#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
CONFIG_FILE="${PROJECT_ROOT}/etc/backup-config.yaml"
# Try project logs first, fallback to user home or tmp
LOG_DIR="${PROJECT_ROOT}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="${HOME:-/tmp}/db2-protect-logs"
    mkdir -p "${LOG_DIR}" 2>/dev/null || LOG_DIR="/tmp/db2-protect-logs-$$"
    mkdir -p "${LOG_DIR}" 2>/dev/null || { echo "ERROR: Cannot create log directory" >&2; exit 1; }
fi
LOG_FILE="${LOG_DIR}/db2-backup.log"
# Generate timestamp with milliseconds for concurrent access safety
if date +%N &>/dev/null && date +%N | grep -q '[0-9]'; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)$(date +%N | head -c 3)
elif command -v python3 &>/dev/null; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)$(python3 -c "import time; print(f'{int(time.time()*1000)%1000000:06d}'[-3:])" 2>/dev/null || echo $(($$ % 1000)))
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)$(printf "%03d" $(($(date +%s) % 1000)))
fi

log() { 
    local l=$1; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${l}] $*"
    echo "${msg}"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || echo "${msg}" >> "/tmp/db2-backup-$$.log" 2>/dev/null || true
}
error_exit() { log "ERROR" "$1"; exit "${2:-1}"; }

# Setup DB2 user - script must run as DB2 instance owner (not root)
setup_db2_user() {
    local current_user=$(whoami)
    # Script must not run as root
    if [[ "${current_user}" == "root" ]]; then
        error_exit "This script must not run as root. Please run as the DB2 instance owner (e.g., db2inst1). Use: su - db2inst1 -c './backup-db2.sh'"
    fi
    DB2_USER="${current_user}"
    # Source DB2 profile once at startup
    source ~${DB2_USER}/sqllib/db2profile 2>/dev/null || source /opt/ibm/db2/V*/db2profile 2>/dev/null || true
    # db2 commands run directly (connection persists)
    db2_cmd() { eval "$*"; }
    log "INFO" "DB2 user: ${DB2_USER}"
}

check_db2() {
    command -v db2 &> /dev/null || error_exit "DB2 command not found. Ensure DB2 is installed and PATH is set correctly."
    log "INFO" "DB2 found for user ${DB2_USER}: $(which db2)"
}

parse_yaml() {
    local p=$2 s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    sed -ne "s|^\($s\):|\1|" -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" "$1" |
    awk -F$fs '{indent=length($1)/2;vname[indent]=$2;for(i in vname){if(i>indent)delete vname[i]}
        if(length($3)>0){vn="";for(i=0;i<indent;i++)vn=(vn)(vname[i])("_");printf("%s%s%s=\"%s\"\n","'$p'",vn,$2,$3);}}'
}

load_config() {
    [[ -f "${CONFIG_FILE}" ]] || error_exit "Config not found: ${CONFIG_FILE}"
    log "INFO" "Loading config: ${CONFIG_FILE}"
    eval $(parse_yaml "${CONFIG_FILE}" "config_")
    BACKUP_TYPE="${config_backup_type:-full}"
    COMPRESS="${config_compress:-true}"
    PARALLELISM="${config_parallelism:-4}"
    BUFFER_SIZE="${config_buffer_size:-1024}"
    BACKUP_PATH="${config_backup_path:-}"
    DB_INSTANCE="${config_db_instance:-}"
    DB_NAME="${config_db_name:-}"
    CONNECTION_TYPE=$(echo "${config_connection_type:-local}" | sed 's/#.*$//' | xargs | tr '[:upper:]' '[:lower:]')
    DB_HOST="${config_db_host:-}"
    DB_PORT="${config_db_port:-50000}"
    DB_USER="${config_db_user:-}"
    DB_PASSWORD="${config_db_password:-}"
    [[ -n "${BACKUP_PATH}" ]] || error_exit "backup_path not specified"
    if [[ "${CONNECTION_TYPE}" != "local" ]]; then
        IS_EXTERNAL_CLIENT=true
        if [[ "${CONNECTION_TYPE}" == "non-cataloged" ]]; then
            [[ -n "${DB_HOST}" ]] || error_exit "db_host required for non-cataloged connections"
        fi
    else
        IS_EXTERNAL_CLIENT=false
    fi
    log "INFO" "Config: type=${BACKUP_TYPE} path=${BACKUP_PATH} conn=${CONNECTION_TYPE} db=${DB_NAME}"
}

