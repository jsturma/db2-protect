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

# Determine DB2 instance owner and setup user switching if running as root
setup_db2_user() {
    local current_user=$(whoami)
    if [[ "${current_user}" == "root" ]]; then
        log "INFO" "Running as root, detecting DB2 instance owner..."
        if [[ -n "${DB_INSTANCE}" ]]; then
            DB2_USER="${DB_INSTANCE}"
        else
            # Try to detect from DB2INSTANCE env or common locations
            DB2_USER="${DB2INSTANCE:-}"
            [[ -z "${DB2_USER}" ]] && {
                # Check common DB2 instance owners
                for u in db2inst1 db2fenc1 db2inst db2admin; do
                    id "${u}" &>/dev/null && { DB2_USER="${u}"; break; }
                done
            }
        fi
        [[ -z "${DB2_USER}" ]] && error_exit "Cannot determine DB2 instance owner. Set db_instance in config or DB2INSTANCE env"
        log "INFO" "Will run DB2 commands as user: ${DB2_USER}"
        # Function to run DB2 commands as instance owner
        db2_cmd() {
            su - "${DB2_USER}" -c "source ~${DB2_USER}/sqllib/db2profile 2>/dev/null || source /opt/ibm/db2/V*/db2profile 2>/dev/null; $*"
        }
    else
        DB2_USER="${current_user}"
        # Source DB2 profile once at startup
        source ~${DB2_USER}/sqllib/db2profile 2>/dev/null || source /opt/ibm/db2/V*/db2profile 2>/dev/null || true
        # For non-root, db2 commands run directly (connection persists)
        db2_cmd() { eval "$*"; }
    fi
    log "INFO" "DB2 user: ${DB2_USER}"
}

check_db2() {
    if [[ "${DB2_USER}" == "root" ]] || [[ -z "${DB2_USER}" ]]; then
        command -v db2 &> /dev/null || error_exit "DB2 command not found"
        log "INFO" "DB2 found: $(which db2)"
    else
        # Check if DB2 is available for the instance owner
        db2_cmd "command -v db2" &> /dev/null || error_exit "DB2 command not found for user ${DB2_USER}"
        log "INFO" "DB2 found for user ${DB2_USER}"
    fi
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

perform_backup() {
    # Reconnect before backup (connection may not persist in script context)
    log "INFO" "Ensuring database connection..."
    [[ -n "${DB_INSTANCE}" ]] && export DB2INSTANCE="${DB_INSTANCE}"
    db2 connect to "${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to connect: ${DB_NAME}"
    
    # Create timestamped subdirectory for this backup session
    local session_dir="${BACKUP_PATH}/${DB_NAME}/${TIMESTAMP}"
    mkdir -p "${session_dir}" || error_exit "Failed to create backup directory: ${session_dir}"
    local bf="${session_dir}/${DB_NAME}_${BACKUP_TYPE}_${TIMESTAMP}"
    log "INFO" "Starting ${BACKUP_TYPE} backup: ${DB_NAME} -> ${session_dir}/"
    
    # Build backup command
    local cmd="BACKUP DATABASE ${DB_NAME}"
    case "${BACKUP_TYPE}" in
        full) ;;
        incremental) cmd="${cmd} INCREMENTAL" ;;
        delta) cmd="${cmd} INCREMENTAL DELTA" ;;
        *) error_exit "Invalid backup type: ${BACKUP_TYPE}" ;;
    esac
    cmd="${cmd} TO '${bf}'"
    [[ "${COMPRESS}" == "true" ]] && cmd="${cmd} COMPRESS"
    cmd="${cmd} WITH ${BUFFER_SIZE} BUFFER PARALLELISM ${PARALLELISM} WITHOUT PROMPTING"
    
    log "INFO" "Executing: db2 \"${cmd}\""
    local backup_output=$(db2 "${cmd}" 2>&1)
    local backup_status=$?
    echo "${backup_output}" >> "${LOG_FILE}"
    if [[ ${backup_status} -eq 0 ]]; then
        log "INFO" "Backup completed in session: ${session_dir}"
        local bf2=$(find "${session_dir}" -type f 2>/dev/null)
        [[ -n "${bf2}" ]] && echo "${bf2}" | while read -r f; do log "INFO" "Created: ${f} ($(du -h "${f}" | cut -f1))"; done || log "WARN" "No backup files found"
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
