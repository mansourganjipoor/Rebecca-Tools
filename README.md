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

