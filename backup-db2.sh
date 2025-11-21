#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/etc/backup-config.yaml"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/db2-backup.log"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "${LOG_DIR}"

log() { local l=$1; shift; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${l}] $*" | tee -a "${LOG_FILE}"; }
error_exit() { log "ERROR" "$1"; exit "${2:-1}"; }

check_db2() {
    command -v db2 &> /dev/null || error_exit "DB2 command not found"
    log "INFO" "DB2 found: $(which db2)"
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
    CONNECTION_TYPE="${config_connection_type:-local}"
    DB_HOST="${config_db_host:-}"
    DB_PORT="${config_db_port:-50000}"
    DB_USER="${config_db_user:-}"
    DB_PASSWORD="${config_db_password:-}"
    [[ -n "${BACKUP_PATH}" ]] || error_exit "backup_path not specified"
    if [[ "${CONNECTION_TYPE}" != "local" ]] || [[ -n "${DB_HOST}" ]]; then
        IS_EXTERNAL_CLIENT=true
        [[ -n "${DB_HOST}" ]] || [[ "${CONNECTION_TYPE}" == "cataloged" ]] || error_exit "db_host required for non-cataloged"
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
    db2 connect to "${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to connect: ${DB_NAME}"
    log "INFO" "Connected: ${DB_NAME}"
}

