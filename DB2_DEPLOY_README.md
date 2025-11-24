# DB2 Backup Deployment Package

This package contains everything needed to deploy the DB2 backup solution system-wide.

## Contents

- `deploy.sh` - Main deployment script
- `backup-db2.sh` - DB2 backup script
- `etc/backup-config.yaml` - Configuration file
- `Makefile` - Makefile for easy operations
- `README.md` - Full documentation
- `LICENSE` - MIT License

## Prerequisites

- Root/sudo access (for deployment)
- DB2 installed and configured
- DB2 instance owner user exists (default: `db2inst1`)
- Bash 4.0 or higher

## Quick Start

1. Extract the archive:
   ```bash
   tar -xzf db2-backup-deploy.tar.gz
   cd db2-backup-deploy
   ```

2. Run the deployment script as root:
   ```bash
   sudo ./deploy.sh
   ```

   Or with custom settings:
   ```bash
   sudo INSTALL_DIR=/opt/db2-protect DB2_USER=db2inst1 ./deploy.sh
   ```

3. Edit the configuration:
   ```bash
   sudo vi /opt/db2-protect/etc/backup-config.yaml
   ```

4. Run backup (as DB2 user):
   ```bash
   su - db2inst1
   /opt/db2-protect/backup-db2.sh
   ```

## What the Deployment Script Does

1. **Checks prerequisites** - Verifies bash version, DB2 user, and DB2 installation
2. **Creates directory structure** - Sets up installation directory with subdirectories
3. **Installs files** - Copies all scripts and configuration files
4. **Sets permissions** - Configures ownership and permissions for DB2 user
5. **Verifies installation** - Checks that everything was installed correctly

## Installation Directory

By default, files are installed to `/opt/db2-protect`. You can customize this:

```bash
sudo INSTALL_DIR=/custom/path ./deploy.sh
```

The installation creates:
```
/opt/db2-protect/
├── backup-db2.sh          # Main backup script
├── etc/
│   └── backup-config.yaml # Configuration file
├── logs/                  # Log directory
├── output/                # Output directory
├── README.md              # Documentation
├── LICENSE                # License file
└── Makefile              # Makefile for operations
```

## Configuration

After deployment, edit the configuration file:

```bash
sudo vi /opt/db2-protect/etc/backup-config.yaml
```

See `DB2_BACKUP_README.md` or `README.md` for detailed configuration options.

## Usage After Deployment

### Using Makefile

```bash
cd /opt/db2-protect
make backup    # Run backup
make help      # Show help
```

### Direct Execution

```bash
# As DB2 instance owner (NOT root)
su - db2inst1
/opt/db2-protect/backup-db2.sh
```

## Customization

### Custom Installation Directory

```bash
sudo INSTALL_DIR=/usr/local/db2-backup ./deploy.sh
```

### Custom DB2 User

```bash
sudo DB2_USER=myuser ./deploy.sh
```

### Both Custom

```bash
sudo INSTALL_DIR=/opt/custom DB2_USER=myuser ./deploy.sh
```

## Verification

The deployment script automatically verifies the installation. You can manually verify:

```bash
# Check script exists and is executable
ls -l /opt/db2-protect/backup-db2.sh

# Check configuration exists
ls -l /opt/db2-protect/etc/backup-config.yaml

# Check ownership
ls -ld /opt/db2-protect
```

## Permissions

After deployment:
- All files are owned by the DB2 user
- Scripts are executable (755)
- Configuration file is readable by owner (600 or 644)
- Logs directory is writable by owner

## Troubleshooting

### Deployment fails with "DB2 user not found"
- Ensure the DB2 instance owner exists
- Or specify the user: `sudo DB2_USER=youruser ./deploy.sh`

### Permission denied errors
- Ensure you're running as root: `sudo ./deploy.sh`
- Check that the installation directory is writable

### DB2 command not found during deployment
- This is a warning, not an error
- The script will still deploy successfully
- Ensure DB2 is properly configured before running backups

### Configuration file already exists
- The deployment script will backup the existing config
- Check for `.bak` files in the `etc/` directory

## Uninstallation

To remove the deployment:

1. Remove the installation directory:
   ```bash
   sudo rm -rf /opt/db2-protect
   ```

2. Remove any cron jobs or scheduled tasks that reference the script

3. Remove any systemd services (if created separately)

## Next Steps

After deployment:

1. **Configure backup settings** - Edit `/opt/db2-protect/etc/backup-config.yaml`
2. **Test backup** - Run a test backup as the DB2 user
3. **Schedule backups** - Set up cron jobs or systemd timers
4. **Monitor logs** - Check `/opt/db2-protect/logs/db2-backup.log`

## Scheduling Backups

### Using Cron

Add to crontab (as DB2 user):
```bash
crontab -e
# Add line:
0 2 * * * /opt/db2-protect/backup-db2.sh >> /opt/db2-protect/logs/cron.log 2>&1
```

### Using Systemd Timer

Create `/etc/systemd/system/db2-backup.service`:
```ini
[Unit]
Description=DB2 Backup
After=network.target

[Service]
Type=oneshot
User=db2inst1
ExecStart=/opt/db2-protect/backup-db2.sh
```

Create `/etc/systemd/system/db2-backup.timer`:
```ini
[Unit]
Description=Daily DB2 Backup

[Timer]
OnCalendar=daily
OnCalendar=02:00

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl enable db2-backup.timer
sudo systemctl start db2-backup.timer
```

## Support

For detailed backup script documentation, see `README.md` or `DB2_BACKUP_README.md`.

