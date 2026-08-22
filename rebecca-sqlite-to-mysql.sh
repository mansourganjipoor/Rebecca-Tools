#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="5.0.0"

# Rebecca Binary: SQLite -> fresh MySQL one-click migration (v5)
# Target: Debian/Ubuntu native (systemd) installations.
# Works with the Rebecca Binary currently installed on the server (master/dev agnostic).
# Keeps SQLite and backups for rollback. Does NOT delete the old SQLite DB.
# If an existing MySQL/MariaDB installation is detected, v5 backs it up,
# purges it, removes its old data/config, and installs a fresh MySQL server.
# Destructive reset requires: PURGE_EXISTING_MYSQL=YES
#
# Optional: when the system APT mirror is wrong/unreachable, supply a known-good
# Ubuntu mirror without changing the host's permanent APT configuration:
#   APT_MIRROR=https://repo.iut.ac.ir/ubuntu bash rebecca-sqlite-to-mysql.sh

APP_NAME="${APP_NAME:-rebecca}"
APP_DIR="${APP_DIR:-/opt/rebecca}"
DATA_DIR="${DATA_DIR:-/var/lib/rebecca}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
SQLITE_DB="${SQLITE_DB:-$DATA_DIR/db.sqlite3}"
SERVICE="${SERVICE:-rebecca.service}"
CLI="${CLI:-$APP_DIR/bin/rebecca-cli}"
MYSQL_DB="${MYSQL_DB:-rebecca}"
MYSQL_USER="${MYSQL_USER:-rebecca}"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/rebecca-sqlite-to-mysql-${STAMP}"
TMP_ENV="$BACKUP_DIR/mysql.env"
MYSQL_PASS_FILE="/root/rebecca-mysql-password"
APT_MIRROR="${APT_MIRROR:-}"
PURGE_EXISTING_MYSQL="${PURGE_EXISTING_MYSQL:-NO}"
MYSQL_CNF="/etc/mysql/mysql.conf.d/rebecca.cnf"
MYSQL_CNF_BACKUP="$BACKUP_DIR/rebecca.cnf.before"
MYSQL_CNF_EXISTED=0
PY_SCRIPT="$BACKUP_DIR/migrate_data.py"
ORIGINAL_ENV="$BACKUP_DIR/original.env"
FINAL_SQLITE="$BACKUP_DIR/db.sqlite3"
LOG_FILE="$BACKUP_DIR/migration.log"
MYSQL_BACKUP_DIR="$BACKUP_DIR/existing-mysql"
SWITCHED_ENV=0
SERVICE_WAS_ACTIVE=0
MYSQL_TARGET_TOUCHED=0
MYSQL_USER_CREATED=0
SUCCESS=0
MIGRATION_STARTED=0
MYSQL_RESET_STARTED=0
MYSQL_OLD_PRESENT=0

c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_blue='\033[36m'
info(){ printf "${c_blue}[INFO]${c_reset} %s\n" "$*"; }
ok(){ printf "${c_green}[OK]${c_reset} %s\n" "$*"; }
warn(){ printf "${c_yellow}[WARN]${c_reset} %s\n" "$*"; }
die(){ printf "${c_red}[ERROR]${c_reset} %s\n" "$*" >&2; exit 1; }

