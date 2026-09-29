#!/usr/bin/env bash

###############################################################################
# Oracle 19c NON-CDB -> Oracle 26ai CDB/PDB Migration
#
# Authentication model:
#
#   Migration Host
#        |
#        | SSH private key
#        v
#   LOGIN_USER
#        |
#        | sudo -iu oracle
#        v
#   ORACLE_OS_USER
#
# Migration method:
#
#   Full Transportable Data Pump
#
# Source:
#   Oracle 19c NON-CDB
#
# Target:
#   Oracle 26ai CDB
#       |
#       +-- TARGET_PDB
#
###############################################################################

set -Eeuo pipefail

IFS=$'\n\t'


###############################################################################
# SCRIPT LOCATION
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${BASE_DIR}/conf/migration.conf"

if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: Configuration file not found:"
    echo "       ${CONFIG}"
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG}"


###############################################################################
# REQUIRED CONFIGURATION
###############################################################################

require_config()
{
    local variable="$1"

    if [[ -z "${!variable:-}" ]]; then
        echo "ERROR: Required configuration variable is empty: ${variable}"
        exit 1
    fi
}


REQUIRED_VARIABLES=(
    LOGIN_USER
    ORACLE_OS_USER

    SOURCE_HOST
    TARGET_HOST

    SSH_IDENTITY_FILE
    SSH_BATCH_MODE
    SSH_STRICT_HOST_KEY_CHECKING
    SSH_CONNECT_TIMEOUT

    SOURCE_SID
    SOURCE_ORACLE_HOME
    SOURCE_ORACLE_BASE
    SOURCE_DATA_DIR
    SOURCE_STAGE
    SOURCE_DP_DIR

    TARGET_SID
    TARGET_ORACLE_HOME
    TARGET_ORACLE_BASE
    TARGET_DATA_DIR
    TARGET_STAGE
    TARGET_DP_DIR
    TARGET_PDB
    TARGET_PDB_ADMIN
    TARGET_PDB_ADMIN_PASSWORD

    DP_USER
    DP_PARALLEL
    DUMP_PREFIX
    EXPORT_LOG
    IMPORT_LOG
    TRANSPORT_DATAFILES_LOG
    DP_PASSWORD_ENV

    RSYNC_PARALLEL

    DRY_RUN
    REQUIRE_CONFIRMATION
    ALLOW_DROP_TARGET_PDB

    MANAGE_READONLY
    CLEANUP_AFTER_SUCCESS
)


for variable in "${REQUIRED_VARIABLES[@]}"; do
    require_config "${variable}"
done


###############################################################################
# RUNTIME
###############################################################################

RUN_ID="$(date '+%Y%m%d_%H%M%S')"

LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"

mkdir -p "${LOG_DIR}" "${STATE_DIR}"

LOG_FILE="${LOG_DIR}/migration_${RUN_ID}.log"

LOCK_FILE="${STATE_DIR}/migration.lock"


###############################################################################
# STATE
###############################################################################

STATE_SOURCE_CHECK="${STATE_DIR}/01_source_checked"
STATE_TARGET_CHECK="${STATE_DIR}/02_target_checked"
STATE_PLATFORM_CHECK="${STATE_DIR}/03_platform_checked"
STATE_TRANSPORT_CHECK="${STATE_DIR}/04_transport_checked"
STATE_READONLY="${STATE_DIR}/05_tablespaces_readonly"
STATE_EXPORT="${STATE_DIR}/06_export_complete"
STATE_DATAFILES="${STATE_DIR}/07_datafiles_identified"
STATE_TRANSFER="${STATE_DIR}/08_transfer_complete"
STATE_IMPORT="${STATE_DIR}/09_import_complete"
STATE_VALIDATE="${STATE_DIR}/10_validation_complete"
STATE_RESTORE="${STATE_DIR}/11_source_restored"


###############################################################################
# SSH
###############################################################################

SSH_ARGS=(
    -i "${SSH_IDENTITY_FILE}"
    -o "BatchMode=${SSH_BATCH_MODE}"
    -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
    -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
)


###############################################################################
# RSYNC
###############################################################################

RSYNC_ARGS=(
    -a
    --partial
    --info=progress2
)


###############################################################################
# LOGGING
###############################################################################

log()
{
    printf '%s | INFO | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        | tee -a "${LOG_FILE}"
}


warn()
{
    printf '%s | WARN | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        | tee -a "${LOG_FILE}" >&2
}


error()
{
    printf '%s | ERROR | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" \
        | tee -a "${LOG_FILE}" >&2
}


die()
{
    error "$*"
    exit 1
}


###############################################################################
# ERROR HANDLER
###############################################################################

error_handler()
{
    local rc=$?

    echo
    echo "============================================================"
    echo "MIGRATION FAILED"
    echo "============================================================"
    echo "Exit code : ${rc}"
    echo "Command   : ${BASH_COMMAND}"
    echo "Log       : ${LOG_FILE}"
    echo "============================================================"

    exit "${rc}"
}

trap error_handler ERR


###############################################################################
# CLEANUP
###############################################################################

cleanup()
{
    rm -f "${LOCK_FILE}"
}

trap cleanup EXIT


###############################################################################
# LOCK
###############################################################################

acquire_lock()
{
    if [[ -f "${LOCK_FILE}" ]]; then

        local old_pid

        old_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"

        die "Migration lock exists: ${LOCK_FILE} PID=${old_pid}"

    fi

    printf '%s\n' "$$" > "${LOCK_FILE}"
}


###############################################################################
# LOCAL COMMANDS
###############################################################################

