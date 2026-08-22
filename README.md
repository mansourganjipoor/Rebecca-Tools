# Rebecca-Tools

One-click SQLite to MySQL migration tool for Rebecca Panel.

## Features

- Automatic SQLite backup before migration
- MySQL installation and configuration
- Automatic Rebecca schema migration
- SQLite to MySQL data transfer
- Automatic datetime conversion
- Row count validation
- Goose migration version validation
- Automatic rollback on failure
- Keeps the original SQLite database for recovery
- Supports Rebecca Binary installations
- Works with both stable/master and dev installations

## Requirements

- Ubuntu / Debian
- Rebecca Panel installed in Binary mode
- Current database must be SQLite
- Root access

Default Rebecca paths:

```text
/opt/rebecca/.env
/var/lib/rebecca/db.sqlite3
One-line installation
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh | bash
Using a custom Ubuntu mirror

If your Ubuntu repository has connectivity issues, you can specify another mirror:

curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh | APT_MIRROR=https://repo.iut.ac.ir/ubuntu bash
Safer download and execution
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh \
-o /tmp/rebecca-migrate.sh

chmod +x /tmp/rebecca-migrate.sh

sudo /tmp/rebecca-migrate.sh
Migration process
Rebecca + SQLite
        ↓
Environment validation
        ↓
SQLite integrity check
        ↓
Backup SQLite and .env
        ↓
Install and configure MySQL
        ↓
Create Rebecca MySQL database
        ↓
Run official Rebecca migrations
        ↓
Compare SQLite and MySQL schemas
        ↓
Transfer application data
        ↓
Convert datetime values
        ↓
Verify row counts
        ↓
Verify Goose migration version
        ↓
Switch Rebecca to MySQL
        ↓
Start Rebecca
        ↓
Final validation
Backup

The original SQLite database is not deleted.

A backup directory is automatically created under:

/root/rebecca-sqlite-to-mysql-YYYYMMDD-HHMMSS/

This includes the SQLite database and Rebecca environment configuration.

Rollback

If migration fails before completion, the script attempts to restore the previous Rebecca configuration and keep the installation running on SQLite.

Important

Do not manually delete:

/var/lib/rebecca/db.sqlite3

after migration.

Keep the SQLite database and generated backup until you are completely sure the MySQL installation is working correctly.

Database

After successful migration Rebecca uses:

MySQL
Host: 127.0.0.1
Database: rebecca
User: rebecca

MySQL is configured to listen locally rather than being exposed publicly.

License

Use at your own risk. Always keep a backup before modifying production systems.
