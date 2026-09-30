#!/bin/bash

###############################################################################
# Oracle 26ai - Full CDB Rename
#
# PURPOSE
# -------
# Rename a single-instance CDB completely:
#
#   DB_NAME
#   DB_UNIQUE_NAME
#   ORACLE_SID
#   INSTANCE_NAME
#   PMON name
#   /etc/oratab entry
#   SID-specific SPFILE
#
# DBID:
#   MUST remain unchanged
#
# DBNEWID:
#   Used ONLY to change DB_NAME:
#
#       nid TARGET=/ DBNAME=NEW_NAME SETNAME=YES
#
# RESETLOGS:
#   NOT used
#
# ENVIRONMENT
# -----------
# RHEL 9
# Oracle Database 26ai
# Single Instance
# CDB
# Filesystem SPFILE
#
# NOT SUPPORTED
# -------------
# RAC
# ASM SPFILE
# Grid Infrastructure / SRVCTL-managed database
#
# CSV FORMAT
# ----------
# OLD_CDB,NEW_CDB
#
# Example:
#
#
# USAGE
# -----
# ./rename_multiple_cdb_full.sh cdb_rename_list.csv
#
###############################################################################

set -u
set -o pipefail

###############################################################################
# INPUT
###############################################################################

CSV_FILE="${1:-cdb_rename_list.csv}"

###############################################################################
# DIRECTORIES
###############################################################################

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

LOG_DIR="${BASE_DIR}/logs"
BACKUP_DIR="${BASE_DIR}/backup"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

MASTER_LOG="${LOG_DIR}/rename_master_$(date +%Y%m%d_%H%M%S).log"

###############################################################################
# LOGGING
###############################################################################

exec > >(tee -a "$MASTER_LOG") 2>&1

###############################################################################
# COLORS
###############################################################################

RED=''
GREEN=''
YELLOW=''
BLUE=''
RESET=''

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
fi

###############################################################################
# LOG FUNCTIONS
###############################################################################

log_info()
{
    echo -e "${BLUE}[INFO]${RESET} $*"
}

log_ok()
{
    echo -e "${GREEN}[OK]${RESET} $*"
}

log_warn()
{
    echo -e "${YELLOW}[WARNING]${RESET} $*"
}

log_error()
{
    echo -e "${RED}[ERROR]${RESET} $*"
}

###############################################################################
# ORACLE NAME VALIDATION
#
# DB_NAME / DB_UNIQUE_NAME maximum 8 characters for this script.
###############################################################################

