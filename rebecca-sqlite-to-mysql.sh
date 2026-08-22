#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Rebecca Binary: SQLite -> MySQL one-click migration
# Target: Debian/Ubuntu native (systemd) installations.
# Keeps SQLite and backups for rollback. Does NOT delete the old SQLite DB.

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
PY_SCRIPT="$BACKUP_DIR/migrate_data.py"
ORIGINAL_ENV="$BACKUP_DIR/original.env"
FINAL_SQLITE="$BACKUP_DIR/db.sqlite3"
LOG_FILE="$BACKUP_DIR/migration.log"
SWITCHED_ENV=0
SERVICE_WAS_ACTIVE=0
MYSQL_TARGET_TOUCHED=0
MYSQL_USER_CREATED=0
SUCCESS=0
MIGRATION_STARTED=0

c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_blue='\033[36m'
info(){ printf "${c_blue}[INFO]${c_reset} %s\n" "$*"; }
ok(){ printf "${c_green}[OK]${c_reset} %s\n" "$*"; }
warn(){ printf "${c_yellow}[WARN]${c_reset} %s\n" "$*"; }
die(){ printf "${c_red}[ERROR]${c_reset} %s\n" "$*" >&2; exit 1; }

require_root(){
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

get_env_value(){
  local key="$1"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      line=$0; sub(/^[^=]*=[[:space:]]*/, "", line);
      gsub(/^[\047\"]|[\047\"]$/, "", line);
      print line; exit
    }
  ' "$ENV_FILE"
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
  [[ "$MIGRATION_STARTED" -eq 1 ]] || return 0
  printf "\n${c_red}========== MIGRATION FAILED: ROLLBACK ==========${c_reset}\n"

  # Restore Rebecca environment if it was switched.
  if [[ -f "$ORIGINAL_ENV" ]]; then
    cp -a "$ORIGINAL_ENV" "$ENV_FILE" || true
    SWITCHED_ENV=0
  fi

  # SQLite was never deleted or modified beyond checkpointing; restart Rebecca on it.
  if systemctl cat "$SERVICE" >/dev/null 2>&1; then
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  fi

  # Remove only MySQL objects that this script created/touched.
  if [[ "$MYSQL_TARGET_TOUCHED" -eq 1 ]] && command -v mysql >/dev/null 2>&1; then
    mysql_root -e "DROP DATABASE IF EXISTS \`$MYSQL_DB\`;" >/dev/null 2>&1 || true
  fi
  if [[ "$MYSQL_USER_CREATED" -eq 1 ]] && command -v mysql >/dev/null 2>&1; then
    mysql_root -e "DROP USER IF EXISTS '$MYSQL_USER'@'127.0.0.1'; DROP USER IF EXISTS '$MYSQL_USER'@'localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
  fi

  warn "Rebecca has been returned to its previous .env (SQLite)."
  warn "Backup directory: $BACKUP_DIR"
  return 0
}
trap rollback EXIT
trap 'exit 130' INT TERM

require_root
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

info "Rebecca SQLite -> MySQL migration"
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

# ---------- Dependencies ----------
info "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq sqlite3 mysql-server python3 python3-pymysql openssl \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
ok "Dependencies installed."

# ---------- Freeze SQLite and create a consistent backup ----------
info "Stopping Rebecca for a consistent final SQLite snapshot..."
MIGRATION_STARTED=1
systemctl stop "$SERVICE"

CHECKPOINT="$(sqlite3 "$SQLITE_DB" 'PRAGMA wal_checkpoint(TRUNCATE);')"
info "SQLite WAL checkpoint: $CHECKPOINT"
INTEGRITY="$(sqlite3 "$SQLITE_DB" 'PRAGMA integrity_check;')"
[[ "$INTEGRITY" == "ok" ]] || die "SQLite integrity_check failed: $INTEGRITY"

sqlite3 "$SQLITE_DB" ".backup '$FINAL_SQLITE'"
FINAL_INTEGRITY="$(sqlite3 "$FINAL_SQLITE" 'PRAGMA integrity_check;')"
[[ "$FINAL_INTEGRITY" == "ok" ]] || die "Backup SQLite integrity_check failed: $FINAL_INTEGRITY"
cp -a "$ENV_FILE" "$BACKUP_DIR/env-before-mysql"
ok "Consistent SQLite backup created: $FINAL_SQLITE"

# ---------- Configure local MySQL the same way Rebecca Binary expects ----------
info "Configuring local MySQL..."
systemctl enable --now mysql >/dev/null
mkdir -p /etc/mysql/mysql.conf.d
cat > /etc/mysql/mysql.conf.d/rebecca.cnf <<'EOF'
[mysqld]
bind-address=127.0.0.1
skip-name-resolve=ON
local-infile=0
symbolic-links=0
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
max_connections=200
EOF
systemctl restart mysql

for _ in $(seq 1 30); do
  mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1 && break
  sleep 1
done
mysqladmin --protocol=socket -uroot ping --silent >/dev/null 2>&1 || die "MySQL did not become ready."

# Safety: never overwrite an existing populated Rebecca MySQL target or existing Rebecca DB account.
if mysql_root -Nse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${MYSQL_DB}'" | grep -qx "$MYSQL_DB"; then
  TABLE_COUNT="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DB}'")"
  [[ "${TABLE_COUNT:-0}" -eq 0 ]] || die "Existing populated MySQL database '$MYSQL_DB' detected. Refusing to overwrite it."
fi
EXISTING_DB_USERS="$(mysql_root -Nse "SELECT COUNT(*) FROM mysql.user WHERE User='${MYSQL_USER}' AND Host IN ('127.0.0.1','localhost')")"
[[ "${EXISTING_DB_USERS:-0}" -eq 0 ]] || die "Existing MySQL account '$MYSQL_USER'@localhost/127.0.0.1 detected. Refusing to overwrite its password/grants."

# Meets Rebecca installer's password policy: uppercase + lowercase + digit + symbol, no spaces.
MYSQL_PASS="A$(openssl rand -hex 12)a9-$(openssl rand -hex 8)"
printf '%s\n' "$MYSQL_PASS" > "$MYSQL_PASS_FILE"
chmod 600 "$MYSQL_PASS_FILE"

# Password uses URL-safe characters only and no SQL quote characters.
MYSQL_TARGET_TOUCHED=1
MYSQL_USER_CREATED=1
mysql_root <<SQL
DROP DATABASE IF EXISTS \`${MYSQL_DB}\`;
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
systemctl start "$SERVICE"
sleep 3
systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" --since "$START_MARK" --no-pager || true
  die "Rebecca did not stay active after switching to MySQL."
}

# Ensure CLI still sees MySQL while service is live.
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
printf "\nDo NOT delete the SQLite DB or backup directory until you have tested the panel.\n"