check_local_commands()
{
    local commands=(
        ssh
        ssh-keygen
        rsync
        awk
        sed
        grep
        find
        basename
        dirname
        mkdir
        date
    )

    for command in "${commands[@]}"; do

        command -v "${command}" >/dev/null 2>&1 ||
            die "Required command not found: ${command}"

    done
}


###############################################################################
# SSH KEY VALIDATION
###############################################################################

check_ssh_key()
{
    if [[ ! -f "${SSH_IDENTITY_FILE}" ]]; then

        die "SSH identity file does not exist: ${SSH_IDENTITY_FILE}"

    fi

    if [[ ! -r "${SSH_IDENTITY_FILE}" ]]; then

        die "SSH identity file is not readable: ${SSH_IDENTITY_FILE}"

    fi

    log "SSH identity : ${SSH_IDENTITY_FILE}"
}


###############################################################################
# SSH HOST KEY CHECK
###############################################################################

check_known_host()
{
    local host="$1"

    log "Checking SSH host key for ${host}..."

    ssh \
        -i "${SSH_IDENTITY_FILE}" \
        -o "BatchMode=yes" \
        -o "StrictHostKeyChecking=yes" \
        -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" \
        "${LOGIN_USER}@${host}" \
        "true" \
        >/dev/null
}


###############################################################################
# SOURCE SSH -> ORACLE
#
# Command is passed over stdin to bash -s.
#
# This avoids fragile nested bash -lc quoting.
###############################################################################

source_oracle()
{
    local script="$1"

    ssh "${SSH_ARGS[@]}" \
        "${LOGIN_USER}@${SOURCE_HOST}" \
        "sudo -iu ${ORACLE_OS_USER} bash -s" \
        <<< "${script}"
}


###############################################################################
# TARGET SSH -> ORACLE
###############################################################################

target_oracle()
{
    local script="$1"

    ssh "${SSH_ARGS[@]}" \
        "${LOGIN_USER}@${TARGET_HOST}" \
        "sudo -iu ${ORACLE_OS_USER} bash -s" \
        <<< "${script}"
}


###############################################################################
# ACCESS TEST
###############################################################################

check_access()
{
    check_local_commands

    check_ssh_key

    log "Testing source SSH..."

    ssh "${SSH_ARGS[@]}" \
        "${LOGIN_USER}@${SOURCE_HOST}" \
        "hostname"

    log "Testing source SSH -> sudo -> oracle..."

    source_oracle '
echo "USER=$(id -un)"
echo "UID=$(id -u)"
echo "GROUP=$(id -gn)"
echo "HOST=$(hostname)"
'

    log "Testing target SSH..."

    ssh "${SSH_ARGS[@]}" \
        "${LOGIN_USER}@${TARGET_HOST}" \
        "hostname"

    log "Testing target SSH -> sudo -> oracle..."

    target_oracle '
echo "USER=$(id -un)"
echo "UID=$(id -u)"
echo "GROUP=$(id -gn)"
echo "HOST=$(hostname)"
'

    log "Testing source Oracle environment..."

    source_oracle "
export ORACLE_SID='${SOURCE_SID}'
export ORACLE_HOME='${SOURCE_ORACLE_HOME}'
export ORACLE_BASE='${SOURCE_ORACLE_BASE}'
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"

echo \"ORACLE_SID=\$ORACLE_SID\"
echo \"ORACLE_HOME=\$ORACLE_HOME\"

\"\$ORACLE_HOME/bin/sqlplus\" -V
"

    log "Testing target Oracle environment..."

    target_oracle "
export ORACLE_SID='${TARGET_SID}'
export ORACLE_HOME='${TARGET_ORACLE_HOME}'
export ORACLE_BASE='${TARGET_ORACLE_BASE}'
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"

echo \"ORACLE_SID=\$ORACLE_SID\"
echo \"ORACLE_HOME=\$ORACLE_HOME\"

\"\$ORACLE_HOME/bin/sqlplus\" -V
"

    log "============================================================"
    log "ACCESS TEST PASSED"
    log "============================================================"
}


###############################################################################
# SOURCE SQL
###############################################################################

source_sql()
{
    local sql="$1"

    source_oracle "
export ORACLE_SID='${SOURCE_SID}'
export ORACLE_HOME='${SOURCE_ORACLE_HOME}'
export ORACLE_BASE='${SOURCE_ORACLE_BASE}'
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"

\"\$ORACLE_HOME/bin/sqlplus\" -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE

SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT OFF
SET LINESIZE 32767
SET TRIMSPOOL ON
SET TAB OFF

${sql}

EXIT;
SQL
"
}


###############################################################################
# TARGET SQL
###############################################################################

target_sql()
{
    local sql="$1"

    target_oracle "
export ORACLE_SID='${TARGET_SID}'
export ORACLE_HOME='${TARGET_ORACLE_HOME}'
export ORACLE_BASE='${TARGET_ORACLE_BASE}'
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"

\"\$ORACLE_HOME/bin/sqlplus\" -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE

SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT OFF
SET LINESIZE 32767
SET TRIMSPOOL ON
SET TAB OFF

${sql}

EXIT;
SQL
"
}


###############################################################################
# VALUE HELPERS
###############################################################################

source_value()
{
    local sql="$1"

    source_sql "${sql}" |
        sed '/^[[:space:]]*$/d' |
        xargs
}


target_value()
{
    local sql="$1"

    target_sql "${sql}" |
        sed '/^[[:space:]]*$/d' |
        xargs
}


###############################################################################
# SOURCE PRECHECK
###############################################################################