valid_oracle_name()
{
    local NAME="$1"

    [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9_\$#]{0,7}$ ]]
}

###############################################################################
# PMON CHECK
###############################################################################

pmon_exists()
{
    local SID="$1"

    ps -ef | grep "[o]ra_pmon_${SID}" >/dev/null 2>&1
}

###############################################################################
# WAIT FOR PMON
###############################################################################

wait_for_pmon()
{
    local SID="$1"
    local TIMEOUT="${2:-90}"
    local COUNT=0

    while [[ $COUNT -lt $TIMEOUT ]]
    do
        if pmon_exists "$SID"; then
            return 0
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done

    return 1
}

###############################################################################
# WAIT FOR PMON TO STOP
###############################################################################

wait_for_pmon_stop()
{
    local SID="$1"
    local TIMEOUT="${2:-90}"
    local COUNT=0

    while [[ $COUNT -lt $TIMEOUT ]]
    do
        if ! pmon_exists "$SID"; then
            return 0
        fi

        sleep 1
        COUNT=$((COUNT + 1))
    done

    return 1
}

###############################################################################
# GET DATABASE INFORMATION
###############################################################################

get_database_info()
{
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off
set trimspool on

select
    trim(name) || '|' ||
    trim(dbid) || '|' ||
    trim(cdb) || '|' ||
    trim(open_mode) || '|' ||
    trim(db_unique_name)
from v\$database;

exit;
EOF
}

###############################################################################
# GET SPFILE
###############################################################################

get_spfile()
{
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off

select trim(value)
from v\$parameter
where name='spfile';

exit;
EOF
}

###############################################################################
# GET CLUSTER DATABASE
###############################################################################

get_cluster_database()
{
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off

select trim(value)
from v\$parameter
where name='cluster_database';

exit;
EOF
}

###############################################################################
# CREATE PFILE
###############################################################################

create_pfile()
{
    local SPFILE="$1"
    local PFILE="$2"

    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

create pfile='$PFILE' from spfile='$SPFILE';

exit;
EOF
}

###############################################################################
# CREATE SPFILE
###############################################################################

create_spfile()
{
    local SPFILE="$1"
    local PFILE="$2"

    rm -f "$SPFILE"

    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

create spfile='$SPFILE' from pfile='$PFILE';

exit;
EOF
}

###############################################################################
# SHUTDOWN
###############################################################################

shutdown_database()
{
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

shutdown immediate;

exit;
EOF
}

###############################################################################
# STARTUP MOUNT
###############################################################################

startup_mount()
{
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

startup mount;

exit;
EOF
}

###############################################################################
# STARTUP NORMAL
###############################################################################

startup_normal()
{
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

startup;

exit;
EOF
}

###############################################################################
# CHANGE PFILE PARAMETER
#
# Handles:
#
#   *.db_name='xxx'
#   *.db_unique_name='xxx'
#
###############################################################################

set_pfile_parameter()
{
    local PFILE="$1"
    local PARAM="$2"
    local VALUE="$3"

    if grep -qiE \
        "^[[:space:]]*\*?[[:space:]]*${PARAM}[[:space:]]*=" \
        "$PFILE"
    then

        sed -i -E \
            "s/^([*]?[[:space:]]*${PARAM}[[:space:]]*=).*/\1'$VALUE'/I" \
            "$PFILE"

    else

        echo "*.${PARAM}='${VALUE}'" >> "$PFILE"

    fi
}

###############################################################################
# VERIFY PFILE PARAMETER
###############################################################################

verify_pfile_parameter()
{
    local PFILE="$1"
    local PARAM="$2"
    local EXPECTED="$3"

    grep -qiE \
        "^[[:space:]]*\*?[[:space:]]*${PARAM}[[:space:]]*=[[:space:]]*'$EXPECTED'" \
        "$PFILE"
}

###############################################################################
# UPDATE /etc/oratab
###############################################################################

update_oratab()
{
    local OLD_SID="$1"
    local NEW_SID="$2"

    if [[ ! -f /etc/oratab ]]; then
        log_warn "/etc/oratab does not exist."
        return 0
    fi

    if ! grep -qE "^${OLD_SID}:" /etc/oratab; then
        log_warn "No /etc/oratab entry found for $OLD_SID."
        return 0
    fi

    local ORATAB_BACKUP

    ORATAB_BACKUP="/etc/oratab.backup.$(date +%Y%m%d_%H%M%S)"

    cp -p /etc/oratab "$ORATAB_BACKUP"

    if [[ $? -ne 0 ]]; then
        log_error "Could not backup /etc/oratab."
        return 1
    fi

    sed -i \
        "s/^${OLD_SID}:/${NEW_SID}:/" \
        /etc/oratab

    if grep -qE "^${NEW_SID}:" /etc/oratab; then
        log_ok "/etc/oratab updated."
        echo "Backup: $ORATAB_BACKUP"
        return 0
    fi

    log_error "/etc/oratab update failed."

    cp -p "$ORATAB_BACKUP" /etc/oratab

    return 1
}

###############################################################################
# FINAL VERIFICATION
###############################################################################

final_verification()
{
    local OLD_SID="$1"
    local NEW_NAME="$2"
    local EXPECTED_DBID="$3"
    local EXPECTED_DB_UNIQUE="$4"

    export ORACLE_SID="$NEW_NAME"

    local OUTPUT
    local RC

    OUTPUT=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off
set trimspool on

select
    trim(name) || '|' ||
    trim(dbid) || '|' ||
    trim(db_unique_name) || '|' ||
    trim(cdb) || '|' ||
    trim(open_mode)
from v\$database;

select
    trim(instance_name) || '|' ||
    trim(status)
from v\$instance;

exit;
EOF
    )

    RC=$?

    if [[ $RC -ne 0 ]]; then

        log_error "Final SQL verification failed."
        echo
        echo "$OUTPUT"
        return 1
    fi

    local DB_LINE
    local INSTANCE_LINE

    DB_LINE=$(echo "$OUTPUT" | sed -n '1p')
    INSTANCE_LINE=$(echo "$OUTPUT" | sed -n '2p')

    local FINAL_NAME
    local FINAL_DBID
    local FINAL_DB_UNIQUE
    local FINAL_CDB
    local FINAL_MODE

    local FINAL_INSTANCE
    local FINAL_STATUS

    IFS='|' read -r \
        FINAL_NAME \
        FINAL_DBID \
        FINAL_DB_UNIQUE \
        FINAL_CDB \
        FINAL_MODE <<< "$DB_LINE"

    IFS='|' read -r \
        FINAL_INSTANCE \
        FINAL_STATUS <<< "$INSTANCE_LINE"

    FINAL_NAME=$(echo "$FINAL_NAME" | xargs)
    FINAL_DBID=$(echo "$FINAL_DBID" | xargs)
    FINAL_DB_UNIQUE=$(echo "$FINAL_DB_UNIQUE" | xargs)
    FINAL_CDB=$(echo "$FINAL_CDB" | xargs)
    FINAL_MODE=$(echo "$FINAL_MODE" | xargs)
    FINAL_INSTANCE=$(echo "$FINAL_INSTANCE" | xargs)
    FINAL_STATUS=$(echo "$FINAL_STATUS" | xargs)

    echo
    echo "============================================================"
    echo "FINAL VERIFICATION"
    echo "============================================================"
    echo
    echo "Expected DB_NAME       : $NEW_NAME"
    echo "Actual DB_NAME         : $FINAL_NAME"
    echo
    echo "Original DBID          : $EXPECTED_DBID"
    echo "Current DBID           : $FINAL_DBID"
    echo
    echo "Expected DB_UNIQUE_NAME: $EXPECTED_DB_UNIQUE"
    echo "Actual DB_UNIQUE_NAME  : $FINAL_DB_UNIQUE"
    echo
    echo "Expected ORACLE_SID    : $NEW_NAME"
    echo "Actual ORACLE_SID      : $ORACLE_SID"
    echo
    echo "INSTANCE_NAME          : $FINAL_INSTANCE"
    echo "INSTANCE STATUS        : $FINAL_STATUS"
    echo
    echo "CDB                    : $FINAL_CDB"
    echo "OPEN_MODE              : $FINAL_MODE"
    echo

    if [[ "$FINAL_NAME" != "$NEW_NAME" ]]; then
        log_error "DB_NAME verification failed."
        return 1
    fi

    if [[ "$FINAL_DBID" != "$EXPECTED_DBID" ]]; then
        log_error "DBID verification failed."
        return 1
    fi

    if [[ "$FINAL_DB_UNIQUE" != "$EXPECTED_DB_UNIQUE" ]]; then
        log_error "DB_UNIQUE_NAME verification failed."
        return 1
    fi

    if [[ "$FINAL_INSTANCE" != "$NEW_NAME" ]]; then
        log_error "INSTANCE_NAME verification failed."
        return 1
    fi

    if [[ "$FINAL_STATUS" != "OPEN" ]]; then
        log_error "INSTANCE STATUS verification failed."
        return 1
    fi

    if [[ "$FINAL_CDB" != "YES" ]]; then
        log_error "CDB verification failed."
        return 1
    fi

    if [[ "$FINAL_MODE" != "READ WRITE" ]]; then
        log_error "OPEN_MODE verification failed."
        return 1
    fi

    if ! pmon_exists "$NEW_NAME"; then
        log_error "New PMON was not found:"
        echo "ora_pmon_${NEW_NAME}"
        return 1
    fi

    if pmon_exists "$OLD_SID"; then
        log_error "OLD PMON is still running:"
        echo "ora_pmon_${OLD_SID}"
        return 1
    fi

    log_ok "DB_NAME              : $FINAL_NAME"
    log_ok "DBID                 : unchanged"
    log_ok "DB_UNIQUE_NAME       : $FINAL_DB_UNIQUE"
    log_ok "ORACLE_SID           : $ORACLE_SID"
    log_ok "INSTANCE_NAME        : $FINAL_INSTANCE"
    log_ok "CDB                  : YES"
    log_ok "OPEN_MODE            : READ WRITE"
    log_ok "New PMON             : ora_pmon_${NEW_NAME}"
    log_ok "Old PMON             : not running"

    return 0
}