connect_external_client() {
    log "INFO" "Connecting as external client..."
    if [[ "${CONNECTION_TYPE}" == "cataloged" ]]; then
        [[ -n "${DB_USER}" ]] && [[ -n "${DB_PASSWORD}" ]] && db2 connect to "${DB_NAME}" user "${DB_USER}" using "${DB_PASSWORD}" > /dev/null 2>&1 ||
        [[ -n "${DB_USER}" ]] && db2 connect to "${DB_NAME}" user "${DB_USER}" > /dev/null 2>&1 ||
        db2 connect to "${DB_NAME}" > /dev/null 2>&1 || error_exit "Failed to connect: ${DB_NAME}"
        log "INFO" "Connected (cataloged): ${DB_NAME}"
    elif [[ "${CONNECTION_TYPE}" == "non-cataloged" ]] || [[ -n "${DB_HOST}" ]]; then
        [[ -n "${DB_HOST}" ]] || error_exit "db_host required"
        local tn="TEMP_NODE_$$" td="TEMP_DB_$$"
        db2 "catalog tcpip node ${tn} remote ${DB_HOST} server ${DB_PORT}" > /dev/null 2>&1 || error_exit "Failed to catalog node: ${DB_HOST}:${DB_PORT}"
        db2 "catalog database ${DB_NAME} as ${td} at node ${tn}" > /dev/null 2>&1 || { db2 "uncatalog node ${tn}" > /dev/null 2>&1; error_exit "Failed to catalog DB: ${DB_NAME}"; }
        if [[ -n "${DB_USER}" ]]; then
            [[ -n "${DB_PASSWORD}" ]] && db2 connect to "${td}" user "${DB_USER}" using "${DB_PASSWORD}" > /dev/null 2>&1 ||
            db2 connect to "${td}" user "${DB_USER}" > /dev/null 2>&1 || { db2 "uncatalog database ${td}" > /dev/null 2>&1; db2 "uncatalog node ${tn}" > /dev/null 2>&1; error_exit "Failed to connect: ${DB_NAME}"; }
        else
            db2 connect to "${td}" > /dev/null 2>&1 || { db2 "uncatalog database ${td}" > /dev/null 2>&1; db2 "uncatalog node ${tn}" > /dev/null 2>&1; error_exit "Failed to connect: ${DB_NAME}"; }
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
    local auth_id=$(db2 "VALUES CURRENT USER" 2>&1 | grep -v "^$" | tail -n +4 | head -n 1 | xargs | tr -d '\n\r')
    [[ -z "${auth_id}" ]] || [[ "${auth_id}" =~ SQLSTATE ]] && auth_id=$(db2 "VALUES USER" 2>&1 | grep -v "^$" | tail -n +4 | head -n 1 | xargs | tr -d '\n\r')
    [[ -z "${auth_id}" ]] || [[ "${auth_id}" =~ SQLSTATE ]] && { auth_id="${USER:-$(whoami)}"; log "WARN" "Using fallback auth: ${auth_id}"; } || log "INFO" "Auth ID: ${auth_id}"
    local has_sys=false has_dbadm=false has_backup=false errs=0
    local sq=$(db2 "SELECT AUTHORIZATION FROM TABLE(SYSPROC.AUTH_LIST_AUTHORITIES_FOR_AUTHID('${auth_id}', 'U')) AS T" 2>&1)
    echo "${sq}" | grep -qiE "(SYSADM|SYSCTRL|SYSMAINT)" && { has_sys=true; log "INFO" "System authority: $(echo "${sq}" | grep -iE "(SYSADM|SYSCTRL|SYSMAINT)" | head -1 | xargs)"; } ||
    echo "${sq}" | grep -q "SQLSTATE" && { log "WARN" "Cannot query system authorities"; ((errs++)); }
    local dq=$(db2 "SELECT GRANTEE,GRANTEETYPE,DBADMAUTH,BACKUPAUTH FROM SYSCAT.DBAUTH WHERE GRANTEE='${auth_id}' AND DBNAME='${DB_NAME}'" 2>&1)
    if ! echo "${dq}" | grep -q "SQLSTATE"; then
        local dl=$(echo "${dq}" | grep -i "${auth_id}" | head -1)
        [[ -n "${dl}" ]] && {
            echo "${dl}" | awk '{print $3}' | grep -q "Y" && { has_dbadm=true; log "INFO" "DBADM detected"; }
            echo "${dl}" | awk '{print $4}' | grep -q "Y" && { has_backup=true; log "INFO" "BACKUP privilege detected"; }
        }
    else
        ((errs++))
    fi
    [[ "${has_sys}" == "false" ]] && [[ "${has_dbadm}" == "false" ]] && [[ "${has_backup}" == "false" ]] && {
        local ac=$(db2 "SELECT COUNT(*) FROM SYSCAT.DBAUTH WHERE GRANTEE='${auth_id}' AND DBNAME='${DB_NAME}' AND (DBADMAUTH='Y' OR BACKUPAUTH='Y')" 2>&1)
        local cnt=$(echo "${ac}" | grep -v "^$" | tail -n +4 | head -n 1 | xargs | tr -d '\n\r')
        [[ "${cnt}" =~ ^[0-9]+$ ]] && [[ "${cnt}" -gt 0 ]] && { has_dbadm=true; log "INFO" "Authority detected (alt method)"; }
    }
    log "INFO" "Rights: sys=${has_sys} dbadm=${has_dbadm} backup=${has_backup}"
    [[ "${has_sys}" == "true" ]] || [[ "${has_dbadm}" == "true" ]] || [[ "${has_backup}" == "true" ]] && { log "INFO" "Rights verified"; return 0; }
    [[ ${errs} -gt 0 ]] && { log "WARN" "Cannot fully verify - proceeding"; return 0; }
    error_exit "Insufficient rights: ${auth_id} needs SYSADM/SYSCTRL/SYSMAINT, DBADM, or BACKUP privilege"
}

perform_backup() {
    local bd="${BACKUP_PATH}/${DB_NAME}" bf="${bd}/${DB_NAME}_${BACKUP_TYPE}_${TIMESTAMP}"
    mkdir -p "${bd}"
    log "INFO" "Starting ${BACKUP_TYPE} backup: ${DB_NAME} -> ${bf}"
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
    log "INFO" "Executing: db2 ${cmd}"
    if db2 "${cmd}" >> "${LOG_FILE}" 2>&1; then
        log "INFO" "Backup completed"
        local bf2=$(find "${bd}" -name "${DB_NAME}_${BACKUP_TYPE}_${TIMESTAMP}*" -type f)
        [[ -n "${bf2}" ]] && echo "${bf2}" | while read -r f; do log "INFO" "Created: ${f} ($(du -h "${f}" | cut -f1))"; done || log "WARN" "No backup files found"
    else
        error_exit "Backup failed"
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
        log "INFO" "Cleaning backups older than ${rd} days"
        find "${BACKUP_PATH}/${DB_NAME}" -type f -name "${DB_NAME}_*" -mtime +${rd} -delete
        log "INFO" "Cleanup done"
    }
}

main() {
    log "INFO" "=== DB2 Backup Started ==="
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