precheck_source()
{
    log "============================================================"
    log "SOURCE DATABASE PRECHECK"
    log "============================================================"

    local version
    local cdb
    local dbname
    local open_mode
    local platform
    local compatible

    version="$(
        source_value '
            SELECT version
            FROM v$instance;
        '
    )"

    cdb="$(
        source_value '
            SELECT cdb
            FROM v$database;
        '
    )"

    dbname="$(
        source_value '
            SELECT name
            FROM v$database;
        '
    )"

    open_mode="$(
        source_value '
            SELECT open_mode
            FROM v$database;
        '
    )"

    platform="$(
        source_value '
            SELECT platform_name
            FROM v$database;
        '
    )"

    compatible="$(
        source_value '
            SELECT value
            FROM v$parameter
            WHERE name = '\''compatible'\'';
        '
    )"

    log "Database   : ${dbname}"
    log "Version    : ${version}"
    log "CDB        : ${cdb}"
    log "Open mode  : ${open_mode}"
    log "Platform   : ${platform}"
    log "Compatible : ${compatible}"

    if [[ "${cdb}" != "NO" ]]; then
        die "Source is not NON-CDB. Detected CDB=${cdb}"
    fi

    if [[ "${version}" != 19* ]]; then
        die "Source is not Oracle 19c. Detected ${version}"
    fi

    if [[ "${open_mode}" != "READ WRITE" ]]; then
        die "Source must be READ WRITE at precheck."
    fi

    log "Source tablespaces:"

    source_sql '
        SELECT
            tablespace_name || '\''|'\'' ||
            contents || '\''|'\'' ||
            status
        FROM dba_tablespaces
        ORDER BY tablespace_name;
    ' | tee -a "${LOG_FILE}"

    log "Source datafiles:"

    source_sql '
        SELECT
            file_id || '\''|'\'' ||
            file_name || '\''|'\'' ||
            ROUND(bytes/1024/1024/1024,2) || '\''GB'\''
        FROM dba_data_files
        ORDER BY file_id;
    ' | tee -a "${LOG_FILE}"

    touch "${STATE_SOURCE_CHECK}"

    log "SOURCE PRECHECK PASSED."
}


###############################################################################
# TARGET PRECHECK
###############################################################################

precheck_target()
{
    log "============================================================"
    log "TARGET DATABASE PRECHECK"
    log "============================================================"

    local version
    local cdb
    local dbname
    local platform

    version="$(
        target_value '
            SELECT version
            FROM v$instance;
        '
    )"

    cdb="$(
        target_value '
            SELECT cdb
            FROM v$database;
        '
    )"

    dbname="$(
        target_value '
            SELECT name
            FROM v$database;
        '
    )"

    platform="$(
        target_value '
            SELECT platform_name
            FROM v$database;
        '
    )"

    log "Database : ${dbname}"
    log "Version  : ${version}"
    log "CDB      : ${cdb}"
    log "Platform : ${platform}"

    if [[ "${version}" != 26* ]]; then
        die "Target is not Oracle 26ai. Detected ${version}"
    fi

    if [[ "${cdb}" != "YES" ]]; then
        die "Target must be a CDB."
    fi

    log "Target PDBs:"

    target_sql '
        SELECT
            con_id || '\''|'\'' ||
            name || '\''|'\'' ||
            open_mode
        FROM v$pdbs
        ORDER BY con_id;
    ' | tee -a "${LOG_FILE}"

    touch "${STATE_TARGET_CHECK}"

    log "TARGET PRECHECK PASSED."
}


###############################################################################
# PLATFORM CHECK
###############################################################################

check_platform()
{
    local source_platform
    local target_platform

    source_platform="$(
        source_value '
            SELECT platform_name
            FROM v$database;
        '
    )"

    target_platform="$(
        target_value '
            SELECT platform_name
            FROM v$database;
        '
    )"

    log "Source platform : ${source_platform}"
    log "Target platform : ${target_platform}"

    if [[ "${source_platform}" != "${target_platform}" ]]; then

        die "Source and target platforms differ."

    fi

    touch "${STATE_PLATFORM_CHECK}"

    log "PLATFORM CHECK PASSED."
}


###############################################################################
# STORAGE CHECK
###############################################################################

check_storage()
{
    log "Checking source datafile storage."

    local asm_count

    asm_count="$(
        source_value '
            SELECT COUNT(*)
            FROM v$datafile
            WHERE name LIKE '\''+%'\'' OR name LIKE '\''+%'\'' ;
        '
    )"

    if [[ "${asm_count}" != "0" ]]; then

        echo
        echo "============================================================"
        echo "ASM DETECTED"
        echo "============================================================"
        echo

        source_sql '
            SELECT name
            FROM v$datafile;
        ' | tee -a "${LOG_FILE}"

        echo
        echo "This version of the migration script is filesystem based."
        echo "Do NOT continue with rsync datafile transfer."
        echo

        die "ASM source detected."

    fi

    log "Source datafiles appear to be filesystem based."

    log "Source filesystem space:"

    source_oracle "
        df -h '${SOURCE_STAGE}'
        df -h '${SOURCE_DP_DIR}'
        df -h '${SOURCE_DATA_DIR}'
    " | tee -a "${LOG_FILE}"

    log "Target filesystem space:"

    target_oracle "
        df -h '${TARGET_STAGE}'
        df -h '${TARGET_DP_DIR}'
        df -h '${TARGET_DATA_DIR}'
    " | tee -a "${LOG_FILE}"
}


###############################################################################
# COLLECT TABLESPACES
###############################################################################