###############################################################################
# BASIC CHECKS
###############################################################################

echo
echo "============================================================"
echo " Oracle 26ai Full CDB Rename"
echo "============================================================"
echo "Date        : $(date)"
echo "Host        : $(hostname)"
echo "CSV         : $CSV_FILE"
echo "ORACLE_HOME : ${ORACLE_HOME:-NOT_SET}"
echo "MASTER LOG  : $MASTER_LOG"
echo "============================================================"
echo

if [[ ! -f "$CSV_FILE" ]]; then
    log_error "CSV file does not exist:"
    echo "$CSV_FILE"
    exit 1
fi

if [[ -z "${ORACLE_HOME:-}" ]]; then
    log_error "ORACLE_HOME is not set."
    exit 1
fi

if [[ ! -x "$ORACLE_HOME/bin/sqlplus" ]]; then
    log_error "sqlplus not found:"
    echo "$ORACLE_HOME/bin/sqlplus"
    exit 1
fi

if [[ ! -x "$ORACLE_HOME/bin/nid" ]]; then
    log_error "nid not found:"
    echo "$ORACLE_HOME/bin/nid"
    exit 1
fi

export PATH="$ORACLE_HOME/bin:$PATH"

###############################################################################
# ROOT CHECK
###############################################################################

if [[ $EUID -eq 0 ]]; then
    log_error "Do not run this script as root."
    echo "Run as the Oracle software owner."
    exit 1
