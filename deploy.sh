#!/bin/bash
# DB2 Protect Deployment Script
# This script deploys the DB2 backup solution to a target system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/db2-protect}"
DB2_USER="${DB2_USER:-db2inst1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root (for installation)
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This deployment script must run as root to install system-wide"
        log_info "Please run: sudo $0"
        exit 1
    fi
    
    # Check bash version
    if ! command -v bash &> /dev/null; then
        log_error "bash is not installed"
        exit 1
    fi
    local bash_version=$(bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    log_info "Bash version: ${bash_version}"
    
    # Check if DB2 user exists
    if ! id "${DB2_USER}" &> /dev/null; then
        log_warn "DB2 user '${DB2_USER}' not found. Please set DB2_USER environment variable."
        read -p "Enter DB2 instance owner username: " DB2_USER
        if ! id "${DB2_USER}" &> /dev/null; then
            log_error "User '${DB2_USER}' does not exist"
            exit 1
        fi
    fi
    log_info "DB2 user: ${DB2_USER}"
    
    # Check if DB2 is installed (optional check)
    if command -v db2 &> /dev/null; then
        log_info "DB2 command found: $(which db2)"
    else
        log_warn "DB2 command not found in PATH (may be OK if DB2 profile not sourced)"
    fi
    
    log_info "Prerequisites check completed"
}

create_directories() {
    log_info "Creating directory structure..."
    
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}/etc"
    mkdir -p "${INSTALL_DIR}/logs"
    mkdir -p "${INSTALL_DIR}/output"
    
    log_info "Directories created in ${INSTALL_DIR}"
}

install_files() {
    log_info "Installing files..."
    
    # Copy main script
    if [[ -f "${SCRIPT_DIR}/backup-db2.sh" ]]; then
        cp "${SCRIPT_DIR}/backup-db2.sh" "${INSTALL_DIR}/backup-db2.sh"
        chmod +x "${INSTALL_DIR}/backup-db2.sh"
        log_info "Installed: backup-db2.sh"
    else
        log_error "backup-db2.sh not found in ${SCRIPT_DIR}"
        exit 1
    fi
    
    # Copy config file if it exists, otherwise create example
    if [[ -f "${SCRIPT_DIR}/etc/backup-config.yaml" ]]; then
        if [[ ! -f "${INSTALL_DIR}/etc/backup-config.yaml" ]]; then
            cp "${SCRIPT_DIR}/etc/backup-config.yaml" "${INSTALL_DIR}/etc/backup-config.yaml"
            log_info "Installed: etc/backup-config.yaml"
        else
            log_warn "Config file already exists, skipping (backup saved to etc/backup-config.yaml.bak)"
            cp "${INSTALL_DIR}/etc/backup-config.yaml" "${INSTALL_DIR}/etc/backup-config.yaml.bak.$(date +%Y%m%d_%H%M%S)"
        fi
    else
        log_warn "No config file found, creating example..."
        create_example_config
    fi
    
    # Copy README and LICENSE if they exist
    [[ -f "${SCRIPT_DIR}/README.md" ]] && cp "${SCRIPT_DIR}/README.md" "${INSTALL_DIR}/README.md" && log_info "Installed: README.md"
    [[ -f "${SCRIPT_DIR}/LICENSE" ]] && cp "${SCRIPT_DIR}/LICENSE" "${INSTALL_DIR}/LICENSE" && log_info "Installed: LICENSE"
    
    # Copy Makefile if it exists
    [[ -f "${SCRIPT_DIR}/Makefile" ]] && cp "${SCRIPT_DIR}/Makefile" "${INSTALL_DIR}/Makefile" && log_info "Installed: Makefile"
    
    log_info "Files installed successfully"
}