collect_tablespaces()
{
    log "Collecting transportable user tablespaces."

    source_sql '
        SELECT tablespace_name
        FROM dba_tablespaces
        WHERE contents = '\''PERMANENT'\''
          AND tablespace_name NOT IN (
              '\''SYSTEM'\'',
              '\''SYSAUX'\''
          )
        ORDER BY tablespace_name;
    ' |
    sed '/^[[:space:]]*$/d' |
    sed 's/^[[:space:]]*//' |
    sed 's/[[:space:]]*$//' \
        > "${STATE_DIR}/transport_tablespaces.txt"

    if [[ ! -s "${STATE_DIR}/transport_tablespaces.txt" ]]; then
        die "No user tablespaces found."
    fi

    log "Tablespaces selected for transport:"

    cat "${STATE_DIR}/transport_tablespaces.txt" |
        tee -a "${LOG_FILE}"
}


###############################################################################
# TRANSPORT CHECK
###############################################################################

transport_check()
{
    log "Running DBMS_TTS transport set check."

    local ts_list

    ts_list="$(paste -sd, "${STATE_DIR}/transport_tablespaces.txt")"

    source_sql "
        BEGIN
            DBMS_TTS.TRANSPORT_SET_CHECK(
                ts_list => '${ts_list}',
                incl_constraints => TRUE
            );
        END;
        /
    " >/dev/null

    local violations

    violations="$(
        source_value '
            SELECT COUNT(*)
            FROM transport_set_violations;
        '
    )"

    log "Transport set violations: ${violations}"

    if [[ "${violations}" != "0" ]]; then

        source_sql '
            SELECT violation
            FROM transport_set_violations;
        ' | tee -a "${LOG_FILE}"

        die "Transport set validation failed."
    fi

    touch "${STATE_TRANSPORT_CHECK}"

    log "TRANSPORT SET CHECK PASSED."
}


###############################################################################
# PRECHECK
###############################################################################

precheck()
{
    acquire_lock

    check_access

    precheck_source

    precheck_target

    check_platform

    check_storage

    collect_tablespaces

    transport_check

    log "============================================================"
    log "ALL PRECHECKS PASSED"
    log "============================================================"
}


###############################################################################
# PREPARE DIRECTORIES
###############################################################################

prepare_directories()
{
    log "Preparing source staging directories."

    source_oracle "
        mkdir -p '${SOURCE_STAGE}'
        mkdir -p '${SOURCE_DP_DIR}'
    "

    log "Preparing target staging directories."

    target_oracle "
        mkdir -p '${TARGET_STAGE}'
        mkdir -p '${TARGET_DP_DIR}'
        mkdir -p '${TARGET_DATA_DIR}'
    "

    log "Creating source Data Pump directory."

    source_sql "
        CREATE OR REPLACE DIRECTORY MIGRATION_DP
        AS '${SOURCE_DP_DIR}';

        GRANT READ, WRITE
        ON DIRECTORY MIGRATION_DP
        TO ${DP_USER};
    "

    log "Creating target Data Pump directory."

    target_sql "
        CREATE OR REPLACE DIRECTORY MIGRATION_DP
        AS '${TARGET_DP_DIR}';

        GRANT READ, WRITE
        ON DIRECTORY MIGRATION_DP
        TO ${DP_USER};
    "

    log "Directory preparation completed."
}


###############################################################################
# PDB EXISTS
###############################################################################

target_pdb_exists()
{
    local count

    count="$(
        target_value "
            SELECT COUNT(*)
            FROM v\\\$pdbs
            WHERE name = UPPER('${TARGET_PDB}');
        "
    )"

    [[ "${count}" == "1" ]]
}


###############################################################################
# TARGET PDB PREPARATION
###############################################################################

prepare_target_pdb()
{
    log "Preparing target PDB: ${TARGET_PDB}"

    if target_pdb_exists; then

        log "Target PDB already exists."

        if [[ "${ALLOW_DROP_TARGET_PDB}" != "YES" ]]; then

            die "Target PDB ${TARGET_PDB} already exists. ALLOW_DROP_TARGET_PDB=NO."

        fi

        if [[ "${DRY_RUN}" == "YES" ]]; then

            die "DRY_RUN=YES. Existing PDB will not be destroyed."

        fi

        confirm_drop_pdb

        target_sql "
            ALTER PLUGGABLE DATABASE ${TARGET_PDB}
            CLOSE IMMEDIATE;

            DROP PLUGGABLE DATABASE ${TARGET_PDB}
            INCLUDING DATAFILES;
        "

    fi

    if target_pdb_exists; then
        die "Target PDB still exists after drop."
    fi

    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: PDB creation skipped."

        return 0
    fi

    local seed_file
    local seed_dir

    seed_file="$(
        target_value "
            SELECT file_name
            FROM cdb_data_files
            WHERE con_id = 2
              AND ROWNUM = 1;
        "
    )"

    [[ -n "${seed_file}" ]] ||
        die "Unable to determine PDB$SEED datafile."

    seed_dir="$(dirname "${seed_file}")"

    log "PDB$SEED directory: ${seed_dir}"

    target_sql "
        CREATE PLUGGABLE DATABASE ${TARGET_PDB}
        ADMIN USER ${TARGET_PDB_ADMIN}
        IDENTIFIED BY \"${TARGET_PDB_ADMIN_PASSWORD}\"
        FILE_NAME_CONVERT =
        (
            '${seed_dir}/',
            '${TARGET_DATA_DIR}/${TARGET_PDB}/'
        );

        ALTER PLUGGABLE DATABASE ${TARGET_PDB}
        OPEN;

        ALTER PLUGGABLE DATABASE ${TARGET_PDB}
        SAVE STATE;
    "

    log "Target PDB created."
}


###############################################################################
# CONFIRM PDB DROP
###############################################################################