require_root(){
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

get_env_value(){
  local key="$1" line
  line="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" || true)"
  [[ -n "$line" ]] || return 0
  line="${line#*=}"
  # Trim surrounding whitespace.
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  # Strip one matching pair of surrounding single/double quotes.
  if [[ ${#line} -ge 2 ]]; then
    if [[ "$line" == \"*\" && "$line" == *\" ]]; then
      line="${line:1:${#line}-2}"
    elif [[ "$line" == \'*\' && "$line" == *\' ]]; then
      line="${line:1:${#line}-2}"
    fi
  fi
  printf '%s\n' "$line"
}

upsert_env(){
  local file="$1" key="$2" value="$3"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key}=\"${value}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

mysql_root(){
  mysql --protocol=socket -uroot "$@"
}

rollback(){
  local rc=$?
  [[ "$SUCCESS" -eq 1 ]] && return 0
  if [[ "$MIGRATION_STARTED" -eq 0 && "$MYSQL_RESET_STARTED" -eq 0 ]]; then
    return 0
  fi

  printf "\n${c_red}========== MIGRATION FAILED: ROLLBACK ==========${c_reset}\n"

  # Rebecca itself is always returned to the original SQLite configuration.
  if [[ "$MIGRATION_STARTED" -eq 1 ]]; then
    if [[ -f "$ORIGINAL_ENV" ]]; then
      cp -a "$ORIGINAL_ENV" "$ENV_FILE" || true
      SWITCHED_ENV=0
    fi

    if systemctl cat "$SERVICE" >/dev/null 2>&1; then
      if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
        systemctl restart "$SERVICE" >/dev/null 2>&1 || true
      else
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
      fi
    fi

    # Remove only the fresh Rebecca target objects created by this run.
    if [[ "$MYSQL_TARGET_TOUCHED" -eq 1 ]] && mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
      mysql_root -e "DROP DATABASE IF EXISTS \`$MYSQL_DB\`;" >/dev/null 2>&1 || true
    fi
    if [[ "$MYSQL_USER_CREATED" -eq 1 ]] && mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
      mysql_root -e "DROP USER IF EXISTS '$MYSQL_USER'@'127.0.0.1'; DROP USER IF EXISTS '$MYSQL_USER'@'localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$MYSQL_PASS_FILE" >/dev/null 2>&1 || true

  if [[ "$MYSQL_RESET_STARTED" -eq 1 ]]; then
    warn "The previous MySQL installation is NOT automatically restored."
    warn "Its backup/metadata (when available) is preserved under: $MYSQL_BACKUP_DIR"
  fi
  if [[ "$MIGRATION_STARTED" -eq 1 ]]; then
    warn "Rebecca has been returned to its previous .env (SQLite)."
  else
    warn "Rebecca was not stopped or modified."
  fi
  warn "Migration backup directory: $BACKUP_DIR"
  return 0
}
trap rollback EXIT
trap 'exit 130' INT TERM

require_root
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

info "Rebecca SQLite -> MySQL migration v${SCRIPT_VERSION}"
info "Backup directory: $BACKUP_DIR"

# ---------- Preconditions ----------
[[ -f /etc/os-release ]] || die "Cannot identify OS."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "This script is intended for Debian/Ubuntu Rebecca Binary installations." ;;
esac

[[ -f "$ENV_FILE" ]] || die "Rebecca env file not found: $ENV_FILE"
[[ -f "$SQLITE_DB" ]] || die "SQLite database not found: $SQLITE_DB"
[[ -x "$CLI" ]] || die "Rebecca CLI not found/executable: $CLI"
[[ -x "$APP_DIR/bin/rebecca-server" ]] || die "Rebecca Binary server not found at $APP_DIR/bin/rebecca-server"
systemctl cat "$SERVICE" >/dev/null 2>&1 || die "systemd service not found: $SERVICE"

CURRENT_FLAVOR="$(get_env_value REBECCA_DATABASE_FLAVOR || true)"
CURRENT_URL="$(get_env_value SQLALCHEMY_DATABASE_URL || true)"
if [[ "$CURRENT_FLAVOR" == "mysql" || "$CURRENT_URL" == mysql* ]]; then
  die "Rebecca is already configured for MySQL. Nothing was changed."
fi
if [[ "$CURRENT_URL" != sqlite* ]]; then
  die "Current SQLALCHEMY_DATABASE_URL is not SQLite: $CURRENT_URL"
fi

cp -a "$ENV_FILE" "$ORIGINAL_ENV"

if systemctl is-active --quiet "$SERVICE"; then
  SERVICE_WAS_ACTIVE=1
fi

# Read the source migration version before making changes.
SOURCE_STATUS="$(REBECCA_ENV_FILE="$ENV_FILE" "$CLI" migrate status)"
printf '%s\n' "$SOURCE_STATUS"
SOURCE_DIALECT="$(printf '%s\n' "$SOURCE_STATUS" | awk -F': ' '/^Dialect:/ {print $2; exit}')"
SOURCE_GOOSE="$(printf '%s\n' "$SOURCE_STATUS" | awk -F': ' '/^Goose version:/ {print $2; exit}')"
[[ "$SOURCE_DIALECT" == "sqlite" ]] || die "Rebecca CLI does not report sqlite dialect."
[[ "$SOURCE_GOOSE" =~ ^[0-9]+$ ]] || die "Could not determine SQLite Goose migration version."
ok "Source Goose version: $SOURCE_GOOSE"

# ---------- Dependency planning / APT safety ----------
info "Checking APT and runtime prerequisites before any destructive MySQL action..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_OPTS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)
APT_COMMON=()

# Detect Ubuntu archive suites in configured APT sources. This prevents, for
# example, Ubuntu noble from accidentally installing packages from jammy.
detect_ubuntu_suite_mismatch() {
  [[ "${ID:-}" == "ubuntu" && -n "${VERSION_CODENAME:-}" ]] || return 0
  OS_CODENAME="$VERSION_CODENAME" python3 - <<'PYAPT'
import os, re
from pathlib import Path
want = os.environ.get("OS_CODENAME", "").strip()
found = []

def ubuntu_archive_uri(uri: str) -> bool:
    u = uri.lower().rstrip('/')
    return ('/ubuntu' in u or 'ubuntu.com/ubuntu' in u)

sl = Path('/etc/apt/sources.list')
files = ([sl] if sl.exists() else []) + list(Path('/etc/apt/sources.list.d').glob('*.list'))
for p in files:
    try:
        lines = p.read_text(errors='ignore').splitlines()
    except Exception:
        continue
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or not line.startswith('deb '):
            continue
        parts = line.split()
        try:
            i = next(i for i,x in enumerate(parts) if x.startswith(('http://','https://')))
        except StopIteration:
            continue
        if i + 1 < len(parts) and ubuntu_archive_uri(parts[i]):
            found.append((str(p), parts[i], parts[i+1]))

for p in Path('/etc/apt/sources.list.d').glob('*.sources'):
    try:
        text = p.read_text(errors='ignore')
    except Exception:
        continue
    for stanza in re.split(r'\n\s*\n', text):
        fields = {}
        for ln in stanza.splitlines():
            if ':' in ln and not ln.lstrip().startswith('#'):
                k,v = ln.split(':',1)
                fields[k.strip().lower()] = v.strip()
        if fields.get('enabled','yes').lower() == 'no':
            continue
        uris = fields.get('uris','').split()
        suites = fields.get('suites','').split()
        if any(ubuntu_archive_uri(u) for u in uris):
            for suite in suites:
                found.append((str(p), ' '.join(uris), suite))

bad=[]
for path, uri, suite in found:
    base = suite.split('-',1)[0]
    if base and want and base != want and not suite.startswith(('$','${')):
        bad.append((path, uri, suite))
if bad:
    print(f"OS codename is {want}, but Ubuntu archive sources target another release:")
    for path,uri,suite in bad:
        print(f"  {path}: {uri} -> {suite}")
    raise SystemExit(42)
PYAPT
}

# Optional temporary mirror, used only by this script and never written into the
# host's permanent APT configuration.
if [[ -n "$APT_MIRROR" ]]; then
  [[ "$APT_MIRROR" =~ ^https?://[^[:space:]]+$ ]] || die "APT_MIRROR must be an http(s) URL."
  [[ "${ID:-}" == "ubuntu" && -n "${VERSION_CODENAME:-}" ]] || die "APT_MIRROR override is currently supported for Ubuntu only."
  APT_SOURCE="$BACKUP_DIR/ubuntu-migration.list"
  APT_LISTS="$BACKUP_DIR/apt-lists"
  mkdir -p "$APT_LISTS/partial"
  cat > "$APT_SOURCE" <<EOF
# Temporary source used only by Rebecca migration v5.
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR ${VERSION_CODENAME} main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR ${VERSION_CODENAME}-updates main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR ${VERSION_CODENAME}-security main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR ${VERSION_CODENAME}-backports main restricted universe multiverse
EOF
  APT_COMMON=(
    -o "Dir::Etc::sourcelist=$APT_SOURCE"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::lists=$APT_LISTS"
    -o "APT::Get::List-Cleanup=0"
  )
  info "Using temporary APT mirror for this run only: $APT_MIRROR"
else
  set +e
  mismatch_out="$(detect_ubuntu_suite_mismatch 2>&1)"
  mismatch_rc=$?
  set -e
  if [[ $mismatch_rc -eq 42 ]]; then
    printf '%s\n' "$mismatch_out"
    die "APT release mismatch detected. Fix repositories or rerun with APT_MIRROR=https://<working-mirror>/ubuntu"
  elif [[ $mismatch_rc -ne 0 ]]; then
    warn "Could not fully inspect APT suites; continuing with normal APT checks."
  fi
fi

apt_get(){ apt-get "${APT_COMMON[@]}" "$@"; }
apt_cache(){ apt-cache "${APT_COMMON[@]}" "$@"; }

if dpkg --audit 2>/dev/null | grep -q .; then
  warn "dpkg reports unfinished package configuration; running dpkg --configure -a."
  dpkg --configure -a || die "dpkg configuration repair failed. Rebecca has not been stopped or modified."
fi

apt_get update || die "apt-get update failed. Rebecca has not been stopped or modified."
if ! apt_get check >/dev/null 2>&1; then
  warn "APT dependency state is broken. Running fix-broken once."
  apt_get --fix-broken install -y "${APT_OPTS[@]}" || die "APT repair failed. Rebecca has not been stopped or modified."
fi

MYSQL_APT_PACKAGE=""
mysql_candidate="$(apt_cache policy mysql-server 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1)"
default_candidate="$(apt_cache policy default-mysql-server 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1)"
if [[ -n "$mysql_candidate" && "$mysql_candidate" != "(none)" ]]; then
  MYSQL_APT_PACKAGE="mysql-server"
  info "APT mysql-server candidate: $mysql_candidate"
elif [[ -n "$default_candidate" && "$default_candidate" != "(none)" ]]; then
  MYSQL_APT_PACKAGE="default-mysql-server"
  info "APT default-mysql-server candidate: $default_candidate"
else
  die "No installable MySQL server candidate was found. Existing MySQL has NOT been purged."
fi

# Ensure non-MySQL helpers are ready before touching an existing DB server.
helper_pkgs=()
command -v python3 >/dev/null 2>&1 || helper_pkgs+=(python3)
command -v openssl >/dev/null 2>&1 || helper_pkgs+=(openssl)
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sqlite3' >/dev/null 2>&1 || die "Python sqlite3 module is unavailable."
  python3 -c 'import pymysql' >/dev/null 2>&1 || helper_pkgs+=(python3-pymysql)
else
  helper_pkgs+=(python3-pymysql)
fi
if ((${#helper_pkgs[@]})); then
  info "Installing helper packages before MySQL reset: ${helper_pkgs[*]}"
  apt_get install -y "${APT_OPTS[@]}" "${helper_pkgs[@]}" || die "Unable to install helper packages. Existing MySQL has NOT been purged."
fi
python3 -c 'import sqlite3, pymysql' >/dev/null 2>&1 || die "Python sqlite3/PyMySQL modules are unavailable."

# ---------- Detect, back up, purge and reinstall existing MySQL/MariaDB ----------
mkdir -p "$MYSQL_BACKUP_DIR"
chmod 700 "$MYSQL_BACKUP_DIR"

mapfile -t EXISTING_MYSQL_PKGS < <(
  dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>/dev/null | \
  awk '$2=="install" && $3=="ok" && $4=="installed" && $1 ~ /^(mysql-(server|client|common)|mysql-server-core|mysql-client-core|default-mysql-(server|client)|mariadb-(server|client|common))/ {print $1}' | sort -u
)

if ((${#EXISTING_MYSQL_PKGS[@]})) || command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1 || [[ -d /etc/mysql || -e /var/lib/mysql ]]; then
  MYSQL_OLD_PRESENT=1
fi

if [[ "$MYSQL_OLD_PRESENT" -eq 1 ]]; then
  [[ "$PURGE_EXISTING_MYSQL" == "YES" ]] || die "Existing MySQL/MariaDB detected. For safety, rerun with PURGE_EXISTING_MYSQL=YES. Nothing has been purged."
  MYSQL_RESET_STARTED=1
  warn "Existing MySQL/MariaDB detected. It will be backed up and then PURGED as explicitly requested."
  info "Existing MySQL backup directory: $MYSQL_BACKUP_DIR"

  # Metadata/config backup first.
  {
    date -u
    cat /etc/os-release 2>/dev/null || true
    printf '\n--- installed DB packages ---\n'
    printf '%s\n' "${EXISTING_MYSQL_PKGS[@]:-}"
    printf '\n--- mysql version ---\n'
    mysql --version 2>/dev/null || true
    mysqld --version 2>/dev/null || true
    mariadbd --version 2>/dev/null || true
  } > "$MYSQL_BACKUP_DIR/metadata.txt"
  systemctl status mysql --no-pager -l > "$MYSQL_BACKUP_DIR/mysql-service-status.txt" 2>&1 || true
  systemctl status mariadb --no-pager -l > "$MYSQL_BACKUP_DIR/mariadb-service-status.txt" 2>&1 || true
  journalctl -u mysql -n 300 --no-pager > "$MYSQL_BACKUP_DIR/mysql-journal.txt" 2>&1 || true
  journalctl -u mariadb -n 300 --no-pager > "$MYSQL_BACKUP_DIR/mariadb-journal.txt" 2>&1 || true

  cfg_paths=()
  [[ -e /etc/mysql ]] && cfg_paths+=(/etc/mysql)
  [[ -e /etc/my.cnf ]] && cfg_paths+=(/etc/my.cnf)
  [[ -e /etc/my.cnf.d ]] && cfg_paths+=(/etc/my.cnf.d)
  [[ -e /root/.my.cnf ]] && cfg_paths+=(/root/.my.cnf)
  [[ -e /etc/systemd/system/mysql.service.d ]] && cfg_paths+=(/etc/systemd/system/mysql.service.d)
  [[ -e /etc/systemd/system/mariadb.service.d ]] && cfg_paths+=(/etc/systemd/system/mariadb.service.d)
  if ((${#cfg_paths[@]})); then
    tar --numeric-owner -cpf "$MYSQL_BACKUP_DIR/mysql-config.tar" "${cfg_paths[@]}" 2>/dev/null || die "Could not back up existing MySQL configuration. Nothing has been purged."
  fi

  # Logical dump when the current server is actually reachable through root socket auth.
  LOGICAL_DUMP_OK=0
  if command -v mysqladmin >/dev/null 2>&1 && mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
    info "Existing MySQL is reachable; creating logical all-databases dump..."
    mysql --protocol=socket -uroot -Nse 'SHOW DATABASES' > "$MYSQL_BACKUP_DIR/databases.txt" 2>&1 || true
    mysql --protocol=socket -uroot -Nse 'SELECT @@datadir' > "$MYSQL_BACKUP_DIR/live-datadir.txt" 2>/dev/null || true
    if command -v mysqldump >/dev/null 2>&1 && \
       mysqldump --protocol=socket -uroot --all-databases --single-transaction --routines --events --triggers --hex-blob --default-character-set=utf8mb4 > "$MYSQL_BACKUP_DIR/all-databases.sql"; then
      LOGICAL_DUMP_OK=1
      ok "Logical MySQL backup created."
    else
      rm -f "$MYSQL_BACKUP_DIR/all-databases.sql"
      warn "Logical dump was not possible; a stopped physical datadir backup will be attempted."
    fi
  else
    warn "Existing MySQL socket is unavailable; a stopped physical datadir backup will be attempted."
  fi

  # Collect likely datadirs before stopping the server.
  DATADIR_FILE="$MYSQL_BACKUP_DIR/datadir-candidates.txt"
  : > "$DATADIR_FILE"
  if [[ -s "$MYSQL_BACKUP_DIR/live-datadir.txt" ]]; then
    cat "$MYSQL_BACKUP_DIR/live-datadir.txt" >> "$DATADIR_FILE"
  fi
  grep -RhsE '^[[:space:]]*datadir[[:space:]]*=' /etc/mysql /etc/my.cnf /etc/my.cnf.d 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' >> "$DATADIR_FILE" || true
  for pid in $(pgrep -x mysqld 2>/dev/null || true) $(pgrep -x mariadbd 2>/dev/null || true); do
    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 's/^--datadir=//p' >> "$DATADIR_FILE" || true
  done
  if command -v mysqld >/dev/null 2>&1; then
    timeout 10s mysqld --verbose --help 2>/dev/null | awk '$1=="datadir" {print $2; exit}' >> "$DATADIR_FILE" || true
  fi
  printf '%s\n' /var/lib/mysql >> "$DATADIR_FILE"
  sed -i '/^[[:space:]]*$/d' "$DATADIR_FILE"
  sort -u -o "$DATADIR_FILE" "$DATADIR_FILE"

  stop_db_service(){
    local svc="$1" state i
    systemctl cat "$svc" >/dev/null 2>&1 || return 0
    state="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || true)"
    [[ "$state" == "inactive" || "$state" == "failed" || -z "$state" ]] && return 0
    info "Stopping $svc (bounded wait)..."
    systemctl stop "$svc" --no-block >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
      state="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || true)"
      [[ "$state" == "inactive" || "$state" == "failed" || -z "$state" ]] && return 0
      sleep 1
    done
    warn "$svc did not stop within 30 seconds; sending SIGKILL to its main process."
    systemctl kill --kill-who=main --signal=SIGKILL "$svc" >/dev/null 2>&1 || true
    sleep 2
    systemctl reset-failed "$svc" >/dev/null 2>&1 || true
  }
  stop_db_service mysql
  stop_db_service mariadb

  # Physical backup after the old daemon is stopped. Multiple candidate paths are
  # deduplicated and archived separately. This is the fallback for broken sockets.
  PHYSICAL_BACKUP_OK=0
  idx=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    d="${d%/}"
    [[ -d "$d" ]] || continue
    # Only treat a directory as a MySQL datadir when it contains typical DB markers.
    if [[ -d "$d/mysql" || -e "$d/ibdata1" || -e "$d/auto.cnf" || -d "$d/#innodb_redo" ]]; then
      idx=$((idx+1))
      bytes="$(du -sb "$d" 2>/dev/null | awk '{print $1}' || echo 0)"
      avail="$(df -PB1 "$MYSQL_BACKUP_DIR" | awk 'NR==2 {print $4}')"
      need=$(( bytes + bytes/10 + 268435456 ))
      if (( bytes > 0 && avail < need )); then
        die "Insufficient free disk space to physically back up existing MySQL datadir $d. Nothing has been purged."
      fi
      archive="$MYSQL_BACKUP_DIR/datadir-${idx}.tar"
      info "Creating physical MySQL datadir backup: $d"
      tar --numeric-owner -cpf "$archive" -C "$(dirname "$d")" "$(basename "$d")" || die "Physical MySQL backup failed. Nothing has been purged."
      printf '%s\t%s\n' "$archive" "$d" >> "$MYSQL_BACKUP_DIR/physical-backups.txt"
      PHYSICAL_BACKUP_OK=1
    fi
  done < "$DATADIR_FILE"

  if [[ "$LOGICAL_DUMP_OK" -eq 0 && "$PHYSICAL_BACKUP_OK" -eq 0 ]]; then
    warn "No readable MySQL data directory and no logical dump were available. Only package/config/log metadata could be backed up."
    printf '%s\n' 'No logical or physical database data was available at reset time.' > "$MYSQL_BACKUP_DIR/NO_DATABASE_DATA_FOUND.txt"
  fi

  find "$MYSQL_BACKUP_DIR" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum > "$MYSQL_BACKUP_DIR/SHA256SUMS" 2>/dev/null || true
  ok "Existing MySQL backup phase completed."

  # Purge the installed DB server/client packages. Do not autoremove unrelated deps.
  if ((${#EXISTING_MYSQL_PKGS[@]})); then
    info "Purging old MySQL/MariaDB packages: ${EXISTING_MYSQL_PKGS[*]}"
    apt_get purge -y "${APT_OPTS[@]}" "${EXISTING_MYSQL_PKGS[@]}" || die "Package purge failed. Rebecca is still on SQLite. Existing MySQL backup is preserved."
  fi

  # Remove old MySQL configuration/runtime paths and verified datadirs after backup.
  rm -rf /etc/mysql /run/mysqld /var/run/mysqld /var/log/mysql /var/log/mysql.* 2>/dev/null || true
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    d="${d%/}"
    [[ -d "$d" ]] || continue
    if [[ -d "$d/mysql" || -e "$d/ibdata1" || -e "$d/auto.cnf" || -d "$d/#innodb_redo" ]]; then
      info "Removing backed-up old MySQL datadir: $d"
      rm -rf --one-file-system "$d"
    fi
  done < "$DATADIR_FILE"
  rm -rf /var/lib/mysql-files /var/lib/mysql-keyring 2>/dev/null || true
  dpkg --configure -a || die "dpkg configuration failed after purge. Rebecca remains on SQLite."
  ok "Old MySQL/MariaDB installation purged."
else
  info "No existing MySQL/MariaDB installation detected; fresh install will proceed."
fi

# Always install a fresh MySQL package in v5, even if old binaries were present.
info "Installing fresh MySQL server..."
apt_get install -y "${APT_OPTS[@]}" "$MYSQL_APT_PACKAGE" python3-pymysql || die "Fresh MySQL installation failed. Rebecca remains on SQLite. Previous MySQL backup is at $MYSQL_BACKUP_DIR"

command -v mysql >/dev/null 2>&1 || die "mysql client is unavailable after installation."
command -v mysqld >/dev/null 2>&1 || die "mysqld is unavailable after installation."
command -v mysqladmin >/dev/null 2>&1 || die "mysqladmin is unavailable after installation."
command -v openssl >/dev/null 2>&1 || die "openssl is unavailable."
python3 -c 'import sqlite3, pymysql' >/dev/null 2>&1 || die "Python sqlite3/PyMySQL modules are unavailable."

# Fresh local-only MySQL configuration. Use a bounded restart so a stuck daemon
# cannot leave the script hanging indefinitely at "Configuring local MySQL".
info "Configuring fresh local MySQL..."
mkdir -p /etc/mysql/mysql.conf.d
cat > "$MYSQL_CNF" <<'EOF'
[mysqld]
bind-address=127.0.0.1
mysqlx-bind-address=127.0.0.1
skip-name-resolve=ON
local-infile=0
symbolic-links=0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_connections=200
EOF
systemctl enable mysql >/dev/null 2>&1 || true
systemctl restart mysql --no-block >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1 && break
  sleep 1
done
if ! mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1; then
  systemctl status mysql --no-pager -l || true
  journalctl -u mysql -n 100 --no-pager || true
  die "Fresh MySQL did not become ready within 60 seconds. Rebecca has not yet been stopped."
fi
ok "Fresh MySQL is running and ready."

# A fresh server must not already contain Rebecca objects.
if mysql_root -Nse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${MYSQL_DB}'" | grep -qx "$MYSQL_DB"; then
  die "Fresh MySQL unexpectedly already contains database '$MYSQL_DB'. Refusing to overwrite it."
fi
EXISTING_DB_USERS="$(mysql_root -Nse "SELECT COUNT(*) FROM mysql.user WHERE User='${MYSQL_USER}' AND Host IN ('127.0.0.1','localhost')")"
[[ "${EXISTING_DB_USERS:-0}" -eq 0 ]] || die "Fresh MySQL unexpectedly already contains account '$MYSQL_USER'. Refusing to overwrite it."

# ---------- Freeze SQLite and create a consistent backup ----------
info "Stopping Rebecca for a consistent final SQLite snapshot..."
MIGRATION_STARTED=1
systemctl stop "$SERVICE"

MIG_SQLITE_DB="$SQLITE_DB" MIG_FINAL_SQLITE="$FINAL_SQLITE" python3 - <<'PYSQLITE'
import os, sqlite3
src = os.environ['MIG_SQLITE_DB']
dst = os.environ['MIG_FINAL_SQLITE']
con = sqlite3.connect(src)
try:
    ck = con.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()
    print('SQLite WAL checkpoint:', '|'.join(map(str, ck or ())))
    integrity = con.execute('PRAGMA integrity_check').fetchone()[0]
    if integrity != 'ok':
        raise RuntimeError(f'SQLite integrity_check failed: {integrity}')
    out = sqlite3.connect(dst)
    try:
        con.backup(out)
    finally:
        out.close()
finally:
    con.close()

verify = sqlite3.connect(dst)
try:
    integrity = verify.execute('PRAGMA integrity_check').fetchone()[0]
    if integrity != 'ok':
        raise RuntimeError(f'Backup SQLite integrity_check failed: {integrity}')
finally:
    verify.close()
print('SQLite backup integrity: ok')
PYSQLITE
cp -a "$ENV_FILE" "$BACKUP_DIR/env-before-mysql"
ok "Consistent SQLite backup created: $FINAL_SQLITE"

# ---------- Fresh MySQL is already configured and healthy ----------
info "Preparing Rebecca database and account on fresh MySQL..."

# Meets Rebecca installer's password policy: uppercase + lowercase + digit + symbol, no spaces.
MYSQL_PASS="A$(openssl rand -hex 12)a9-$(openssl rand -hex 8)"
printf '%s\n' "$MYSQL_PASS" > "$MYSQL_PASS_FILE"
chmod 600 "$MYSQL_PASS_FILE"

# Password uses URL-safe characters only and no SQL quote characters.
MYSQL_TARGET_TOUCHED=1
MYSQL_USER_CREATED=1
mysql_root <<SQL
CREATE DATABASE \`${MYSQL_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
ALTER USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASS}';
ALTER USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DB}\`.* TO '${MYSQL_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${MYSQL_DB}\`.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "MySQL database/user created."

# ---------- Temporary MySQL env and official Rebecca schema migrations ----------
cp -a "$ENV_FILE" "$TMP_ENV"
upsert_env "$TMP_ENV" REBECCA_DATABASE_FLAVOR "mysql"
upsert_env "$TMP_ENV" MYSQL_DATABASE "$MYSQL_DB"
upsert_env "$TMP_ENV" MYSQL_USER "$MYSQL_USER"
upsert_env "$TMP_ENV" MYSQL_PASSWORD "$MYSQL_PASS"
upsert_env "$TMP_ENV" SQLALCHEMY_DATABASE_URL "mysql+pymysql://${MYSQL_USER}:${MYSQL_PASS}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
chmod 600 "$TMP_ENV"

info "Creating MySQL schema with Rebecca's own migrations..."
REBECCA_ENV_FILE="$TMP_ENV" "$CLI" migrate up
TARGET_STATUS="$(REBECCA_ENV_FILE="$TMP_ENV" "$CLI" migrate status)"
printf '%s\n' "$TARGET_STATUS"
TARGET_DIALECT="$(printf '%s\n' "$TARGET_STATUS" | awk -F': ' '/^Dialect:/ {print $2; exit}')"
TARGET_GOOSE="$(printf '%s\n' "$TARGET_STATUS" | awk -F': ' '/^Goose version:/ {print $2; exit}')"
[[ "$TARGET_DIALECT" == "mysql" ]] || die "Rebecca CLI did not report MySQL dialect for target DB."
[[ "$TARGET_GOOSE" == "$SOURCE_GOOSE" ]] || die "Migration version mismatch: SQLite=$SOURCE_GOOSE MySQL=$TARGET_GOOSE"
ok "MySQL schema is at Goose version $TARGET_GOOSE."

# ---------- Data migration (transactional) ----------
cat > "$PY_SCRIPT" <<'PY'
import sqlite3
import pymysql
import os
import re
import sys
from datetime import datetime, date, time, timezone, timedelta

sqlite_db = os.environ["MIG_SQLITE_DB"]
mysql_host = os.environ["MIG_MYSQL_HOST"]
mysql_port = int(os.environ["MIG_MYSQL_PORT"])
mysql_user = os.environ["MIG_MYSQL_USER"]
mysql_password = os.environ["MIG_MYSQL_PASSWORD"]
mysql_db = os.environ["MIG_MYSQL_DB"]
expected_goose = int(os.environ["MIG_GOOSE_VERSION"])

EXCLUDED = {"alembic_version", "goose_db_version"}
GO_TIME_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
    r'(?:\.(\d+))?\s+([+-])(\d{2})(\d{2})(?:\s+\S+)?$'
)


def go_or_iso_datetime(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        dt = value
        if dt.tzinfo is not None:
            dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
        return dt
    s = str(value).strip()
    if not s:
        return None
    m = GO_TIME_RE.match(s)
    if m:
        base, fraction, sign, oh, om = m.groups()
        micros = int(((fraction or "") + "000000")[:6])
        dt = datetime.strptime(base, "%Y-%m-%d %H:%M:%S").replace(microsecond=micros)
        mins = int(oh) * 60 + int(om)
        if sign == "-":
            mins = -mins
        dt = dt.replace(tzinfo=timezone(timedelta(minutes=mins)))
        return dt.astimezone(timezone.utc).replace(tzinfo=None)
    iso = s[:-1] + "+00:00" if s.endswith("Z") else s
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError as e:
        raise ValueError(f"Unsupported datetime format: {value!r}") from e
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt


def convert_value(value, mysql_type):
    if value is None:
        return None
    t = mysql_type.lower()
    if t in ("datetime", "timestamp"):
        return go_or_iso_datetime(value)
    if t == "date":
        if isinstance(value, datetime):
            return value.date()
        if isinstance(value, date):
            return value
        s = str(value).strip()
        try:
            return date.fromisoformat(s)
        except ValueError:
            return go_or_iso_datetime(value).date()
    if t == "time":
        if isinstance(value, time):
            return value
        s = str(value).strip()
        try:
            return time.fromisoformat(s)
        except ValueError:
            return value
    return value

sq = sqlite3.connect(sqlite_db)
sq.row_factory = sqlite3.Row
my = pymysql.connect(
    host=mysql_host, port=mysql_port, user=mysql_user, password=mysql_password,
    database=mysql_db, charset="utf8mb4", autocommit=False
)
sqc = sq.cursor()
myc = my.cursor()

try:
    sqc.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    sqlite_tables = {r[0] for r in sqc.fetchall()}
    myc.execute("SELECT table_name FROM information_schema.tables WHERE table_schema=%s ORDER BY table_name", (mysql_db,))
    mysql_tables = {r[0] for r in myc.fetchall()}

    only_sqlite = sorted(sqlite_tables - mysql_tables)
    only_mysql = sorted(mysql_tables - sqlite_tables)
    allowed_only_sqlite = [x for x in only_sqlite if x in EXCLUDED]
    unexpected_sqlite = [x for x in only_sqlite if x not in EXCLUDED]
    unexpected_mysql = [x for x in only_mysql if x not in EXCLUDED]
    print(f"SQLite tables: {len(sqlite_tables)} | MySQL tables: {len(mysql_tables)}")
    print(f"Expected source-only tables: {allowed_only_sqlite}")
    if unexpected_sqlite or unexpected_mysql:
        raise RuntimeError(f"Unexpected table mismatch. only_sqlite={unexpected_sqlite}, only_mysql={unexpected_mysql}")

    tables = sorted((sqlite_tables & mysql_tables) - EXCLUDED)

    # Schema compatibility check before any DML.
    metadata = {}
    for table in tables:
        sqc.execute(f'PRAGMA table_info("{table}")')
        sqlite_cols = [r[1] for r in sqc.fetchall()]
        myc.execute("""
            SELECT column_name, data_type, generation_expression
            FROM information_schema.columns
            WHERE table_schema=%s AND table_name=%s
            ORDER BY ordinal_position
        """, (mysql_db, table))
        info = myc.fetchall()
        mysql_cols = [r[0] for r in info]
        if set(sqlite_cols) != set(mysql_cols):
            raise RuntimeError(
                f"Column mismatch in {table}: "
                f"only_sqlite={sorted(set(sqlite_cols)-set(mysql_cols))}, "
                f"only_mysql={sorted(set(mysql_cols)-set(sqlite_cols))}"
            )
        metadata[table] = (sqlite_cols, info)
    print("Schema check: ALL COMMON TABLE COLUMNS MATCH")

    myc.execute("SET FOREIGN_KEY_CHECKS=0")
    for table in tables:
        myc.execute(f"DELETE FROM `{table}`")

    total_source = 0
    total_target = 0
    datetime_conversions = 0

    for table in tables:
        sqlite_cols, info = metadata[table]
        mysql_types = {r[0]: r[1] for r in info}
        generated = {r[0] for r in info if r[2]}
        insert_cols = [c for c in sqlite_cols if c not in generated]

        quoted = ", ".join(f'"{c}"' for c in insert_cols)
        sqc.execute(f'SELECT {quoted} FROM "{table}"')
        rows = sqc.fetchall()
        source_count = len(rows)

        if rows:
            col_sql = ", ".join(f"`{c}`" for c in insert_cols)
            placeholders = ", ".join(["%s"] * len(insert_cols))
            insert_sql = f"INSERT INTO `{table}` ({col_sql}) VALUES ({placeholders})"
            values = []
            for row in rows:
                out = []
                for c in insert_cols:
                    typ = mysql_types[c]
                    raw = row[c]
                    converted = convert_value(raw, typ)
                    if raw is not None and typ.lower() in ("datetime", "timestamp", "date", "time"):
                        datetime_conversions += 1
                    out.append(converted)
                values.append(tuple(out))
            myc.executemany(insert_sql, values)

        myc.execute(f"SELECT COUNT(*) FROM `{table}`")
        target_count = myc.fetchone()[0]
        if source_count != target_count:
            raise RuntimeError(f"Row-count mismatch in {table}: SQLite={source_count}, MySQL={target_count}")
        if source_count:
            print(f"[OK] {table:35} SQLite={source_count:<8} MySQL={target_count:<8}")
        total_source += source_count
        total_target += target_count

    myc.execute("SELECT MAX(version_id) FROM goose_db_version WHERE is_applied=1")
    goose = myc.fetchone()[0]
    if goose != expected_goose:
        raise RuntimeError(f"Goose mismatch after data copy: expected={expected_goose}, target={goose}")
    if total_source != total_target:
        raise RuntimeError(f"Global row-count mismatch: SQLite={total_source}, MySQL={total_target}")

    my.commit()
    print("=" * 64)
    print(f"SQLite total rows: {total_source}")
    print(f"MySQL total rows : {total_target}")
    print(f"Date/time values converted: {datetime_conversions}")
    print(f"Goose version: {goose}")
    print("DATA MIGRATION SUCCESSFUL - TRANSACTION COMMITTED")
    print("=" * 64)
except Exception:
    my.rollback()
    print("DATA MIGRATION FAILED - MYSQL TRANSACTION ROLLED BACK", file=sys.stderr)
    raise
finally:
    try:
        myc.execute("SET FOREIGN_KEY_CHECKS=1")
    except Exception:
        pass
    sq.close()
    my.close()
PY

info "Copying application data from the final SQLite snapshot into MySQL..."
MIG_SQLITE_DB="$FINAL_SQLITE" \
MIG_MYSQL_HOST="$MYSQL_HOST" \
MIG_MYSQL_PORT="$MYSQL_PORT" \
MIG_MYSQL_USER="$MYSQL_USER" \
MIG_MYSQL_PASSWORD="$MYSQL_PASS" \
MIG_MYSQL_DB="$MYSQL_DB" \
MIG_GOOSE_VERSION="$SOURCE_GOOSE" \
python3 "$PY_SCRIPT"
ok "Application data copied and verified."

# ---------- Switch the live Rebecca .env ----------
info "Switching Rebecca live configuration to MySQL..."
upsert_env "$ENV_FILE" REBECCA_DATABASE_FLAVOR "mysql"
upsert_env "$ENV_FILE" MYSQL_DATABASE "$MYSQL_DB"
upsert_env "$ENV_FILE" MYSQL_USER "$MYSQL_USER"
upsert_env "$ENV_FILE" MYSQL_PASSWORD "$MYSQL_PASS"
upsert_env "$ENV_FILE" SQLALCHEMY_DATABASE_URL "mysql+pymysql://${MYSQL_USER}:${MYSQL_PASS}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
chmod 600 "$ENV_FILE"
SWITCHED_ENV=1

LIVE_STATUS="$(REBECCA_ENV_FILE="$ENV_FILE" "$CLI" migrate status)"
printf '%s\n' "$LIVE_STATUS"
LIVE_DIALECT="$(printf '%s\n' "$LIVE_STATUS" | awk -F': ' '/^Dialect:/ {print $2; exit}')"
LIVE_GOOSE="$(printf '%s\n' "$LIVE_STATUS" | awk -F': ' '/^Goose version:/ {print $2; exit}')"
[[ "$LIVE_DIALECT" == "mysql" ]] || die "Live .env does not resolve to MySQL."
[[ "$LIVE_GOOSE" == "$SOURCE_GOOSE" ]] || die "Live Goose mismatch: source=$SOURCE_GOOSE live=$LIVE_GOOSE"

# ---------- Start and validate Rebecca ----------
SQLITE_MTIME_BEFORE="$(stat -c %Y "$SQLITE_DB")"
START_MARK="$(date --iso-8601=seconds)"
if [[ "$SERVICE_WAS_ACTIVE" -eq 1 ]]; then
  systemctl start "$SERVICE"
  sleep 3
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" --since "$START_MARK" --no-pager || true
    die "Rebecca did not stay active after switching to MySQL."
  }
else
  warn "Rebecca was stopped before migration, so it is being left stopped after migration."
fi

# Ensure CLI sees MySQL in the final live configuration.
FINAL_STATUS="$(REBECCA_ENV_FILE="$ENV_FILE" "$CLI" migrate status)"
FINAL_DIALECT="$(printf '%s\n' "$FINAL_STATUS" | awk -F': ' '/^Dialect:/ {print $2; exit}')"
FINAL_GOOSE="$(printf '%s\n' "$FINAL_STATUS" | awk -F': ' '/^Goose version:/ {print $2; exit}')"
[[ "$FINAL_DIALECT" == "mysql" && "$FINAL_GOOSE" == "$SOURCE_GOOSE" ]] || die "Final Rebecca DB verification failed."

# MySQL must only listen on localhost.
if ! ss -lnt 2>/dev/null | awk '$4 ~ /127\.0\.0\.1:3306$/ {found=1} END{exit !found}'; then
  die "MySQL is not listening on 127.0.0.1:3306 as expected."
fi

# Look only at new service logs for obvious DB startup failures.
NEW_LOGS="$(journalctl -u "$SERVICE" --since "$START_MARK" --no-pager || true)"
if printf '%s\n' "$NEW_LOGS" | grep -Eqi 'database connection failed|access denied|unknown database|migration failed|panic:|fatal'; then
  printf '%s\n' "$NEW_LOGS"
  die "Rebecca produced a database/startup error after switching to MySQL."
fi

SQLITE_MTIME_AFTER="$(stat -c %Y "$SQLITE_DB")"
if [[ "$SQLITE_MTIME_AFTER" != "$SQLITE_MTIME_BEFORE" ]]; then
  warn "SQLite mtime changed after startup. This is unusual; inspect logs before deleting anything."
else
  ok "Old SQLite file remained unchanged after Rebecca started on MySQL."
fi

# Final row overview for non-empty application tables.
info "Final non-empty MySQL table counts:"
MYSQL_PWD="$MYSQL_PASS" mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" "$MYSQL_DB" -Nse \
"SELECT CONCAT(table_name, ': ', table_rows) FROM information_schema.tables WHERE table_schema='${MYSQL_DB}' AND table_rows > 0 ORDER BY table_name;" || true

SUCCESS=1
trap - EXIT INT TERM

printf "\n${c_green}============================================================${c_reset}\n"
printf "${c_green} Rebecca SQLite -> MySQL migration completed successfully.${c_reset}\n"
printf "${c_green}============================================================${c_reset}\n"
printf "Backup directory : %s\n" "$BACKUP_DIR"
printf "SQLite backup    : %s\n" "$FINAL_SQLITE"
printf "Old SQLite live  : %s  (kept for rollback)\n" "$SQLITE_DB"
printf "MySQL database   : %s@%s:%s/%s\n" "$MYSQL_USER" "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_DB"
printf "MySQL password   : %s\n" "$MYSQL_PASS_FILE"
printf "Migration log    : %s\n" "$LOG_FILE"
printf "Goose version    : %s\n" "$SOURCE_GOOSE"
if [[ "$MYSQL_OLD_PRESENT" -eq 1 ]]; then
  printf "Old MySQL backup : %s\n" "$MYSQL_BACKUP_DIR"
fi
printf "\nDo NOT delete the SQLite DB, migration backup, or old MySQL backup until you have tested the panel.\n"