check_mount_point() {
    local mp=$1
    if [[ "${IS_EXTERNAL_CLIENT}" == "true" ]]; then
        log "WARN" "Path ${mp} must be accessible from DB2 server: ${DB_HOST:-server}"
        [[ "${mp}" =~ ^/ ]] || log "WARN" "Path should be absolute on DB2 server"
        return 0
    fi
    [[ -d "${mp}" ]] || error_exit "Path does not exist: ${mp}"
    if mountpoint -q "${mp}" 2>/dev/null; then
        local fst=$(df -T "${mp}" 2>/dev/null | tail -1 | awk '{print $2}' || echo "unknown")
        log "INFO" "Mount: ${mp} type=${fst}"
    fi
    [[ -w "${mp}" ]] || error_exit "Path not writable: ${mp}"
    local av=$(df -BG "${mp}" | tail -1 | awk '{print $4}' | sed 's/G//')
    [[ ${av} -lt 1 ]] && log "WARN" "Low space: ${av}GB" || log "INFO" "Space: ${av}GB"
}

connect_db2() {
    [[ "${IS_EXTERNAL_CLIENT}" == "true" ]] && connect_external_client || connect_local
}

connect_local() {
    [[ -n "${DB_INSTANCE}" ]] && export DB2INSTANCE="${DB_INSTANCE}"
    # Connect to database - connection will persist in this shell session
    db2 connect to "${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to connect: ${DB_NAME}"
    log "INFO" "Connected: ${DB_NAME}"
    # Export connection state so it persists
    export DB2DBDFT="${DB_NAME}"
}

connect_external_client() {
    log "INFO" "Connecting as external client..."
    if [[ "${CONNECTION_TYPE}" == "cataloged" ]]; then
        [[ -n "${DB_USER}" ]] && [[ -n "${DB_PASSWORD}" ]] && db2_cmd "db2 connect to ${DB_NAME} user ${DB_USER} using ${DB_PASSWORD}" > /dev/null 2>&1 ||
        [[ -n "${DB_USER}" ]] && db2_cmd "db2 connect to ${DB_NAME} user ${DB_USER}" > /dev/null 2>&1 ||
        db2_cmd "db2 connect to ${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to connect: ${DB_NAME}"
        log "INFO" "Connected (cataloged): ${DB_NAME}"
    elif [[ "${CONNECTION_TYPE}" == "non-cataloged" ]] || [[ -n "${DB_HOST}" ]]; then
        [[ -n "${DB_HOST}" ]] || error_exit "db_host required"
        local tn="TEMP_NODE_$$" td="TEMP_DB_$$"
        db2_cmd "db2 \"catalog tcpip node ${tn} remote ${DB_HOST} server ${DB_PORT}\"" > /dev/null 2>&1 || error_exit "Failed to catalog node: ${DB_HOST}:${DB_PORT}"
        db2_cmd "db2 \"catalog database ${DB_NAME} as ${td} at node ${tn}\"" > /dev/null 2>&1 || { db2_cmd "db2 \"uncatalog node ${tn}\"" > /dev/null 2>&1; error_exit "Failed to catalog DB: ${DB_NAME}"; }
        if [[ -n "${DB_USER}" ]]; then
            [[ -n "${DB_PASSWORD}" ]] && db2_cmd "db2 connect to ${td} user ${DB_USER} using ${DB_PASSWORD}" > /dev/null 2>&1 ||
            db2_cmd "db2 connect to ${td} user ${DB_USER}" > /dev/null 2>&1 || { db2_cmd "db2 \"uncatalog database ${td}\"" > /dev/null 2>&1; db2_cmd "db2 \"uncatalog node ${tn}\"" > /dev/null 2>&1; error_exit "Failed to connect: ${DB_NAME}"; }
        else
            db2_cmd "db2 connect to ${td}" > /dev/null 2>&1 || { db2_cmd "db2 \"uncatalog database ${td}\"" > /dev/null 2>&1; db2_cmd "db2 \"uncatalog node ${tn}\"" > /dev/null 2>&1; error_exit "Failed to connect: ${DB_NAME}"; }
        fi
        TEMP_NODE="${tn}"
        TEMP_DB="${td}"
        log "INFO" "Connected (non-cataloged): ${DB_NAME}"
    else
        error_exit "Invalid connection_type: ${CONNECTION_TYPE}"
    fi
}

