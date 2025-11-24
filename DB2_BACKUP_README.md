# DB2 Backup Script Package

This package contains the DB2 backup script and configuration file for backing up DB2 databases to NFS or local mount points.

## Contents

- `backup-db2.sh` - Main backup script
- `etc/backup-config.yaml` - Configuration file

## Prerequisites

- DB2 installed and configured
- `db2` command available in PATH
- Write access to backup destination (NFS or local mount)
- Bash 4.0 or higher
- Python 3 (optional, for YAML parsing - fallback parser included)

## Quick Start

1. Extract the archive:
   ```bash
   tar -xzf db2-backup.tar.gz
   cd db2-backup
   ```

2. Edit the configuration file:
   ```bash
   vi etc/backup-config.yaml
   ```

3. Run the backup script (as DB2 instance owner, NOT root):
   ```bash
   ./backup-db2.sh
   ```

## Configuration

Edit `etc/backup-config.yaml` to configure your backup:

```yaml
# Backup type: full, incremental, or delta
backup_type: full

# Enable compression
compress: true

# Parallelism for backup (number of parallel processes)
parallelism: 4

# Buffer size in pages (1024 = 4MB default)
buffer_size: 1024

# Backup destination path (NFS or local mount point)
backup_path: /mnt/backup/db2

# Database name to backup
db_name: SAMPLE

# Connection type: local, cataloged, or non-cataloged
connection_type: local

# Retention period in days (0 to disable)
retention_days: 30
```

### Configuration Options

- **backup_type**: `full`, `incremental`, or `delta`
- **compress**: `true` or `false` - Enable backup compression
- **parallelism**: Number of parallel processes (typically 2-8)
- **buffer_size**: Buffer size in pages (default: 1024 = 4MB)
- **backup_path**: Destination path for backups (must exist and be writable)
- **db_name**: Name of the database to backup
- **connection_type**: `local`, `cataloged`, or `non-cataloged` (default: `local`)
- **db_host**: DB2 server hostname/IP (required for non-cataloged external connections)
- **db_port**: DB2 server port (default: 50000, for external connections)
- **db_user**: Database user for authentication (optional, for external connections)
- **db_password**: Database password (optional, will prompt if not set)
- **retention_days**: Number of days to keep backups (0 to disable cleanup)

## Usage

### Direct Execution

Run the script as the DB2 instance owner (NOT as root):

```bash
./backup-db2.sh
```

### Important Notes

- **DO NOT run as root**: The script must run as the DB2 instance owner (e.g., `db2inst1`)
- **Backup path**: Must exist and be writable on the DB2 server
- **Permissions**: The user must have backup permissions on the database

## Backup Types

- **full**: Complete database backup
- **incremental**: Incremental backup (requires previous full backup)
- **delta**: Delta backup (only changed data since last backup)

## Backup Location

Backups are organized in timestamped session directories:

```
{backup_path}/{db_name}/{timestamp}/
```

Each backup session creates its own subdirectory with a millisecond-precision timestamp.

**Example:**
```
/mnt/backup/db2/SAMPLE/20241121_114530123/
├── SAMPLE_full_20241121_114530123.001
├── SAMPLE_full_20241121_114530123.002
└── SAMPLE_full_20241121_114530123.003
```

## Logging

All backup operations are logged to:
```
./logs/db2-backup.log
```

## External Client Connections

The script supports backing up databases from external DB2 clients.

### Non-Cataloged Connection

```yaml
connection_type: non-cataloged
db_host: db2-server.example.com
db_port: 50000
db_name: PRODUCTION
db_user: db2admin
db_password: secret  # Optional - will prompt if not set
```

### Cataloged Connection

```yaml
connection_type: cataloged
db_name: PRODUCTION
db_user: db2admin
# Database must be pre-cataloged:
# db2 catalog tcpip node <node> remote <host> server <port>
# db2 catalog database <db_name> at node <node>
```

## Troubleshooting

### DB2 command not found
- Ensure DB2 is installed and in PATH
- Source the DB2 environment: `. ~/sqllib/db2profile`

### Cannot connect to database
- Verify database name is correct
- Check DB2 instance is running
- Ensure user has backup permissions

### Backup path not writable
- Check mount point permissions
- Verify NFS mount is active (if using NFS)
- Ensure sufficient disk space

### Configuration file not found
- Ensure `etc/backup-config.yaml` exists in the same directory as the script
- The script looks for config in `./etc/backup-config.yaml` relative to the script location

### YAML parsing errors
- Install Python yaml: `pip3 install pyyaml`
- The script includes a fallback parser, but Python yaml is recommended

## Database Permissions

The user must have at least one of the following:
- SYSADM, SYSCTRL, or SYSMAINT system authority, OR
- DBADM authority on the target database, OR
- BACKUP DATABASE privilege on the target database

The script automatically verifies permissions before attempting backup.

## System-Wide Installation

For system-wide installation, use the deployment package (`db2-backup-deploy.tar.gz`) which includes the `deploy.sh` script for automated installation.

## Support

For more detailed information, see the main project README.