confirm_drop_pdb()
{
    local expected="DESTROY-${TARGET_SID}-${TARGET_PDB}"

    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "DANGER"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    echo "This will destroy:"
    echo
    echo "  ${TARGET_SID}/${TARGET_PDB}"
    echo
    echo "INCLUDING DATAFILES."
    echo
    echo "Type exactly:"
    echo
    echo "  ${expected}"
    echo

    local answer

    read -r -p "Confirmation: " answer

    [[ "${answer}" == "${expected}" ]] ||
        die "PDB destruction confirmation failed."
}


###############################################################################
# SET READ ONLY
###############################################################################

set_readonly()
{
    [[ "${MANAGE_READONLY}" == "YES" ]] ||
        return 0

    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: READ ONLY operation skipped."

        return 0
    fi

    log "Setting user tablespaces READ ONLY."

    while IFS= read -r tablespace; do

        [[ -z "${tablespace}" ]] && continue

        log "READ ONLY: ${tablespace}"

        source_sql "
            ALTER TABLESPACE \"${tablespace}\" READ ONLY;
        "

    done < "${STATE_DIR}/transport_tablespaces.txt"

    touch "${STATE_READONLY}"

    log "User tablespaces are READ ONLY."
}


###############################################################################
# VERIFY READ ONLY
###############################################################################

verify_readonly()
{
    [[ "${MANAGE_READONLY}" == "YES" ]] ||
        return 0

    [[ "${DRY_RUN}" == "YES" ]] &&
        return 0

    local writable

    writable="$(
        source_value '
            SELECT COUNT(*)
            FROM dba_tablespaces
            WHERE contents = '\''PERMANENT'\''
              AND tablespace_name NOT IN (
                  '\''SYSTEM'\'',
                  '\''SYSAUX'\''
              )
              AND status <> '\''READ ONLY'\'';
        '
    )"

    if [[ "${writable}" != "0" ]]; then
        die "${writable} user tablespaces are not READ ONLY."
    fi

    log "Verified user tablespaces are READ ONLY."
}


###############################################################################
# PASSWORD
###############################################################################

check_datapump_password()
{
    if [[ -z "${!DP_PASSWORD_ENV:-}" ]]; then

        die "Environment variable ${DP_PASSWORD_ENV} is not set.

Set it with:

export ${DP_PASSWORD_ENV}='YOUR_SYSTEM_PASSWORD'
"

    fi
}


###############################################################################
# BUILD EXPORT PARFILE
###############################################################################

build_export_parfile()
{
    source_oracle "
cat > '${SOURCE_STAGE}/export.par' <<'EOF'
FULL=YES
TRANSPORTABLE=ALWAYS
VERSION=12
DIRECTORY=MIGRATION_DP
DUMPFILE=${DUMP_PREFIX}_%L.dmp
LOGFILE=${EXPORT_LOG}
TRANSPORT_DATAFILES_LOG=${TRANSPORT_DATAFILES_LOG}
PARALLEL=${DP_PARALLEL}
METRICS=YES
LOGTIME=ALL
EOF

chmod 640 '${SOURCE_STAGE}/export.par'
"

    log "Export parameter file created."
}


###############################################################################
# EXPORT
###############################################################################

run_export()
{
    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: Data Pump export skipped."

        return 0
    fi

    [[ -f "${STATE_READONLY}" ]] ||
        die "Source tablespaces are not READ ONLY."

    check_datapump_password

    build_export_parfile

    log "Starting Data Pump export."

    source_oracle "
export ORACLE_SID='${SOURCE_SID}'
export ORACLE_HOME='${SOURCE_ORACLE_HOME}'
export ORACLE_BASE='${SOURCE_ORACLE_BASE}'
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"

export DP_CONNECT='${DP_USER}/\${${DP_PASSWORD_ENV}}'

\"\$ORACLE_HOME/bin/expdp\" \
    \"\$DP_CONNECT\" \
    PARFILE='${SOURCE_STAGE}/export.par'
" >> "${LOG_FILE}" 2>&1

    log "Checking Data Pump export log."

    source_oracle "
grep -Eiq 'successfully completed' \
    '${SOURCE_DP_DIR}/${EXPORT_LOG}'
"

    touch "${STATE_EXPORT}"

    log "DATA PUMP EXPORT COMPLETED."
}


###############################################################################
# GET TRANSPORT DATAFILES
###############################################################################

get_transport_datafiles()
{
    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: transport datafile extraction skipped."

        return 0
    fi

    [[ -f "${STATE_EXPORT}" ]] ||
        die "Export has not completed."

    log "Retrieving transport datafile information."

    source_oracle "
cat '${SOURCE_DP_DIR}/${TRANSPORT_DATAFILES_LOG}'
" > "${STATE_DIR}/transport_datafiles.raw"

    if [[ ! -s "${STATE_DIR}/transport_datafiles.raw" ]]; then
        die "Transport datafile log is empty."
    fi

    log "Transport datafile log received."

    #
    # Keep the raw Oracle-generated file.
    #
    cp "${STATE_DIR}/transport_datafiles.raw" \
       "${STATE_DIR}/transport_datafiles.raw.backup"

    #
    # Extract absolute paths.
    #
    grep -Eo "'/[^']+'" \
        "${STATE_DIR}/transport_datafiles.raw" |
        sed "s/^'//;s/'$//" |
        sort -u \
        > "${STATE_DIR}/transport_datafiles.txt" || true

    if [[ ! -s "${STATE_DIR}/transport_datafiles.txt" ]]; then

        grep -E '^/' \
            "${STATE_DIR}/transport_datafiles.raw" |
            sed 's/[[:space:]]*$//' |
            sort -u \
            > "${STATE_DIR}/transport_datafiles.txt" || true

    fi

    if [[ ! -s "${STATE_DIR}/transport_datafiles.txt" ]]; then

        log "Raw transport datafile output:"
        cat "${STATE_DIR}/transport_datafiles.raw" |
            tee -a "${LOG_FILE}"

        die "Unable to determine transport datafiles."
    fi

    log "Transport datafiles:"

    cat "${STATE_DIR}/transport_datafiles.txt" |
        tee -a "${LOG_FILE}"

    touch "${STATE_DATAFILES}"
}