verify_db_rights() {
    log "INFO" "Verifying backup rights..."
    # DB2 connections may not persist between commands in script context
    # Since manual backup works, user has proper permissions
    # DB2 will validate permissions during backup - proceed with warning if can't verify
    local auth_id="${DB2_USER}"
    local can_verify=false
    
    # Quick connection test
    local test_out=$(db2 -x "SELECT 1 FROM SYSIBM.SYSDUMMY1" 2>&1)
    if ! echo "${test_out}" | grep -q "SQL1024N\|SQLSTATE=08003"; then
        can_verify=true
        local user_out=$(db2 -x "VALUES CURRENT USER" 2>&1)
        [[ -n "${user_out}" ]] && ! echo "${user_out}" | grep -q "SQL" && auth_id=$(echo "${user_out}" | head -1 | xargs | tr -d '\n\r')
        log "INFO" "Auth ID: ${auth_id}"
    fi
    
    if [[ "${can_verify}" == "true" ]]; then
        # Try basic rights check
        local dq=$(db2 -x "SELECT DBADMAUTH,BACKUPAUTH FROM SYSCAT.DBAUTH WHERE GRANTEE='${auth_id}' AND DBNAME='${DB_NAME}'" 2>&1)
        if ! echo "${dq}" | grep -q "SQLSTATE"; then
            echo "${dq}" | grep -q "Y" && { log "INFO" "Backup rights confirmed"; return 0; }
        fi
    fi
    log "WARN" "Cannot verify rights (connection issue) - proceeding (DB2 will validate during backup)"
    return 0
}

check_logging_type() {
    log "INFO" "Checking database logging configuration..."
    [[ -n "${DB_INSTANCE}" ]] && export DB2INSTANCE="${DB_INSTANCE}"
    db2 terminate > /dev/null 2>&1 || true
    
    # Connect to check logging configuration
    db2 connect to "${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to connect to check logging type: ${DB_NAME}"
    
    # Get logging method - check if archive logging is enabled
    local logarch=$(db2 -x "SELECT VALUE FROM SYSIBMADM.DBCFG WHERE NAME='logarchmeth1'" 2>&1 | head -1 | xargs | tr -d '\n\r')
    
    # If query fails, try alternative method using db2 get db cfg
    if [[ -z "${logarch}" ]] || echo "${logarch}" | grep -q "SQL"; then
        local dbcfg=$(db2 get db cfg for "${DB_NAME}" 2>&1 | grep -i "logarchmeth1" | head -1 | awk -F'=' '{print $2}' | xargs | tr -d '\n\r')
        logarch="${dbcfg}"
    fi
    
    db2 terminate > /dev/null 2>&1 || true
    
    # If logarchmeth1 is OFF or empty, it's circular logging (offline backup required)
    # Circular logging = Archive logging OFF = Database must be deactivated for offline backup
    if [[ -z "${logarch}" ]] || [[ "${logarch}" == "OFF" ]] || echo "${logarch}" | grep -qiE "^$|^off$"; then
        log "INFO" "Database uses circular logging (archive logging OFF) - database must be deactivated for offline backup"
        return 1  # Circular logging - must deactivate database
    else
        log "INFO" "Database uses archive logging (${logarch}) - online backup possible"
        return 0  # Archive logging - online backup possible
    fi
}