fi

###############################################################################
# PROCESS CSV
###############################################################################

while IFS=',' read -r OLD_CDB NEW_CDB
do

    ###########################################################################
    # CLEAN INPUT
    ###########################################################################

    OLD_CDB=$(echo "$OLD_CDB" | tr -d '\r' | xargs)
    NEW_CDB=$(echo "$NEW_CDB" | tr -d '\r' | xargs)

    [[ -z "$OLD_CDB" ]] && continue

    ###########################################################################
    # HEADER
    ###########################################################################

    if [[ "$OLD_CDB" == "OLD_CDB" ]]; then
        continue
    fi

    ###########################################################################
    # PROCESS HEADER
    ###########################################################################

    echo
    echo
    echo "############################################################"
    echo "Processing:"
    echo "  OLD NAME : $OLD_CDB"
    echo "  NEW NAME : $NEW_CDB"
    echo "############################################################"
    echo

    ###########################################################################
    # VALIDATE NAMES
    ###########################################################################

    if ! valid_oracle_name "$OLD_CDB"; then
        log_error "Invalid OLD name: $OLD_CDB"
        continue
    fi

    if ! valid_oracle_name "$NEW_CDB"; then
        log_error "Invalid NEW name: $NEW_CDB"
        continue
    fi

    if [[ "$OLD_CDB" == "$NEW_CDB" ]]; then
        log_warn "OLD and NEW names are identical."
        continue
    fi

    ###########################################################################
    # OLD SID
    ###########################################################################

    export ORACLE_SID="$OLD_CDB"

    echo
    echo "Current ORACLE_SID:"
    echo "  $ORACLE_SID"

    ###########################################################################
    # CHECK OLD PMON
    ###########################################################################

    if ! pmon_exists "$OLD_CDB"; then

        log_error "Old PMON not found:"
        echo "ora_pmon_${OLD_CDB}"
        echo
        echo "The database must be running before starting."
        continue
    fi

    log_ok "Old PMON found."

    ###########################################################################
    # CHECK TARGET PMON
    ###########################################################################

    if pmon_exists "$NEW_CDB"; then

        log_error "Target PMON already exists:"
        echo "ora_pmon_${NEW_CDB}"
        echo
        echo "Refusing to continue."

        continue
    fi

    ###########################################################################
    # CURRENT DATABASE INFORMATION
    ###########################################################################

    DB_INFO=$(get_database_info 2>&1)
    DB_INFO_RC=$?

    if [[ $DB_INFO_RC -ne 0 ]]; then

        log_error "Unable to query V\$DATABASE."
        echo "$DB_INFO"

        continue
    fi

    IFS='|' read -r \
        CURRENT_NAME \
        CURRENT_DBID \
        CURRENT_CDB \
        CURRENT_MODE \
        CURRENT_DB_UNIQUE <<< "$DB_INFO"

    CURRENT_NAME=$(echo "$CURRENT_NAME" | xargs)
    CURRENT_DBID=$(echo "$CURRENT_DBID" | xargs)
    CURRENT_CDB=$(echo "$CURRENT_CDB" | xargs)
    CURRENT_MODE=$(echo "$CURRENT_MODE" | xargs)
    CURRENT_DB_UNIQUE=$(echo "$CURRENT_DB_UNIQUE" | xargs)

    echo
    echo "Current database:"
    echo "--------------------------------"
    echo "DB_NAME        : $CURRENT_NAME"
    echo "DBID           : $CURRENT_DBID"
    echo "DB_UNIQUE_NAME : $CURRENT_DB_UNIQUE"
    echo "CDB            : $CURRENT_CDB"
    echo "OPEN_MODE      : $CURRENT_MODE"
    echo "ORACLE_SID     : $ORACLE_SID"
    echo "--------------------------------"

    ###########################################################################
    # VALIDATE DATABASE
    ###########################################################################

    if [[ "$CURRENT_NAME" != "$OLD_CDB" ]]; then

        log_error "Current DB_NAME does not match OLD_CDB."
        echo "Expected: $OLD_CDB"
        echo "Actual  : $CURRENT_NAME"

        continue
    fi

    if [[ "$CURRENT_CDB" != "YES" ]]; then

        log_error "Database is not a CDB."

        continue
    fi

    if [[ "$CURRENT_MODE" != "READ WRITE" ]]; then

        log_error "Database is not READ WRITE."
        echo "Current mode: $CURRENT_MODE"

        continue
    fi

    ###########################################################################
    # RAC CHECK
    ###########################################################################

    CLUSTER_DB=$(get_cluster_database 2>&1)
    CLUSTER_RC=$?

    if [[ $CLUSTER_RC -ne 0 ]]; then

        log_error "Unable to read cluster_database."
        echo "$CLUSTER_DB"

        continue
    fi

    CLUSTER_DB=$(echo "$CLUSTER_DB" | xargs)

    if [[ "$CLUSTER_DB" == "TRUE" ]]; then

        log_error "RAC detected."
        echo "This script supports single-instance only."

        continue
    fi

    ###########################################################################
    # SPFILE
    ###########################################################################

    CURRENT_SPFILE=$(get_spfile 2>&1)
    SPFILE_RC=$?

    if [[ $SPFILE_RC -ne 0 ]]; then

        log_error "Unable to determine SPFILE."
        echo "$CURRENT_SPFILE"

        continue
    fi

    CURRENT_SPFILE=$(echo "$CURRENT_SPFILE" | xargs)

    if [[ -z "$CURRENT_SPFILE" ]]; then

        log_error "Database is not using an SPFILE."

        continue
    fi

    ###########################################################################
    # ASM CHECK
    ###########################################################################

    if [[ "$CURRENT_SPFILE" == +* ]]; then

        log_error "ASM SPFILE detected:"
        echo "$CURRENT_SPFILE"
        echo
        echo "This script only supports filesystem SPFILEs."
        echo "Use ASM/Grid Infrastructure specific procedures."

        continue
    fi

    if [[ ! -f "$CURRENT_SPFILE" ]]; then

        log_error "SPFILE does not exist:"
        echo "$CURRENT_SPFILE"

        continue
    fi

    echo
    echo "SPFILE:"
    echo "  $CURRENT_SPFILE"

    ###########################################################################
    # TIMESTAMP
    ###########################################################################

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    SPFILE_BACKUP="${BACKUP_DIR}/spfile_${OLD_CDB}_${TIMESTAMP}.ora"

    PFILE="${BACKUP_DIR}/init_${OLD_CDB}_${TIMESTAMP}.ora"

    NEW_SPFILE="${BACKUP_DIR}/spfile_${NEW_CDB}_${TIMESTAMP}.ora"

    OLD_SID_SPFILE_BACKUP="${BACKUP_DIR}/spfile_${OLD_CDB}_active_${TIMESTAMP}.ora"

    NID_LOG="${LOG_DIR}/${OLD_CDB}_to_${NEW_CDB}_nid_${TIMESTAMP}.log"

    ###########################################################################
    # NEW SID SPFILE LOCATION
    #
    # Oracle's normal startup search:
    #
    #   $ORACLE_HOME/dbs/spfile<SID>.ora
    #
    ###########################################################################

    NEW_SID_SPFILE="${ORACLE_HOME}/dbs/spfile${NEW_CDB}.ora"

    ###########################################################################
    # BACKUP SPFILE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Backing up original SPFILE"
    echo "============================================================"

    echo
    echo "Original:"
    echo "  $CURRENT_SPFILE"

    echo
    echo "Backup:"
    echo "  $SPFILE_BACKUP"

    if ! cp -p "$CURRENT_SPFILE" "$SPFILE_BACKUP"; then

        log_error "SPFILE backup failed."

        continue
    fi

    log_ok "Original SPFILE backed up."

    ###########################################################################
    # CREATE PFILE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Creating PFILE"
    echo "============================================================"

    if ! create_pfile "$CURRENT_SPFILE" "$PFILE"; then

        log_error "PFILE creation failed."

        continue
    fi

    if [[ ! -f "$PFILE" ]]; then

        log_error "PFILE was not created:"
        echo "$PFILE"

        continue
    fi

    log_ok "PFILE created:"
    echo "$PFILE"

    ###########################################################################
    # SHOW PARAMETERS BEFORE
    ###########################################################################

    echo
    echo "Current PFILE parameters:"
    echo "--------------------------------"

    grep -iE \
        "^[[:space:]]*\*?[[:space:]]*(db_name|db_unique_name)[[:space:]]*=" \
        "$PFILE" || true

    ###########################################################################
    # USER CONFIRMATION
    ###########################################################################

    echo
    echo "============================================================"
    echo "FULL RENAME"
    echo "============================================================"
    echo
    echo "This operation will change:"
    echo
    echo "  DB_NAME:"
    echo "      $OLD_CDB -> $NEW_CDB"
    echo
    echo "  DB_UNIQUE_NAME:"
    echo "      $CURRENT_DB_UNIQUE -> $NEW_CDB"
    echo
    echo "  ORACLE_SID:"
    echo "      $OLD_CDB -> $NEW_CDB"
    echo
    echo "  INSTANCE_NAME:"
    echo "      $OLD_CDB -> $NEW_CDB"
    echo
    echo "  PMON:"
    echo "      ora_pmon_${OLD_CDB}"
    echo "          ->"
    echo "      ora_pmon_${NEW_CDB}"
    echo
    echo "  /etc/oratab:"
    echo "      $OLD_CDB -> $NEW_CDB"
    echo
    echo "DBID WILL REMAIN:"
    echo "      $CURRENT_DBID"
    echo
    echo "RESETLOGS WILL NOT BE USED."
    echo
    echo "============================================================"
    echo

    read -r -p \
        "Type FULL-RENAME to continue: " \
        CONFIRM < /dev/tty

    if [[ "$CONFIRM" != "FULL-RENAME" ]]; then

        log_warn "Operation cancelled by user."

        continue
    fi

    ###########################################################################
    # SHUTDOWN
    ###########################################################################

    echo
    echo "============================================================"
    echo "SHUTDOWN"
    echo "============================================================"

    if ! shutdown_database; then

        log_error "Shutdown failed."

        continue
    fi

    ###########################################################################
    # WAIT FOR PMON STOP
    ###########################################################################

    echo
    echo "Waiting for old PMON to stop..."

    if ! wait_for_pmon_stop "$OLD_CDB" 90; then

        log_error "Old PMON is still running:"
        echo "ora_pmon_${OLD_CDB}"

        continue
    fi

    log_ok "Old instance stopped."

    ###########################################################################
    # STARTUP MOUNT
    ###########################################################################

    echo
    echo "============================================================"
    echo "STARTUP MOUNT"
    echo "============================================================"

    if ! startup_mount; then

        log_error "STARTUP MOUNT failed."

        continue
    fi

    if ! wait_for_pmon "$OLD_CDB" 60; then

        log_error "Old PMON did not start."

        continue
    fi

    ###########################################################################
    # VERIFY MOUNT
    ###########################################################################

    MOUNT_INFO=$(get_database_info 2>&1)
    MOUNT_RC=$?

    if [[ $MOUNT_RC -ne 0 ]]; then

        log_error "Unable to query database in MOUNT mode."
        echo "$MOUNT_INFO"

        continue
    fi

    IFS='|' read -r \
        MOUNT_NAME \
        MOUNT_DBID \
        MOUNT_CDB \
        MOUNT_MODE \
        MOUNT_DB_UNIQUE <<< "$MOUNT_INFO"

    MOUNT_NAME=$(echo "$MOUNT_NAME" | xargs)
    MOUNT_DBID=$(echo "$MOUNT_DBID" | xargs)
    MOUNT_CDB=$(echo "$MOUNT_CDB" | xargs)
    MOUNT_MODE=$(echo "$MOUNT_MODE" | xargs)
    MOUNT_DB_UNIQUE=$(echo "$MOUNT_DB_UNIQUE" | xargs)

    echo
    echo "Mounted database:"
    echo "  DB_NAME        : $MOUNT_NAME"
    echo "  DBID           : $MOUNT_DBID"
    echo "  DB_UNIQUE_NAME : $MOUNT_DB_UNIQUE"
    echo "  CDB            : $MOUNT_CDB"
    echo "  OPEN_MODE      : $MOUNT_MODE"

    if [[ "$MOUNT_MODE" != "MOUNTED" ]]; then

        log_error "Database is not MOUNTED."

        continue
    fi

    if [[ "$MOUNT_DBID" != "$CURRENT_DBID" ]]; then

        log_error "DBID changed before NID."
        echo "Original: $CURRENT_DBID"
        echo "Current : $MOUNT_DBID"

        continue
    fi

    ###########################################################################
    # DBNEWID
    #
    # IMPORTANT:
    #
    # NID changes DB_NAME.
    # NID does NOT change DB_UNIQUE_NAME.
    # NID does NOT change ORACLE_SID.
    ###########################################################################

    echo
    echo "============================================================"
    echo "DBNEWID"
    echo "============================================================"

    echo
    echo "Command:"
    echo
    echo "nid TARGET=/ DBNAME=$NEW_CDB SETNAME=YES"
    echo
    echo "NID log:"
    echo "$NID_LOG"
    echo

    "$ORACLE_HOME/bin/nid" \
        TARGET=/ \
        DBNAME="$NEW_CDB" \
        SETNAME=YES \
        LOGFILE="$NID_LOG"

    NID_RC=$?

    ###########################################################################
    # NID FAILURE
    ###########################################################################

    if [[ $NID_RC -ne 0 ]]; then

        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_error "DBNEWID FAILED"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo
        echo "Return code: $NID_RC"
        echo
        echo "NID log:"
        echo "  $NID_LOG"
        echo
        echo "DO NOT rerun NID automatically."
        echo

        continue
    fi

    log_ok "DBNEWID completed successfully."

    ###########################################################################
    # NID SETNAME=YES SHUTS DOWN INSTANCE
    ###########################################################################

    echo
    echo "Waiting for NID to stop the instance..."

    if ! wait_for_pmon_stop "$OLD_CDB" 90; then

        log_error "Old PMON still exists after NID."

        continue
    fi

    log_ok "Instance stopped after NID."

    ###########################################################################
    # MODIFY PFILE
    #
    # NID changed DB_NAME in the control files.
    #
    # Now we update:
    #
    #   DB_NAME
    #   DB_UNIQUE_NAME
    ###########################################################################

    echo
    echo "============================================================"
    echo "Updating PFILE"
    echo "============================================================"

    echo
    echo "DB_NAME:"
    echo "  $OLD_CDB -> $NEW_CDB"

    set_pfile_parameter \
        "$PFILE" \
        "db_name" \
        "$NEW_CDB"

    echo
    echo "DB_UNIQUE_NAME:"
    echo "  $CURRENT_DB_UNIQUE -> $NEW_CDB"

    set_pfile_parameter \
        "$PFILE" \
        "db_unique_name" \
        "$NEW_CDB"

    ###########################################################################
    # VERIFY PFILE
    ###########################################################################

    echo
    echo "PFILE parameters after modification:"
    echo "--------------------------------"

    grep -iE \
        "^[[:space:]]*\*?[[:space:]]*(db_name|db_unique_name)[[:space:]]*=" \
        "$PFILE" || true

    if ! verify_pfile_parameter \
        "$PFILE" \
        "db_name" \
        "$NEW_CDB"
    then

        log_error "DB_NAME was not correctly updated in PFILE."

        continue
    fi

    if ! verify_pfile_parameter \
        "$PFILE" \
        "db_unique_name" \
        "$NEW_CDB"
    then

        log_error "DB_UNIQUE_NAME was not correctly updated in PFILE."

        continue
    fi

    log_ok "DB_NAME verified in PFILE."
    log_ok "DB_UNIQUE_NAME verified in PFILE."

    ###########################################################################
    # CREATE NEW SPFILE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Creating NEW SPFILE"
    echo "============================================================"

    echo
    echo "Temporary:"
    echo "  $NEW_SPFILE"

    if ! create_spfile "$NEW_SPFILE" "$PFILE"; then

        log_error "New SPFILE creation failed."

        continue
    fi

    if [[ ! -f "$NEW_SPFILE" ]]; then

        log_error "New SPFILE does not exist:"
        echo "$NEW_SPFILE"

        continue
    fi

    log_ok "New SPFILE created."

    ###########################################################################
    # BACKUP NEW SID SPFILE IF IT ALREADY EXISTS
    ###########################################################################

    if [[ -f "$NEW_SID_SPFILE" ]]; then

        log_warn "Target SID SPFILE already exists:"
        echo "$NEW_SID_SPFILE"

        TARGET_SPFILE_BACKUP="${BACKUP_DIR}/spfile_${NEW_CDB}_existing_${TIMESTAMP}.ora"

        if ! cp -p "$NEW_SID_SPFILE" "$TARGET_SPFILE_BACKUP"; then

            log_error "Could not backup existing target SPFILE."

            continue
        fi

        log_ok "Existing target SPFILE backed up:"
        echo "$TARGET_SPFILE_BACKUP"
    fi

    ###########################################################################
    # INSTALL NEW SID SPFILE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Installing SID-specific SPFILE"
    echo "============================================================"

    echo
    echo "New SID:"
    echo "  $NEW_CDB"

    echo
    echo "New SPFILE:"
    echo "  $NEW_SID_SPFILE"

    if ! cp -p "$NEW_SPFILE" "$NEW_SID_SPFILE"; then

        log_error "Could not install new SID SPFILE."

        continue
    fi

    log_ok "New SID SPFILE installed."

    ###########################################################################
    # VERIFY NEW SPFILE
    ###########################################################################

    if [[ ! -f "$NEW_SID_SPFILE" ]]; then

        log_error "New SID SPFILE does not exist."

        continue
    fi

    ###########################################################################
    # BACKUP ORIGINAL ACTIVE SPFILE
    ###########################################################################

    if [[ -f "$CURRENT_SPFILE" ]]; then

        if ! cp -p \
            "$CURRENT_SPFILE" \
            "$OLD_SID_SPFILE_BACKUP"
        then

            log_error "Could not create active SPFILE backup."

            continue
        fi

        log_ok "Original active SPFILE backed up:"
        echo "$OLD_SID_SPFILE_BACKUP"
    fi

    ###########################################################################
    # UPDATE /etc/oratab
    ###########################################################################

    echo
    echo "============================================================"
    echo "Updating /etc/oratab"
    echo "============================================================"

    if ! update_oratab "$OLD_CDB" "$NEW_CDB"; then

        log_error "/etc/oratab update failed."

        continue
    fi

    ###########################################################################
    # CHANGE ORACLE_SID
    #
    # This happens ONLY AFTER NID and SPFILE preparation are complete.
    ###########################################################################

    echo
    echo "============================================================"
    echo "Changing ORACLE_SID"
    echo "============================================================"

    export ORACLE_SID="$NEW_CDB"

    echo
    echo "ORACLE_SID:"
    echo "  $ORACLE_SID"

    ###########################################################################
    # VERIFY OLD PMON IS GONE
    ###########################################################################

    if pmon_exists "$OLD_CDB"; then

        log_error "Old PMON still exists:"
        echo "ora_pmon_${OLD_CDB}"

        continue
    fi

    ###########################################################################
    # TARGET PMON SHOULD NOT EXIST YET
    ###########################################################################

    if pmon_exists "$NEW_CDB"; then

        log_error "New PMON unexpectedly already exists:"
        echo "ora_pmon_${NEW_CDB}"

        continue
    fi

    ###########################################################################
    # STARTUP WITH NEW SID
    ###########################################################################

    echo
    echo "============================================================"
    echo "STARTING DATABASE WITH NEW SID"
    echo "============================================================"

    echo
    echo "ORACLE_SID:"
    echo "  $ORACLE_SID"

    echo
    echo "Expected SPFILE:"
    echo "  $NEW_SID_SPFILE"

    if ! startup_normal; then

        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_error "STARTUP WITH NEW SID FAILED"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo
        echo "ORACLE_SID:"
        echo "  $ORACLE_SID"
        echo
        echo "Expected SPFILE:"
        echo "  $NEW_SID_SPFILE"
        echo
        echo "Original DBID:"
        echo "  $CURRENT_DBID"
        echo
        echo "PFILE:"
        echo "  $PFILE"
        echo
        echo "NID log:"
        echo "  $NID_LOG"
        echo

        continue
    fi

    ###########################################################################
    # WAIT FOR NEW PMON
    ###########################################################################

    echo
    echo "Waiting for new PMON..."

    if ! wait_for_pmon "$NEW_CDB" 90; then

        log_error "New PMON did not appear:"
        echo "ora_pmon_${NEW_CDB}"

        continue
    fi

    log_ok "New PMON found:"
    echo "ora_pmon_${NEW_CDB}"

    ###########################################################################
    # FINAL VERIFICATION
    ###########################################################################

    if final_verification \
        "$OLD_CDB" \
        "$NEW_CDB" \
        "$CURRENT_DBID" \
        "$NEW_CDB"
    then

        echo
        echo "############################################################"
        echo "FULL RENAME SUCCESSFUL"
        echo "############################################################"
        echo
        echo "OLD DB_NAME        : $OLD_CDB"
        echo "NEW DB_NAME        : $NEW_CDB"
        echo
        echo "DBID               : $CURRENT_DBID"
        echo "DBID               : UNCHANGED"
        echo
        echo "DB_UNIQUE_NAME     : $NEW_CDB"
        echo
        echo "ORACLE_SID         : $NEW_CDB"
        echo
        echo "INSTANCE_NAME      : $NEW_CDB"
        echo
        echo "PMON               : ora_pmon_${NEW_CDB}"
        echo
        echo "CDB                : YES"
        echo "OPEN_MODE          : READ WRITE"
        echo
        echo "RESETLOGS          : NOT USED"
        echo
        echo "############################################################"

    else

        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_error "FULL RENAME VERIFICATION FAILED"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo
        echo "DO NOT perform dependent work."
        echo
        echo "Master log:"
        echo "  $MASTER_LOG"
        echo
        echo "NID log:"
        echo "  $NID_LOG"
        echo
        echo "PFILE:"
        echo "  $PFILE"
        echo
        echo "Original SPFILE backup:"
        echo "  $SPFILE_BACKUP"
        echo

        continue
    fi

    ###########################################################################
    # COMPLETED
    ###########################################################################

    echo
    echo "Completed:"
    echo "  $OLD_CDB -> $NEW_CDB"
    echo

done < "$CSV_FILE"

###############################################################################
# END
###############################################################################

echo
echo "============================================================"
echo "ALL CDB PROCESSING COMPLETED"
echo "============================================================"
echo
echo "Master log:"
echo "  $MASTER_LOG"
echo
echo "NID logs:"
echo "  $LOG_DIR"
echo
echo "Backups:"
echo "  $BACKUP_DIR"
echo
echo "============================================================"