create_example_config() {
    cat > "${INSTALL_DIR}/etc/backup-config.yaml" << 'EOF'
# DB2 Backup Configuration
# Edit this file to configure your backup settings

# Backup type: full, incremental, or delta
backup_type: full

# Enable compression
compress: true

# Parallelism for backup (number of parallel processes)
parallelism: 4

# Buffer size in pages (1024 = 4MB default)
buffer_size: 1024

# Backup destination path (NFS or local mount point)
# IMPORTANT: This path must exist and be writable on the DB2 server
backup_path: /mnt/backup/db2

# DB2 instance name (optional, for local connections)
# db_instance: db2inst1

# Database name to backup
db_name: SAMPLE

# Connection type: local, cataloged, or non-cataloged
connection_type: local  # local, cataloged, or non-cataloged

# For external client connections (non-cataloged):
# db_host: db2-server.example.com
# db_port: 50000
# db_user: db2admin
# db_password: secret

# Retention period in days (0 to disable automatic cleanup)
retention_days: 30
EOF
    log_info "Created example config: etc/backup-config.yaml"
}

set_permissions() {
    log_info "Setting permissions..."
    
    # Set ownership to DB2 user
    chown -R "${DB2_USER}:${DB2_USER}" "${INSTALL_DIR}"
    
    # Set directory permissions
    find "${INSTALL_DIR}" -type d -exec chmod 755 {} \;
    
    # Set script permissions
    chmod 755 "${INSTALL_DIR}/backup-db2.sh"
    
    # Config file should be readable by owner only (may contain passwords)
    chmod 600 "${INSTALL_DIR}/etc/backup-config.yaml" 2>/dev/null || chmod 644 "${INSTALL_DIR}/etc/backup-config.yaml"
    
    # Logs directory writable by owner
    chmod 755 "${INSTALL_DIR}/logs"
    
    log_info "Permissions set for user: ${DB2_USER}"
}

verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    
    # Check if script exists and is executable
    if [[ ! -f "${INSTALL_DIR}/backup-db2.sh" ]]; then
        log_error "backup-db2.sh not found"
        ((errors++))
    elif [[ ! -x "${INSTALL_DIR}/backup-db2.sh" ]]; then
        log_error "backup-db2.sh is not executable"
        ((errors++))
    else
        log_info "✓ backup-db2.sh is installed and executable"
    fi
    
    # Check if config exists
    if [[ ! -f "${INSTALL_DIR}/etc/backup-config.yaml" ]]; then
        log_warn "Config file not found (this is OK if you plan to create it manually)"
    else
        log_info "✓ Config file exists"
    fi
    
    # Check ownership
    local owner=$(stat -c '%U' "${INSTALL_DIR}" 2>/dev/null || stat -f '%Su' "${INSTALL_DIR}" 2>/dev/null)
    if [[ "${owner}" == "${DB2_USER}" ]]; then
        log_info "✓ Ownership is correct (${DB2_USER})"
    else
        log_warn "Ownership is ${owner}, expected ${DB2_USER}"
    fi
    
    if [[ ${errors} -eq 0 ]]; then
        log_info "Installation verification completed successfully"
        return 0
    else
        log_error "Installation verification found ${errors} error(s)"
        return 1
    fi
}

show_summary() {
    echo ""
    log_info "=== Deployment Summary ==="
    echo ""
    echo "Installation directory: ${INSTALL_DIR}"
    echo "DB2 user: ${DB2_USER}"
    echo ""
    echo "Next steps:"
    echo "1. Edit configuration:"
    echo "   ${INSTALL_DIR}/etc/backup-config.yaml"
    echo ""
    echo "2. Test the backup script (as ${DB2_USER}):"
    echo "   su - ${DB2_USER}"
    echo "   ${INSTALL_DIR}/backup-db2.sh"
    echo ""
    echo "3. Or use the Makefile:"
    echo "   cd ${INSTALL_DIR}"
    echo "   make backup"
    echo ""
    log_info "Deployment completed!"
}

main() {
    echo "=========================================="
    echo "  DB2 Protect Deployment Script"
    echo "=========================================="
    echo ""
    
    check_prerequisites
    create_directories
    install_files
    set_permissions
    
    if verify_installation; then
        show_summary
    else
        log_error "Deployment completed with errors. Please review the output above."
        exit 1
    fi
}

# Run main function
main "$@"