###############################################################################
# VERIFY SOURCE DATAFILES
###############################################################################

verify_source_datafiles()
{
    [[ "${DRY_RUN}" == "YES" ]] &&
        return 0

    while IFS= read -r file; do

        [[ -z "${file}" ]] && continue

        log "Checking source datafile: ${file}"

        source_oracle "
            test -r '${file}'
        "

    done < "${STATE_DIR}/transport_datafiles.txt"

    log "Source datafiles are readable."
}


###############################################################################
# TRANSFER DUMP FILES
###############################################################################

transfer_dump_files()
{
    [[ "${DRY_RUN}" == "YES" ]] &&
        return 0

    log "Finding Data Pump dump files."

    ssh "${SSH_ARGS[@]}" \
        "${LOGIN_USER}@${SOURCE_HOST}" \
        "find '${SOURCE_DP_DIR}' -maxdepth 1 -type f \
        \\( -name '${DUMP_PREFIX}_*.dmp' \
        -o -name '${EXPORT_LOG}' \
        -o -name '${TRANSPORT_DATAFILES_LOG}' \\) -print" \
        > "${STATE_DIR}/dump_files.txt"

    if [[ ! -s "${STATE_DIR}/dump_files.txt" ]]; then
        die "No Data Pump dump files found."
    fi

    while IFS= read -r file; do

        [[ -z "${file}" ]] && continue

        local filename

        filename="$(basename "${file}")"

        log "Transferring ${filename}"

        ssh "${SSH_ARGS[@]}" \
            "${LOGIN_USER}@${SOURCE_HOST}" \
            "test -r '${file}'"

        #
        # Transfer directly source -> migration host -> target.
        #
        # rsync cannot normally perform a remote-to-remote copy through
        # an arbitrary login host without additional SSH configuration.
        #
        # Therefore we stage on the local migration host.
        #

        local local_file

        local_file="${BASE_DIR}/stage/${filename}"

        mkdir -p "${BASE_DIR}/stage"

        rsync "${RSYNC_ARGS[@]}" \
            -e "ssh -i ${SSH_IDENTITY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
            "${LOGIN_USER}@${SOURCE_HOST}:${file}" \
            "${local_file}" \
            >> "${LOG_FILE}" 2>&1

        rsync "${RSYNC_ARGS[@]}" \
            -e "ssh -i ${SSH_IDENTITY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
            "${local_file}" \
            "${LOGIN_USER}@${TARGET_HOST}:${TARGET_DP_DIR}/${filename}" \
            >> "${LOG_FILE}" 2>&1

    done < "${STATE_DIR}/dump_files.txt"

    log "Data Pump dump transfer completed."
}


###############################################################################
# TRANSFER DATAFILES
###############################################################################

transfer_datafiles()
{
    [[ "${DRY_RUN}" == "YES" ]] &&
        return 0

    log "Transferring Oracle datafiles."

    mkdir -p "${BASE_DIR}/stage/datafiles"

    local running=0
    local pids=()

    while IFS= read -r source_file; do

        [[ -z "${source_file}" ]] && continue

        local filename
        local local_file
        local target_file

        filename="$(basename "${source_file}")"

        local_file="${BASE_DIR}/stage/datafiles/${filename}"

        target_file="${TARGET_DATA_DIR}/${filename}"

        log "Datafile:"
        log "  Source : ${source_file}"
        log "  Local  : ${local_file}"
        log "  Target : ${target_file}"

        ssh "${SSH_ARGS[@]}" \
            "${LOGIN_USER}@${SOURCE_HOST}" \
            "test -r '${source_file}'"

        ssh "${SSH_ARGS[@]}" \
            "${LOGIN_USER}@${TARGET_HOST}" \
            "test -d '${TARGET_DATA_DIR}'"

        rsync "${RSYNC_ARGS[@]}" \
            -e "ssh -i ${SSH_IDENTITY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
            "${LOGIN_USER}@${SOURCE_HOST}:${source_file}" \
            "${local_file}" \
            >> "${LOG_FILE}" 2>&1 &

        pids+=("$!")

        ((running+=1))

        if (( running >= RSYNC_PARALLEL )); then

            for pid in "${pids[@]}"; do

                wait "${pid}" ||
                    die "Source -> local datafile transfer failed."

            done

            pids=()
            running=0

        fi

    done < "${STATE_DIR}/transport_datafiles.txt"


    for pid in "${pids[@]}"; do

        wait "${pid}" ||
            die "Source -> local datafile transfer failed."

    done


    log "Uploading datafiles to target."

    running=0
    pids=()

    while IFS= read -r source_file; do

        [[ -z "${source_file}" ]] && continue

        local filename
        local local_file

        filename="$(basename "${source_file}")"

        local_file="${BASE_DIR}/stage/datafiles/${filename}"

        rsync "${RSYNC_ARGS[@]}" \
            -e "ssh -i ${SSH_IDENTITY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
            "${local_file}" \
            "${LOGIN_USER}@${TARGET_HOST}:${TARGET_DATA_DIR}/${filename}" \
            >> "${LOG_FILE}" 2>&1 &

        pids+=("$!")

        ((running+=1))

        if (( running >= RSYNC_PARALLEL )); then

            for pid in "${pids[@]}"; do

                wait "${pid}" ||
                    die "Local -> target datafile transfer failed."

            done

            pids=()
            running=0

        fi

    done < "${STATE_DIR}/transport_datafiles.txt"


    for pid in "${pids[@]}"; do

        wait "${pid}" ||
            die "Local -> target datafile transfer failed."

    done

    log "Oracle datafile transfer completed."
}