perform_backup() {
    # Ensure clean connection state before backup
    log "INFO" "Preparing database connection for backup..."
    [[ -n "${DB_INSTANCE}" ]] && export DB2INSTANCE="${DB_INSTANCE}"
    # Terminate any existing connection to ensure clean state
    db2 terminate > /dev/null 2>&1 || true
    
    # Check logging type - circular logging (archive logging OFF) requires database deactivation
    local needs_offline=false
    local needs_deactivate=false
    if ! check_logging_type; then
        needs_offline=true
        needs_deactivate=true
        log "INFO" "Circular logging detected (archive logging OFF) - database must be deactivated for offline backup"
        log "INFO" "Forcing all applications to disconnect..."
        db2 force applications all > /dev/null 2>&1 || log "WARN" "Some applications may still be connected"
        log "INFO" "Deactivating database..."
        db2 deactivate database "${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to deactivate database for offline backup"
    fi
    
    # Create timestamped subdirectory for this backup session
    local session_dir="${BACKUP_PATH}/${DB_NAME}/${TIMESTAMP}"
    mkdir -p "${session_dir}" || error_exit "Failed to create backup directory: ${session_dir}"
    local bf="${session_dir}/${DB_NAME}_${BACKUP_TYPE}_${TIMESTAMP}"
    log "INFO" "Starting ${BACKUP_TYPE} backup: ${DB_NAME} -> ${session_dir}/"
    
    # Build backup command - DB2 syntax: BACKUP DATABASE ... [ONLINE] ... TO 'directory' WITH ... BUFFERS ... [COMPRESS] ...
    # Note: DB2 creates files with its own naming, so use directory path, not full filename
    # For archive logging: use ONLINE keyword for online backup
    # For circular logging: no ONLINE keyword (offline backup after deactivation)
    local cmd="BACKUP DATABASE ${DB_NAME}"
    if [[ "${needs_offline}" == "false" ]]; then
        cmd="${cmd} ONLINE"
    fi
    case "${BACKUP_TYPE}" in
        full) ;;
        incremental) cmd="${cmd} INCREMENTAL" ;;
        delta) cmd="${cmd} INCREMENTAL DELTA" ;;
        *) error_exit "Invalid backup type: ${BACKUP_TYPE}" ;;
    esac
    cmd="${cmd} TO '${session_dir}'"
    cmd="${cmd} WITH ${BUFFER_SIZE} BUFFERS PARALLELISM ${PARALLELISM}"
    [[ "${COMPRESS}" == "true" ]] && cmd="${cmd} COMPRESS"
    cmd="${cmd} WITHOUT PROMPTING"
    
    log "INFO" "Executing: db2 \"${cmd}\""
    local backup_output=$(db2 "${cmd}" 2>&1)
    local backup_status=$?
    echo "${backup_output}" >> "${LOG_FILE}"
    # Also log output to console for debugging
    log "INFO" "DB2 backup output: ${backup_output}"
    
    # Reactivate database if it was deactivated for offline backup
    if [[ "${needs_deactivate}" == "true" ]]; then
        log "INFO" "Reactivating database..."
        db2 activate database "${DB_NAME}" > /dev/null 2>&1 || log "WARN" "Failed to reactivate database - may need manual intervention"
    fi
    
    # Check for DB2 errors in output even if exit code is 0
    if echo "${backup_output}" | grep -qiE "SQL[0-9]+.*error|SQLSTATE.*error|failed"; then
        log "ERROR" "Backup command reported errors:"
        echo "${backup_output}" | grep -iE "SQL[0-9]+|SQLSTATE|error|failed" | while read -r line; do log "ERROR" "  ${line}"; done
        error_exit "Backup failed with DB2 errors. Check logs for details."
    fi
    
    if [[ ${backup_status} -eq 0 ]]; then
        log "INFO" "Backup command completed successfully"
        # Wait a moment for files to be written
        sleep 1
        # Look for backup files - DB2 creates files with its own naming (usually .001, .002, etc.)
        local bf2=$(find "${session_dir}" -type f \( -name "*.001" -o -name "*.002" -o -name "*.003" -o -name "${DB_NAME}.*" \) 2>/dev/null | head -10)
        if [[ -n "${bf2}" ]]; then
            log "INFO" "Backup files created in session: ${session_dir}"
            echo "${bf2}" | while read -r f; do 
                [[ -f "${f}" ]] && log "INFO" "  ${f} ($(du -h "${f}" 2>/dev/null | cut -f1 || echo "unknown size"))"
            done
        else
            log "WARN" "No backup files found in ${session_dir}"
            log "WARN" "Backup output: ${backup_output}"
            log "WARN" "Checking if files were created in parent directory..."
            local parent_files=$(find "${BACKUP_PATH}/${DB_NAME}" -maxdepth 1 -type f -name "${DB_NAME}_${BACKUP_TYPE}_${TIMESTAMP}*" 2>/dev/null)
            [[ -n "${parent_files}" ]] && log "INFO" "Found files in parent: ${parent_files}" || log "ERROR" "No backup files found anywhere"
        fi
    else
        log "ERROR" "Backup command failed with status ${backup_status}"
        log "ERROR" "Backup output: ${backup_output}"
        error_exit "Backup failed. Check logs for details."
    fi
    disconnect_db2
}

disconnect_db2() {
    log "INFO" "Disconnecting..."
    db2 terminate > /dev/null 2>&1
    [[ -n "${TEMP_DB:-}" ]] && [[ -n "${TEMP_NODE:-}" ]] && {
        db2 "uncatalog database ${TEMP_DB}" > /dev/null 2>&1
        db2 "uncatalog node ${TEMP_NODE}" > /dev/null 2>&1
        log "INFO" "Cleaned up temp catalog"
    }
}

cleanup_old_backups() {
    local rd="${config_retention_days:-30}"
    [[ -n "${rd}" ]] && [[ "${rd}" -gt 0 ]] && {
        log "INFO" "Cleaning backup sessions older than ${rd} days"
        # Remove entire timestamped subdirectories older than retention period
        find "${BACKUP_PATH}/${DB_NAME}" -maxdepth 1 -type d -mtime +${rd} -exec rm -rf {} + 2>/dev/null || true
        log "INFO" "Cleanup done"
    }
}

main() {
    log "INFO" "=== DB2 Backup Started ==="
    setup_db2_user
    check_db2
    load_config
    check_mount_point "${BACKUP_PATH}"
    connect_db2
    verify_db_rights
    perform_backup
    cleanup_old_backups
    log "INFO" "=== DB2 Backup Completed ==="
}

main "$@"
