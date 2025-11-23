# DB2 Database Backup Script

A comprehensive bash script for backing up DB2 databases to NFS or local mount points.

## Features

- ✅ Supports NFS and local mount points
- ✅ **External client support** - Backup from remote DB2 clients
- ✅ **Timestamped session directories** - Each backup session in its own subdirectory
- ✅ **Millisecond-precision timestamps** - Prevents file overwrites during concurrent backups
- ✅ Automatic mount point verification
- ✅ **Database rights verification** - Checks backup permissions before attempting backup
- ✅ Configurable via YAML configuration file
- ✅ Comprehensive logging to `./logs/db2-backup.log`
- ✅ Multiple backup types: full, incremental, delta
- ✅ Compression support
- ✅ Parallel backup operations
- ✅ Automatic cleanup of old backups
- ✅ Error handling and validation
- ✅ Disk space checking

## Prerequisites

- DB2 installed and configured
- `db2` command available in PATH
- Write access to backup destination (NFS or local mount)
- Bash 4.0 or higher

## Installation

### Automated Deployment (Recommended)

Use the deployment script to install system-wide:

```bash
# Run as root
sudo ./deploy.sh

# Or specify custom installation directory and DB2 user
sudo INSTALL_DIR=/opt/db2-protect DB2_USER=db2inst1 ./deploy.sh
```

The deployment script will:
- Check prerequisites (bash, DB2 user, etc.)
- Create directory structure
- Install all files with correct permissions
- Create example configuration if needed
- Verify installation

### Manual Installation

1. Make the script executable:
```bash
chmod +x backup-db2.sh
```

2. Create necessary directories:
```bash
mkdir -p logs etc
```

3. Configure the backup settings by editing `etc/backup-config.yaml`

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

# DB2 instance name (optional)
db_instance: db2inst1

# Database name to backup
db_name: SAMPLE

# Retention period in days (0 to disable)
retention_days: 30
```

### Configuration Options

- **backup_type**: `full`, `incremental`, or `delta`
- **compress**: `true` or `false` - Enable backup compression
- **parallelism**: Number of parallel processes (typically 2-8)
- **buffer_size**: Buffer size in pages (default: 1024 = 4MB)
- **backup_path**: Destination path for backups (must exist and be writable on DB2 server)
- **db_instance**: DB2 instance name (optional, uses default if not specified, local only)
- **db_name**: Name of the database to backup
- **connection_type**: `local`, `cataloged`, or `non-cataloged` (default: `local`)
- **db_host**: DB2 server hostname/IP (required for non-cataloged external connections)
- **db_port**: DB2 server port (default: 50000, for external connections)
- **db_user**: Database user for authentication (optional, for external connections)
- **db_password**: Database password (optional, will prompt if not set)
- **retention_days**: Number of days to keep backups (0 to disable cleanup)

## Usage

### Using the Makefile

```bash
# Install and setup
make install

# Run backup
make backup