###############################################################################
# VERIFY TARGET DATAFILES
###############################################################################

verify_target_datafiles()
{
    [[ "${DRY_RUN}" == "YES" ]] &&
        return 0

    while IFS= read -r source_file; do

        [[ -z "${source_file}" ]] && continue

        local filename

        filename="$(basename "${source_file}")"

        local target_file

        target_file="${TARGET_DATA_DIR}/${filename}"

        target_oracle "
            test -r '${target_file}'
        "

    done < "${STATE_DIR}/transport_datafiles.txt"

    log "Target datafiles verified."
}


###############################################################################
# TRANSFER
###############################################################################

transfer()
{
    [[ "${DRY_RUN}" == "YES" ]] &&
        {
            log "DRY_RUN: transfer skipped."
            return 0
        }

    [[ -f "${STATE_DATAFILES}" ]] ||
        die "Transport datafile list does not exist."

    verify_source_datafiles

    transfer_dump_files

    transfer_datafiles

    verify_target_datafiles

    touch "${STATE_TRANSFER}"

    log "TRANSFER COMPLETED."
}


###############################################################################
# BUILD IMPORT PARFILE
###############################################################################

build_import_parfile()
{
    local local_parfile="${STATE_DIR}/import.par"

    {
        echo "DIRECTORY=MIGRATION_DP"
        echo "DUMPFILE=${DUMP_PREFIX}_%L.dmp"
        echo "LOGFILE=${IMPORT_LOG}"
        echo "PARALLEL=${DP_PARALLEL}"
        echo "METRICS=YES"
        echo "LOGTIME=ALL"

        printf "TRANSPORT_DATAFILES="

        local first="YES"

        while IFS= read -r source_file; do

            [[ -z "${source_file}" ]] && continue

            local filename
            local target_file

            filename="$(basename "${source_file}")"

            target_file="${TARGET_DATA_DIR}/${filename}"

            if [[ "${first}" == "YES" ]]; then

                printf "'%s'" "${target_file}"

                first="NO"

            else

                printf ",\n'%s'" "${target_file}"

            fi

        done < "${STATE_DIR}/transport_datafiles.txt"

        printf "\n"

    } > "${local_parfile}"

    log "Import parameter file:"
    cat "${local_parfile}" | tee -a "${LOG_FILE}"

    rsync "${RSYNC_ARGS[@]}" \
        -e "ssh -i ${SSH_IDENTITY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}" \
        "${local_parfile}" \
        "${LOGIN_USER}@${TARGET_HOST}:${TARGET_STAGE}/import.par" \
        >> "${LOG_FILE}" 2>&1
}


###############################################################################
# VERIFY TARGET PDB
###############################################################################

verify_target_pdb()
{
    local count

    count="$(
        target_value "
            SELECT COUNT(*)
            FROM v\\\$pdbs
            WHERE name=UPPER('${TARGET_PDB}');
        "
    )"

    [[ "${count}" == "1" ]] ||
        die "Target PDB ${TARGET_PDB} does not exist."

    log "Target PDB exists: ${TARGET_PDB}"

    target_sql "
        ALTER PLUGGABLE DATABASE ${TARGET_PDB}
        OPEN;
    " >/dev/null 2>&1 || true
}


###############################################################################
# IMPORT
###############################################################################

run_import()
{
    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: import skipped."

        return 0
    fi

    [[ -f "${STATE_TRANSFER}" ]] ||
        die "Data transfer has not completed."

    check_datapump_password

    verify_target_pdb

    build_import_parfile

    log "Starting Data Pump import into ${TARGET_PDB}."

    target_oracle "
export ORACLE_SID='${TARGET_SID}'
export ORACLE_HOME='${TARGET_ORACLE_HOME}'
export ORACLE_BASE='${TARGET_ORACLE_BASE}'
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"

export DP_CONNECT='${DP_USER}/\${${DP_PASSWORD_ENV}}@${TARGET_PDB}'

\"\$ORACLE_HOME/bin/impdp\" \
    \"\$DP_CONNECT\" \
    PARFILE='${TARGET_STAGE}/import.par'
" >> "${LOG_FILE}" 2>&1

    log "Checking Data Pump import log."

    target_oracle "
grep -Eiq 'successfully completed' \
    '${TARGET_DP_DIR}/${IMPORT_LOG}'
"

    touch "${STATE_IMPORT}"

    log "DATA PUMP IMPORT COMPLETED."
}


###############################################################################
# VALIDATION
###############################################################################

validate()
{
    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: validation skipped."

        return 0
    fi

    [[ -f "${STATE_IMPORT}" ]] ||
        die "Import has not completed."

    log "============================================================"
    log "POST-MIGRATION VALIDATION"
    log "============================================================"

    log "Invalid objects in target PDB:"

    target_sql "
        ALTER SESSION SET CONTAINER=${TARGET_PDB};

        SELECT
            owner || '\''|'\'' ||
            object_type || '\''|'\'' ||
            COUNT(*)
        FROM dba_objects
        WHERE status <> '\''VALID'\''
        GROUP BY owner, object_type
        ORDER BY owner, object_type;
    " | tee -a "${LOG_FILE}"

    log "Target users:"

    target_sql "
        ALTER SESSION SET CONTAINER=${TARGET_PDB};

        SELECT
            username || '\''|'\'' ||
            account_status
        FROM dba_users
        WHERE oracle_maintained='N'
        ORDER BY username;
    " | tee -a "${LOG_FILE}"

    log "Target tablespaces:"

    target_sql "
        ALTER SESSION SET CONTAINER=${TARGET_PDB};

        SELECT
            tablespace_name || '\''|'\'' ||
            status
        FROM dba_tablespaces
        ORDER BY tablespace_name;
    " | tee -a "${LOG_FILE}"

    touch "${STATE_VALIDATE}"

    log "VALIDATION COMPLETED."
}


