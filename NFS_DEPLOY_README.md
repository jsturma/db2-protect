# NFS Backup Deployment Package

This package contains everything needed to deploy and configure NFS mounts for backup operations.

## Contents

- `deploy_nfs_backup.sh` - Main deployment script
- `etc/nfs-deploy-config.yaml` - Configuration file

## Prerequisites

- Root/sudo access
- Network connectivity to NFS server
- One of the following package managers: `yum`, `dnf`, or `apt-get`
- Optional: `yq` or Python 3 with `pyyaml` for better YAML parsing (fallback parser included)

## Quick Start

1. Extract the archive:
   ```bash
   tar -xzf nfs-backup-deploy.tar.gz
   cd nfs-backup-deploy
   ```

2. Edit the configuration file:
   ```bash
   vi etc/nfs-deploy-config.yaml
   ```

3. Run the deployment script as root:
   ```bash
   sudo ./deploy_nfs_backup.sh
   ```

## Configuration

Edit `etc/nfs-deploy-config.yaml` to configure your NFS deployment:

```yaml
# NFS server hostname or IP address
nfs_server: dd.demo.local

# Read-Write mount configuration (for backups)
rw_mount:
  export: /storage_unit/subdir_1
  mount_point: /dd/backup
  mode: rw

# Read-Only mount configuration (for recovery)
ro_mount:
  export: /storage_unit/subdir_1
  mount_point: /dd/recover
  mode: ro

# User and group configuration
user:
  name: backup_svc
  group: backup_svc
```

### Configuration Options

- **nfs_server**: Hostname or IP address of your NFS server
- **rw_mount.export**: NFS export path on the server (for backups)
- **rw_mount.mount_point**: Local mount point for RW access
- **rw_mount.mode**: Mount mode (typically `rw`)
- **ro_mount.export**: NFS export path on the server (for recovery)
- **ro_mount.mount_point**: Local mount point for RO access
- **ro_mount.mode**: Mount mode (typically `ro`)
- **user.name**: System user name for NFS operations
- **user.group**: System group name for NFS operations

## What the Script Does

1. **Installs NFS utilities** - Automatically detects and installs the appropriate NFS client package
2. **Creates user and group** - Creates the specified user and group if they don't exist
3. **Creates mount points** - Creates and configures mount directories with proper permissions
4. **Generates NFS server configuration** - Displays the required `/etc/exports` entry for the NFS server
5. **Updates /etc/fstab** - Adds mount entries for automatic mounting (with backup)
6. **Tests mounts** - Verifies that the user can mount both RW and RO shares

## NFS Server Configuration

After running the script, you'll see output showing what needs to be added to the NFS server's `/etc/exports` file. The script will display something like:

```
======================================================
➡️  ADD TO NFS SERVER: /etc/exports
======================================================
/storage_unit/subdir_1 *(rw,sync,no_subtree_check,all_squash,anonuid=1001,anongid=1001)

Then execute on the NFS server: exportfs -ra
======================================================
```

**Important**: You must add this entry to `/etc/exports` on the NFS server and run `exportfs -ra` before the mounts will work.

## Mount Points

The script creates two mount points:

- **RW Mount** (`/dd/backup` by default): For backup operations (read-write)
- **RO Mount** (`/dd/recover` by default): For recovery operations (read-only)

Both mounts are configured in `/etc/fstab` with the following options:
- `user` - Allows non-root users to mount
- `soft` - Soft mount (doesn't hang if server is unavailable)
- `nofail` - Don't fail boot if mount fails
- `_netdev` - Network device (mount after network is up)

## User Permissions

The specified user (`backup_svc` by default) will be able to:
- Mount and unmount both NFS shares without root privileges
- Read and write to the RW mount point
- Read from the RO mount point

## Troubleshooting

### Configuration file not found
- Ensure `etc/nfs-deploy-config.yaml` exists in the same directory as the script
- Or specify the full path to the config file

### YAML parsing errors
- Install `yq`: `yum install yq` or `apt-get install yq`
- Or install Python yaml: `pip3 install pyyaml`
- The script includes a fallback parser, but `yq` or Python yaml is recommended

### Mount failures
- Verify NFS server is accessible: `ping <nfs_server>`
- Check NFS server exports: `showmount -e <nfs_server>`
- Ensure `/etc/exports` entry was added on the NFS server
- Verify `exportfs -ra` was run on the NFS server
- Check firewall rules allow NFS traffic (ports 111, 2049)

### Permission denied
- Ensure the script is run as root: `sudo ./deploy_nfs_backup.sh`
- Verify the user has proper permissions after creation

## Files Modified

The script modifies the following system files:
- `/etc/fstab` - Adds mount entries (backup created automatically)
- Creates mount point directories
- Creates system user and group (if they don't exist)

## Uninstallation

To remove the NFS deployment:

1. Unmount the shares:
   ```bash
   umount /dd/backup
   umount /dd/recover
   ```

2. Remove entries from `/etc/fstab`:
   ```bash
   # Edit /etc/fstab and remove the NFS mount lines
   vi /etc/fstab
   ```

3. Remove mount points (optional):
   ```bash
   rmdir /dd/backup
   rmdir /dd/recover
   ```

4. Remove user and group (optional):
   ```bash
   userdel backup_svc
   groupdel backup_svc
   ```

## Support

For issues or questions, refer to the main project README or check the script logs.

