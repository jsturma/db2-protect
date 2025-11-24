#!/bin/bash
set -euo pipefail

###############################################
# NFS Backup Deployment Script
# This script configures NFS mounts for backup operations
# with both read-write (backup) and read-only (recover) access
###############################################

###############################################
# CONFIGURATION FILE
###############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/etc/nfs-deploy-config.yaml"

# Default config file if not found in script directory
if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/../etc/nfs-deploy-config.yaml"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[!] ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

###############################################
# HELPER FUNCTIONS
###############################################

log_info() {
    echo "[+] $*"
}

log_error() {
    echo "[!] ERROR: $*" >&2
}

log_success() {
    echo "[✓] $*"
}

# YAML parsing function - tries multiple methods
parse_yaml() {
    local key="$1"
    local yaml_file="$2"
    local value=""
    
    # Try yq first (most reliable)
    if command -v yq &>/dev/null; then
        value=$(yq eval ".$key" "$yaml_file" 2>/dev/null | sed 's/^"//;s/"$//' | sed 's/^null$//')
        if [[ -n "$value" ]] && [[ "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi
    
    # Try Python yaml module (common on most systems)
    if command -v python3 &>/dev/null; then
        if python3 -c "import yaml" 2>/dev/null; then
            value=$(python3 -c "
import yaml
import sys
try:
    with open('$yaml_file', 'r') as f:
        data = yaml.safe_load(f)
        keys = '$key'.split('.')
        result = data
        for k in keys:
            if isinstance(result, dict) and k in result:
                result = result[k]
            else:
                sys.exit(1)
        if result is not None:
            print(result)
except Exception:
    sys.exit(1)
" 2>/dev/null)
            if [[ $? -eq 0 ]] && [[ -n "$value" ]]; then
                echo "$value"
                return 0
            fi
        fi
    fi
    
    # Fallback: simple awk-based YAML parser for nested structures
    # This handles basic YAML with nested keys
    local keys=(${key//./ })
    
    if [[ ${#keys[@]} -eq 1 ]]; then
        # Simple key (no nesting)
        value=$(awk -F': ' "/^${keys[0]}:/ {gsub(/^[\"'\'' ]+|[\"'\'' ]+$/, \"\", \$2); print \$2; exit}" "$yaml_file" 2>/dev/null | head -1)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    else
        # Nested key - use awk to find parent and child
        value=$(awk -v parent="${keys[0]}" -v child="${keys[1]}" '
        BEGIN { in_parent = 0 }
        /^[^[:space:]#]/ && /:/ { 
            if (in_parent && $0 ~ "^[[:space:]]+" child ":") {
                gsub(/^[^:]*:[[:space:]]*/, "");
                gsub(/^[\"'\'' ]+|[\"'\'' ]+$/, "");
                print;
                exit;
            }
            in_parent = 0;
        }
        $0 ~ "^" parent ":" { in_parent = 1; next }
        in_parent && /^[[:space:]]+/ && !/^[[:space:]]*#/ {
            if ($0 ~ child ":") {
                gsub(/^[^:]*:[[:space:]]*/, "");
                gsub(/^[\"'\'' ]+|[\"'\'' ]+$/, "");
                print;
                exit;
            }
        }
        ' "$yaml_file" 2>/dev/null)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi
    
    return 1
}

# Load configuration from YAML file
load_config() {
    log_info "Loading configuration from: $CONFIG_FILE"
    
    # Read configuration values
    NFS_SERVER=$(parse_yaml "nfs_server" "$CONFIG_FILE" || echo "")
    EXPORT1=$(parse_yaml "rw_mount.export" "$CONFIG_FILE" || echo "")
    MOUNT1=$(parse_yaml "rw_mount.mount_point" "$CONFIG_FILE" || echo "")
    MODE1=$(parse_yaml "rw_mount.mode" "$CONFIG_FILE" || echo "")
    EXPORT2=$(parse_yaml "ro_mount.export" "$CONFIG_FILE" || echo "")
    MOUNT2=$(parse_yaml "ro_mount.mount_point" "$CONFIG_FILE" || echo "")
    MODE2=$(parse_yaml "ro_mount.mode" "$CONFIG_FILE" || echo "")
    USER_NAME=$(parse_yaml "user.name" "$CONFIG_FILE" || echo "")
    GROUP_NAME=$(parse_yaml "user.group" "$CONFIG_FILE" || echo "")
    
    # Validate required variables
    local missing_vars=()
    [[ -z "$NFS_SERVER" ]] && missing_vars+=("nfs_server")
    [[ -z "$EXPORT1" ]] && missing_vars+=("rw_mount.export")
    [[ -z "$MOUNT1" ]] && missing_vars+=("rw_mount.mount_point")
    [[ -z "$MODE1" ]] && missing_vars+=("rw_mount.mode")
    [[ -z "$EXPORT2" ]] && missing_vars+=("ro_mount.export")
    [[ -z "$MOUNT2" ]] && missing_vars+=("ro_mount.mount_point")
    [[ -z "$MODE2" ]] && missing_vars+=("ro_mount.mode")
    [[ -z "$USER_NAME" ]] && missing_vars+=("user.name")
    [[ -z "$GROUP_NAME" ]] && missing_vars+=("user.group")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables:"
        printf "  - %s\n" "${missing_vars[@]}" >&2
        log_error "Please check your configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    log_success "Configuration loaded successfully"
    log_info "  NFS Server: $NFS_SERVER"
    log_info "  RW Mount: $EXPORT1 -> $MOUNT1 ($MODE1)"
    log_info "  RO Mount: $EXPORT2 -> $MOUNT2 ($MODE2)"
    log_info "  User: $USER_NAME (Group: $GROUP_NAME)"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

detect_package_manager() {
    if command -v yum &>/dev/null; then
        echo "yum"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    else
        log_error "No supported package manager found (yum, apt-get, or dnf)"
        exit 1
    fi

}

install_nfs_utils() {
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    log_info "Installing NFS utilities using $pkg_manager"
    
    case "$pkg_manager" in
        yum|dnf)
            "$pkg_manager" install -y nfs-utils
            ;;
        apt)
            apt-get update -qq
            apt-get install -y nfs-common
            ;;
    esac
    
    if ! command -v mount.nfs &>/dev/null; then
        log_error "NFS utilities installation failed"
        exit 1
    fi
    
    log_success "NFS utilities installed successfully"
}

create_user() {
    if ! id "$USER_NAME" &>/dev/null; then
        log_info "Creating user: $USER_NAME"
        if ! useradd -m -s /bin/bash "$USER_NAME"; then
            log_error "Failed to create user $USER_NAME"
            exit 1
        fi
        log_success "User $USER_NAME created"
    else
        log_info "User $USER_NAME already exists"
    fi
    
    # Verify group exists
    if ! getent group "$GROUP_NAME" &>/dev/null; then
        log_info "Creating group: $GROUP_NAME"
        if ! groupadd "$GROUP_NAME"; then
            log_error "Failed to create group $GROUP_NAME"
            exit 1
        fi
        # Add user to group if not already a member
        usermod -aG "$GROUP_NAME" "$USER_NAME" || true
    fi
}

create_mount_points() {
    log_info "Creating mount points"
    
    for DIR in "$MOUNT1" "$MOUNT2"; do
        if [[ ! -d "$DIR" ]]; then
            mkdir -p "$DIR"
            log_info "Created directory: $DIR"
        else
            log_info "Directory already exists: $DIR"
        fi
        
        if ! chown "$USER_NAME:$GROUP_NAME" "$DIR"; then
            log_error "Failed to set ownership for $DIR"
            exit 1
        fi
        
        if ! chmod 700 "$DIR"; then
            log_error "Failed to set permissions for $DIR"
            exit 1
        fi
    done
    
    log_success "Mount points created and configured"
}

generate_export_config() {
    log_info "Generating NFS server export configuration"
    
    local user_uid user_gid
    user_uid=$(id -u "$USER_NAME")
    user_gid=$(id -g "$GROUP_NAME")
    
    if [[ -z "$user_uid" ]] || [[ -z "$user_gid" ]]; then
        log_error "Failed to get UID/GID for user $USER_NAME"
        exit 1
    fi
    
    local export_line="${EXPORT1} *(rw,sync,no_subtree_check,all_squash,anonuid=${user_uid},anongid=${user_gid})"
    
    echo
    echo "======================================================"
    echo "➡️  ADD TO NFS SERVER: /etc/exports"
    echo "======================================================"
    echo "$export_line"
    echo
    echo "Then execute on the NFS server: exportfs -ra"
    echo "======================================================"
    echo
}

update_fstab() {
    log_info "Updating /etc/fstab"
    
    # Create backup of fstab
    cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
    log_info "Backup created: /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
    
    local fstab1="${NFS_SERVER}:${EXPORT1}  ${MOUNT1}  nfs  ${MODE1},user,soft,nofail,_netdev  0  0"
    local fstab2="${NFS_SERVER}:${EXPORT2}  ${MOUNT2}  nfs  ${MODE2},user,soft,nofail,_netdev  0  0"
    
    # Check if entries already exist (more robust check)
    if ! grep -qE "^[^#]*${MOUNT1}[[:space:]]" /etc/fstab; then
        echo "$fstab1" >> /etc/fstab
        log_success "Added RW mount entry to /etc/fstab"
    else
        log_info "RW mount entry already exists in /etc/fstab"
    fi
    
    if ! grep -qE "^[^#]*${MOUNT2}[[:space:]]" /etc/fstab; then
        echo "$fstab2" >> /etc/fstab
        log_success "Added RO mount entry to /etc/fstab"
    else
        log_info "RO mount entry already exists in /etc/fstab"
    fi
}

test_mounts() {
    log_info "Testing mounts as user: $USER_NAME"
    
    # Check if already mounted
    if mountpoint -q "$MOUNT1" 2>/dev/null; then
        log_info "RW mount $MOUNT1 is already mounted"
    else
        log_info "Testing RW mount: $MOUNT1"
        if ! su - "$USER_NAME" -c "mount $MOUNT1" 2>&1; then
            log_error "Failed to mount RW share at $MOUNT1"
            log_error "Please verify NFS server configuration and network connectivity"
            exit 1
        fi
        log_success "RW mount successful"
    fi
    
    if mountpoint -q "$MOUNT2" 2>/dev/null; then
        log_info "RO mount $MOUNT2 is already mounted"
    else
        log_info "Testing RO mount: $MOUNT2"
        if ! su - "$USER_NAME" -c "mount $MOUNT2" 2>&1; then
            log_error "Failed to mount RO share at $MOUNT2"
            log_error "Please verify NFS server configuration and network connectivity"
            exit 1
        fi
        log_success "RO mount successful"
    fi
}

###############################################
# MAIN EXECUTION
###############################################

main() {
    echo "======================================================"
    echo "NFS Backup Deployment Script"
    echo "======================================================"
    echo
    
    # Load configuration first
    load_config
    
    check_root
    install_nfs_utils
    create_user
    create_mount_points
    generate_export_config
    update_fstab
    test_mounts
    
    echo
    echo "======================================================"
    log_success "Deployment completed successfully!"
    log_success "$USER_NAME can mount RW on: $MOUNT1"
    log_success "$USER_NAME can mount RO on: $MOUNT2"
    echo "======================================================"
}

main "$@"