###############################################################################
# RESTORE SOURCE
###############################################################################

restore_source()
{
    if [[ "${MANAGE_READONLY}" != "YES" ]]; then
        log "Source READ ONLY management disabled."
        return 0
    fi

    if [[ ! -f "${STATE_READONLY}" ]]; then
        log "Source was not placed READ ONLY by this script."
        return 0
    fi

    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "DRY_RUN: source READ WRITE restoration skipped."

        return 0
    fi

    log "Restoring source tablespaces READ WRITE."

    while IFS= read -r tablespace; do

        [[ -z "${tablespace}" ]] && continue

        log "READ WRITE: ${tablespace}"

        source_sql "
            ALTER TABLESPACE \"${tablespace}\" READ WRITE;
        "

    done < "${STATE_DIR}/transport_tablespaces.txt"

    touch "${STATE_RESTORE}"

    log "SOURCE TABLESPACES RESTORED."
}


###############################################################################
# CONFIRM MIGRATION
###############################################################################

confirm_migration()
{
    [[ "${REQUIRE_CONFIRMATION}" == "YES" ]] ||
        return 0

    [[ "${DRY_RUN}" != "YES" ]] ||
        return 0

    echo
    echo "============================================================"
    echo "FINAL MIGRATION CONFIRMATION"
    echo "============================================================"
    echo
    echo "SOURCE:"
    echo "  ${LOGIN_USER}@${SOURCE_HOST}"
    echo "  SID = ${SOURCE_SID}"
    echo
    echo "TARGET:"
    echo "  ${LOGIN_USER}@${TARGET_HOST}"
    echo "  SID = ${TARGET_SID}"
    echo "  PDB = ${TARGET_PDB}"
    echo
    echo "Type exactly:"
    echo
    echo "  MIGRATE-${TARGET_SID}-${TARGET_PDB}"
    echo

    local answer

    read -r -p "Confirmation: " answer

    [[ "${answer}" == "MIGRATE-${TARGET_SID}-${TARGET_PDB}" ]] ||
        die "Migration confirmation failed."
}


###############################################################################
# STATUS
###############################################################################

status()
{
    echo
    echo "============================================================"
    echo "ORACLE MIGRATION STATUS"
    echo "============================================================"
    echo

    local states=(
        "${STATE_SOURCE_CHECK}"
        "${STATE_TARGET_CHECK}"
        "${STATE_PLATFORM_CHECK}"
        "${STATE_TRANSPORT_CHECK}"
        "${STATE_READONLY}"
        "${STATE_EXPORT}"
        "${STATE_DATAFILES}"
        "${STATE_TRANSFER}"
        "${STATE_IMPORT}"
        "${STATE_VALIDATE}"
        "${STATE_RESTORE}"
    )

    for state in "${states[@]}"; do

        if [[ -f "${state}" ]]; then
            printf "PASS  %s\n" "$(basename "${state}")"
        else
            printf "----  %s\n" "$(basename "${state}")"
        fi

    done

    echo
    echo "Log:"
    echo "  ${LOG_FILE}"
    echo
}


###############################################################################
# ALL
###############################################################################

all()
{
    acquire_lock

    check_access

    precheck_source

    precheck_target

    check_platform

    check_storage

    collect_tablespaces

    transport_check

    confirm_migration

    prepare_directories

    prepare_target_pdb

    set_readonly

    verify_readonly

    run_export

    get_transport_datafiles

    transfer

    run_import

    validate

    restore_source

    log "============================================================"
    log "MIGRATION COMPLETED"
    log "============================================================"
    log "SOURCE : ${SOURCE_HOST}/${SOURCE_SID}"
    log "TARGET : ${TARGET_HOST}/${TARGET_SID}/${TARGET_PDB}"
    log "LOG    : ${LOG_FILE}"
    log "============================================================"
}


###############################################################################
# USAGE
###############################################################################

usage()
{
    cat <<EOF

Oracle 19c NON-CDB -> Oracle 26ai CDB/PDB

Usage:

  $0 access
  $0 precheck
  $0 prepare
  $0 readonly
  $0 export
  $0 datafiles
  $0 transfer
  $0 import
  $0 validate
  $0 restore
  $0 status
  $0 all

Recommended first commands:

  $0 access
  $0 precheck
  $0 status

Authentication:

  ${LOGIN_USER}
      |
      | SSH key
      v
  Source/Target
      |
      | sudo -iu ${ORACLE_OS_USER}
      v
  Oracle

EOF
}


###############################################################################
# MAIN
###############################################################################

case "${1:-}" in

    access)
        check_access
        ;;

    precheck)
        precheck
        ;;

    prepare)
        acquire_lock
        prepare_directories
        prepare_target_pdb
        ;;

    readonly)
        acquire_lock
        collect_tablespaces
        set_readonly
        verify_readonly
        ;;

    export)
        acquire_lock
        run_export
        get_transport_datafiles
        ;;

    datafiles)
        get_transport_datafiles
        ;;

    transfer)
        acquire_lock
        transfer
        ;;

    import)
        acquire_lock
        run_import
        ;;

    validate)
        acquire_lock
        validate
        ;;

    restore)
        acquire_lock
        restore_source
        ;;

    status)
        status
        ;;

    all)
        all
        ;;

    *)
        usage
        exit 1
        ;;

esac