# Show help
make help
```

### Direct execution

```bash
./backup-db2.sh
```

## Backup Types

- **full**: Complete database backup
- **incremental**: Incremental backup (requires previous full backup)
- **delta**: Delta backup (only changed data since last backup)

## Backup Location

Backups are organized in timestamped session directories to prevent file overwrites and enable concurrent backups:

```
{backup_path}/{db_name}/{timestamp}/
```

Each backup session creates its own subdirectory with a millisecond-precision timestamp (format: `YYYYMMDD_HHMMSSmmm`).

**Structure:**
```
{backup_path}/{db_name}/{timestamp}/{db_name}_{backup_type}_{timestamp}.001
{backup_path}/{db_name}/{timestamp}/{db_name}_{backup_type}_{timestamp}.002
...
```

**Example:**
```
/mnt/backup/db2/SAMPLE/20241121_114530123/
├── SAMPLE_full_20241121_114530123.001
├── SAMPLE_full_20241121_114530123.002
└── SAMPLE_full_20241121_114530123.003
```

**Benefits:**
- **Concurrent-safe**: Millisecond precision prevents collisions when multiple backups run simultaneously
- **Session isolation**: Each backup session is completely isolated in its own directory
- **Easy management**: Entire sessions can be moved, archived, or deleted as a unit
- **No overwrites**: Files from different backup sessions never conflict

## Logging

All backup operations are logged to:
```
./logs/db2-backup.log
```

The log includes:
- Configuration details
- Mount point verification
- Backup session directory creation
- Backup progress
- File sizes and locations
- Errors and warnings

## NFS Mount Points

The script automatically detects NFS mounts and verifies:
- Mount point exists
- Write permissions
- Available disk space
- Filesystem type

For NFS mounts, ensure:
1. The NFS share is mounted before running the backup
2. The mount point has write permissions
3. Sufficient space is available

Example NFS mount:
```bash
mount -t nfs nfs-server:/backups /mnt/backup/db2
```

## Database Rights Verification

The script verifies that the current user has sufficient permissions to perform backups before attempting the operation. It checks for:

1. **System Authorities**: SYSADM, SYSCTRL, or SYSMAINT
2. **Database Administrator**: DBADM authority on the target database
3. **Backup Privilege**: BACKUP DATABASE privilege on the target database

The verification process:
- Identifies the current DB2 authorization ID
- Queries system catalog tables to check authorities
- Provides detailed logging of detected permissions
- Fails early if insufficient rights are detected
- Handles cases where catalog queries may not be permitted (graceful degradation)

**Required Permissions**: The user must have at least one of the following:
- SYSADM, SYSCTRL, or SYSMAINT system authority, OR
- DBADM authority on the target database, OR
- BACKUP DATABASE privilege on the target database

## Error Handling

The script includes comprehensive error handling:
- Validates DB2 installation
- Checks configuration file
- Verifies mount points and permissions
- **Verifies database backup rights**
- Validates database connectivity
- Checks disk space
- Provides detailed error messages

## External Client Connections

The script supports backing up databases from external DB2 clients (remote machines). This is useful when:
- Running backups from a backup server
- Centralized backup management
- Network-separated environments

### Connection Types

1. **Local** (`connection_type: local`): Direct connection to local DB2 instance
2. **Cataloged** (`connection_type: cataloged`): Uses pre-cataloged database entry
3. **Non-cataloged** (`connection_type: non-cataloged`): Creates temporary catalog entries

### External Client Configuration

For **cataloged** connections:
```yaml
connection_type: cataloged
db_name: PRODUCTION
db_user: db2admin
# Database must be pre-cataloged:
# db2 catalog tcpip node <node> remote <host> server <port>
# db2 catalog database <db_name> at node <node>
```

For **non-cataloged** connections:
```yaml
connection_type: non-cataloged
db_host: db2-server.example.com
db_port: 50000
db_name: PRODUCTION
db_user: db2admin
db_password: secret  # Optional - will prompt if not set
```

**Important Notes for External Clients:**
- The `backup_path` must be accessible from the **DB2 server**, not the client
- The path must exist and be writable on the DB2 server filesystem
- Network connectivity between client and server is required
- User must have backup permissions on the remote database

## Examples

### Local full backup to NFS
```yaml
backup_type: full
backup_path: /nfs/backups/db2
db_name: PRODUCTION
connection_type: local
```

### External client backup (non-cataloged)
```yaml
backup_type: full
backup_path: /mnt/backup/db2
db_name: PRODUCTION
connection_type: non-cataloged
db_host: db2-prod.example.com
db_port: 50000
db_user: backup_user
compress: true
```

### External client backup (cataloged)
```yaml
backup_type: incremental
backup_path: /backup/db2
db_name: DEVELOPMENT
connection_type: cataloged
db_user: db2admin
```

### Incremental backup to local mount
```yaml
backup_type: incremental
backup_path: /mnt/local-backup/db2
db_name: DEVELOPMENT
compress: true
```

### Delta backup with custom settings
```yaml
backup_type: delta
backup_path: /backup/db2
db_name: TESTDB
parallelism: 8
buffer_size: 2048
retention_days: 7
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
- Verify NFS mount is active
- Ensure sufficient disk space

### Low disk space warning
- Free up space on backup destination
- Reduce retention period
- Use compression to save space

### Backup session organization
- Each backup creates a timestamped subdirectory (e.g., `20241121_114530123/`)
- Timestamps include milliseconds to prevent concurrent backup collisions
- Entire session directories are removed during cleanup (not individual files)
- To manually clean up, remove entire timestamped subdirectories under `{backup_path}/{db_name}/`

### External client connection issues
- Verify network connectivity: `ping <db_host>` and `telnet <db_host> <db_port>`
- Check DB2 server is accepting connections
- Verify database name is correct
- For cataloged connections, ensure database is properly cataloged
- For non-cataloged connections, verify hostname and port are correct
- Check firewall rules allow DB2 port (default 50000)
- Ensure backup path exists on DB2 server, not client
- Verify user credentials and permissions

## Backup Session Management

### Session Structure

Each backup execution creates a unique session directory with the following characteristics:

- **Timestamp Format**: `YYYYMMDD_HHMMSSmmm` (includes milliseconds)
  - Example: `20241121_114530123` (November 21, 2024 at 11:45:30.123)
- **Directory Path**: `{backup_path}/{db_name}/{timestamp}/`
- **File Naming**: `{db_name}_{backup_type}_{timestamp}.{sequence}`
  - Sequence numbers (.001, .002, etc.) are assigned by DB2 for multi-file backups

### Concurrent Backups

The script supports concurrent backup operations safely:

- Multiple backups of the same database can run simultaneously
- Each backup gets its own unique timestamped directory
- Millisecond precision ensures no directory name collisions
- Files from different sessions never overwrite each other

### Cleanup Behavior

The automatic cleanup process:

- Removes **entire session directories** older than the retention period
- Preserves session integrity (all files in a session are kept or removed together)
- Runs after each successful backup
- Respects the `retention_days` configuration setting

**Manual Cleanup Example:**
```bash
# Remove a specific backup session
rm -rf /mnt/backup/db2/SAMPLE/20241121_114530123/

# Remove all sessions older than 7 days
find /mnt/backup/db2/SAMPLE -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

## License

This script is provided as-is for DB2 database backup operations.

See [LICENSE](LICENSE) file for details.

