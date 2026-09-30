#!/bin/bash

###############################################################################
# Oracle Multiple CDB Rename
#
# PURPOSE
# -------
# Rename an Oracle CDB while:
#
#   OLD DB_NAME      -> NEW DB_NAME
#   OLD ORACLE_SID   -> NEW ORACLE_SID
#   OLD PMON         -> NEW PMON
#
# DBID:
#   MUST remain unchanged.
#
# DB_UNIQUE_NAME:
#   MUST remain unchanged.
#
# RESETLOGS:
#   NOT performed.
#
# NID:
#   nid TARGET=/ DBNAME=NEW_NAME SETNAME=YES
#
# IMPORTANT:
#   PMON existence alone is NOT considered proof that SYSDBA
#   connectivity works.
#
# CSV:
#
#   OLD_CDB,NEW_CDB
#
# Example:
#
#
# Usage:
#
#   ./rename_multiple_cdb.sh cdb_rename_list.csv
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
# VALIDATE ORACLE NAME
#
# Oracle DB_NAME/SID used here:
#   maximum 8 characters
###############################################################################

valid_oracle_name()
{
    local NAME="$1"

    [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9_\$#]{0,7}$ ]]
}

###############################################################################
# PMON PID
###############################################################################

get_pmon_pid()
{
    local SID="$1"

    pgrep -f "ora_pmon_${SID}" | head -1
}

###############################################################################
# PMON EXISTS
###############################################################################

pmon_exists()
{
    local SID="$1"

    [[ -n "$(get_pmon_pid "$SID")" ]]
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
# WAIT FOR PMON STOP
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
# FIND ORACLE HOME FROM PMON
#
# This is important when the shell ORACLE_HOME does not match the
# Oracle Home used by the running instance.
###############################################################################

get_pmon_oracle_home()
{
    local SID="$1"
    local PID

    PID=$(get_pmon_pid "$SID")

    [[ -z "$PID" ]] && return 1

    if [[ -e "/proc/$PID/exe" ]]; then

        local EXE

        EXE=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)

        if [[ "$EXE" == */bin/oracle ]]; then
            dirname "$(dirname "$EXE")"
            return 0
        fi

    fi

    return 1
}

###############################################################################
# FIND ORACLE_HOME FROM /etc/orATAB
###############################################################################

get_oratab_home()
{
    local SID="$1"

    if [[ -f /etc/oratab ]]; then

        awk -F: -v sid="$SID" '
            $1 == sid {
                print $2
                exit
            }
        ' /etc/oratab

    fi
}

###############################################################################
# SQLPLUS BASIC CONNECTIVITY TEST
#
# Returns success ONLY when SQL can actually query V$INSTANCE.
###############################################################################

test_sysdba()
{
    local OUTPUT
    local RC

    OUTPUT=$(
        "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off
set trimspool on

select trim(instance_name) || '|' ||
       trim(status)
from v$instance;

exit;
EOF
    )

    RC=$?

    if [[ $RC -ne 0 ]]; then
        echo "$OUTPUT"
        return 1
    fi

    if ! echo "$OUTPUT" | grep -q '|'; then
        echo "$OUTPUT"
        return 1
    fi

    echo "$OUTPUT"

    return 0
}

###############################################################################
# GET DATABASE INFORMATION
###############################################################################

get_database_info()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
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
from v$database;

exit;
EOF
}

###############################################################################
# GET SPFILE
###############################################################################

get_spfile()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off
set trimspool on

select trim(value)
from v$parameter
where name='spfile';

exit;
EOF
}

###############################################################################
# GET CLUSTER DATABASE
###############################################################################

get_cluster_database()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set heading off
set feedback off
set pagesize 0
set verify off
set echo off
set trimspool on

select trim(value)
from v$parameter
where name='cluster_database';

exit;
EOF
}

###############################################################################
# DISPLAY DATABASE
###############################################################################

show_database()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set lines 200
set pages 100

col name format a15
col db_unique_name format a30
col open_mode format a15
col cdb format a5

select
    name,
    db_unique_name,
    open_mode,
    cdb
from v$database;

show parameter db_name
show parameter db_unique_name
show parameter spfile

exit;
EOF
}

###############################################################################
# SHUTDOWN
###############################################################################

shutdown_database()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set echo on

shutdown immediate;

exit;
EOF
}

###############################################################################
# STARTUP MOUNT
###############################################################################

startup_mount()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set echo on

startup mount;

exit;
EOF
}

###############################################################################
# RUN NID
###############################################################################

run_nid()
{
    local NEW_NAME="$1"
    local NID_LOG="$2"

    "$ORACLE_HOME/bin/nid" \
        TARGET=/ \
        DBNAME="$NEW_NAME" \
        SETNAME=YES \
        LOGFILE="$NID_LOG"
}

###############################################################################
# ALTER DB_NAME IN SPFILE
#
# This is intentionally done through Oracle rather than sed-editing
# a text PFILE.
###############################################################################

set_db_name_spfile()
{
    local NEW_NAME="$1"

    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

alter system set db_name='$NEW_NAME' scope=spfile;

exit;
EOF
}

###############################################################################
# STARTUP FORCE
###############################################################################

startup_force()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set echo on

startup force;

exit;
EOF
}

###############################################################################
# NORMAL STARTUP
###############################################################################

startup_normal()
{
    "$ORACLE_HOME/bin/sqlplus" -L -s / as sysdba <<'EOF'
whenever sqlerror exit sql.sqlcode
whenever oserror exit failure

set echo on

startup;

exit;
EOF
}

###############################################################################
# FINAL VERIFICATION
#
# Checks:
#   DB_NAME
#   DBID
#   CDB
#   OPEN_MODE
#   DB_UNIQUE_NAME
#   ORACLE_SID
#   PMON
###############################################################################

final_verification()
{
    local OLD_SID="$1"
    local NEW_NAME="$2"
    local EXPECTED_DBID="$3"
    local EXPECTED_DB_UNIQUE="$4"

    local INFO
    local RC

    INFO=$(get_database_info 2>&1)
    RC=$?

    if [[ $RC -ne 0 ]]; then

        echo
        log_error "FINAL VERIFICATION: V\$DATABASE query failed."
        echo
        echo "$INFO"

        return 1
    fi

    local FINAL_NAME
    local FINAL_DBID
    local FINAL_CDB
    local FINAL_MODE
    local FINAL_DB_UNIQUE

    IFS='|' read -r \
        FINAL_NAME \
        FINAL_DBID \
        FINAL_CDB \
        FINAL_MODE \
        FINAL_DB_UNIQUE <<< "$INFO"

    FINAL_NAME=$(echo "$FINAL_NAME" | xargs)
    FINAL_DBID=$(echo "$FINAL_DBID" | xargs)
    FINAL_CDB=$(echo "$FINAL_CDB" | xargs)
    FINAL_MODE=$(echo "$FINAL_MODE" | xargs)
    FINAL_DB_UNIQUE=$(echo "$FINAL_DB_UNIQUE" | xargs)

    echo
    echo "============================================================"
    echo "FINAL VERIFICATION"
    echo "============================================================"
    echo
    echo "Expected DB_NAME        : $NEW_NAME"
    echo "Actual DB_NAME          : $FINAL_NAME"
    echo
    echo "Original DBID           : $EXPECTED_DBID"
    echo "Current DBID            : $FINAL_DBID"
    echo
    echo "Expected CDB            : YES"
    echo "Actual CDB              : $FINAL_CDB"
    echo
    echo "OPEN_MODE               : $FINAL_MODE"
    echo
    echo "Original DB_UNIQUE_NAME : $EXPECTED_DB_UNIQUE"
    echo "Current DB_UNIQUE_NAME  : $FINAL_DB_UNIQUE"
    echo
    echo "Expected ORACLE_SID     : $NEW_NAME"
    echo "Current ORACLE_SID      : $ORACLE_SID"
    echo

    ###########################################################################
    # DB_NAME
    ###########################################################################

    if [[ "$FINAL_NAME" != "$NEW_NAME" ]]; then
        log_error "DB_NAME verification FAILED."
        return 1
    fi

    log_ok "DB_NAME = $NEW_NAME"

    ###########################################################################
    # DBID
    ###########################################################################

    if [[ "$FINAL_DBID" != "$EXPECTED_DBID" ]]; then
        log_error "DBID changed!"
        return 1
    fi

    log_ok "DBID unchanged = $FINAL_DBID"

    ###########################################################################
    # CDB
    ###########################################################################

    if [[ "$FINAL_CDB" != "YES" ]]; then
        log_error "Database is no longer a CDB."
        return 1
    fi

    log_ok "CDB = YES"

    ###########################################################################
    # OPEN MODE
    ###########################################################################

    if [[ "$FINAL_MODE" != "READ WRITE" ]]; then
        log_error "Database is not READ WRITE."
        return 1
    fi

    log_ok "OPEN_MODE = READ WRITE"

    ###########################################################################
    # DB_UNIQUE_NAME
    ###########################################################################

    if [[ "$FINAL_DB_UNIQUE" != "$EXPECTED_DB_UNIQUE" ]]; then
        log_error "DB_UNIQUE_NAME changed unexpectedly."
        return 1
    fi

    log_ok "DB_UNIQUE_NAME unchanged = $FINAL_DB_UNIQUE"

    ###########################################################################
    # ORACLE_SID
    ###########################################################################

    if [[ "$ORACLE_SID" != "$NEW_NAME" ]]; then
        log_error "ORACLE_SID is not the new SID."
        return 1
    fi

    log_ok "ORACLE_SID = $ORACLE_SID"

    ###########################################################################
    # PMON
    ###########################################################################

    if ! pmon_exists "$NEW_NAME"; then
        log_error "New PMON not found:"
        echo "ora_pmon_${NEW_NAME}"
        return 1
    fi

    log_ok "New PMON exists:"
    echo "  ora_pmon_${NEW_NAME}"

    ###########################################################################
    # OLD PMON MUST NOT EXIST
    ###########################################################################

    if pmon_exists "$OLD_SID"; then

        log_error "OLD PMON still exists:"
        echo "  ora_pmon_${OLD_SID}"

        return 1
    fi

    log_ok "Old PMON no longer exists."

    return 0
}

###############################################################################
# BASIC CHECKS
###############################################################################

echo
echo "============================================================"
echo " Oracle CDB DB_NAME + ORACLE_SID Rename"
echo "============================================================"
echo
echo "Date        : $(date)"
echo "Host        : $(hostname)"
echo "CSV         : $CSV_FILE"
echo "ORACLE_HOME : ${ORACLE_HOME:-NOT_SET}"
echo "MASTER LOG  : $MASTER_LOG"
echo
echo "============================================================"
echo

if [[ ! -f "$CSV_FILE" ]]; then

    log_error "CSV file does not exist:"
    echo "  $CSV_FILE"

    exit 1
fi

if [[ -z "${ORACLE_HOME:-}" ]]; then

    log_error "ORACLE_HOME is not set."

    echo
    echo "Set it before running the script, for example:"
    echo
    echo "export ORACLE_HOME=/opt/app/oracle/product/26ai"
    echo

    exit 1
fi

if [[ ! -x "$ORACLE_HOME/bin/sqlplus" ]]; then

    log_error "sqlplus not found:"
    echo "  $ORACLE_HOME/bin/sqlplus"

    exit 1
fi

if [[ ! -x "$ORACLE_HOME/bin/nid" ]]; then

    log_error "nid not found:"
    echo "  $ORACLE_HOME/bin/nid"

    exit 1
fi

export PATH="$ORACLE_HOME/bin:$PATH"

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

    ###########################################################################
    # EMPTY
    ###########################################################################

    [[ -z "$OLD_CDB" ]] && continue

    ###########################################################################
    # HEADER
    ###########################################################################

    if [[ "$OLD_CDB" == "OLD_CDB" || "$OLD_CDB" == "OLD_DB" ]]; then
        continue
    fi

    ###########################################################################
    # SEPARATOR
    ###########################################################################

    echo
    echo
    echo "############################################################"
    echo "Processing database"
    echo "############################################################"
    echo
    echo "OLD DB_NAME / SID : $OLD_CDB"
    echo "NEW DB_NAME / SID : $NEW_CDB"
    echo
    echo "############################################################"
    echo

    ###########################################################################
    # VALIDATION
    ###########################################################################

    if ! valid_oracle_name "$OLD_CDB"; then

        log_error "Invalid OLD database/SID:"
        echo "  $OLD_CDB"

        continue
    fi

    if ! valid_oracle_name "$NEW_CDB"; then

        log_error "Invalid NEW database/SID:"
        echo "  $NEW_CDB"

        continue
    fi

    if [[ "$OLD_CDB" == "$NEW_CDB" ]]; then

        log_warn "OLD and NEW names are identical."

        continue
    fi

    ###########################################################################
    # SET OLD SID
    ###########################################################################

    export ORACLE_SID="$OLD_CDB"

    echo
    echo "============================================================"
    echo "Current Oracle SID"
    echo "============================================================"
    echo
    echo "ORACLE_SID:"
    echo "  $ORACLE_SID"
    echo

    ###########################################################################
    # PMON CHECK
    ###########################################################################

    if ! pmon_exists "$OLD_CDB"; then

        log_error "Old PMON not found:"
        echo "  ora_pmon_${OLD_CDB}"
        echo
        echo "Database must be running before the rename."
        echo

        continue
    fi

    OLD_PMON_PID=$(get_pmon_pid "$OLD_CDB")

    log_ok "Old PMON found:"
    echo "  PID : $OLD_PMON_PID"
    echo "  PMON: ora_pmon_${OLD_CDB}"

    ###########################################################################
    # DETERMINE ORACLE HOME FROM PMON
    ###########################################################################

    PMON_HOME=$(get_pmon_oracle_home "$OLD_CDB" 2>/dev/null || true)

    if [[ -n "$PMON_HOME" && -x "$PMON_HOME/bin/sqlplus" ]]; then

        log_info "Oracle Home detected from running PMON:"
        echo "  $PMON_HOME"

        export ORACLE_HOME="$PMON_HOME"
        export PATH="$ORACLE_HOME/bin:$PATH"

    else

        log_warn "Could not determine Oracle Home from PMON."

        ORATAB_HOME=$(get_oratab_home "$OLD_CDB" | head -1 | xargs || true)

        if [[ -n "$ORATAB_HOME" && -x "$ORATAB_HOME/bin/sqlplus" ]]; then

            log_info "Using Oracle Home from /etc/oratab:"
            echo "  $ORATAB_HOME"

            export ORACLE_HOME="$ORATAB_HOME"
            export PATH="$ORACLE_HOME/bin:$PATH"

        else

            log_info "Using existing ORACLE_HOME:"
            echo "  $ORACLE_HOME"

        fi

    fi

    ###########################################################################
    # VERIFY SQLPLUS
    ###########################################################################

    echo
    echo "============================================================"
    echo "Checking SYSDBA connectivity"
    echo "============================================================"
    echo

    echo "ORACLE_SID : $ORACLE_SID"
    echo "ORACLE_HOME: $ORACLE_HOME"
    echo

    CONNECT_TEST=$(test_sysdba 2>&1)
    CONNECT_RC=$?

    if [[ $CONNECT_RC -ne 0 ]]; then

        echo "$CONNECT_TEST"

        echo
        log_error "Unable to query V\$INSTANCE."
        echo
        echo "PMON exists, but the instance is not accepting"
        echo "SYSDBA connections using:"
        echo
        echo "  ORACLE_SID=$ORACLE_SID"
        echo "  ORACLE_HOME=$ORACLE_HOME"
        echo
        echo "DO NOT run NID."
        echo
        echo "Check:"
        echo
        echo "  ps -ef | grep '[o]ra_pmon_${OLD_CDB}'"
        echo "  echo \$ORACLE_HOME"
        echo "  echo \$ORACLE_SID"
        echo "  readlink -f /proc/${OLD_PMON_PID}/exe"
        echo

        continue
    fi

    log_ok "SYSDBA connectivity confirmed."

    echo
    echo "Instance information:"
    echo "  $CONNECT_TEST"

    ###########################################################################
    # DATABASE INFORMATION
    ###########################################################################

    echo
    echo "============================================================"
    echo "Reading current database information"
    echo "============================================================"
    echo

    DB_INFO=$(get_database_info 2>&1)
    DB_INFO_RC=$?

    if [[ $DB_INFO_RC -ne 0 ]]; then

        log_error "Unable to query V\$DATABASE."
        echo
        echo "$DB_INFO"
        echo

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
    echo "------------------------------------------------------------"
    echo "DB_NAME        : $CURRENT_NAME"
    echo "DBID           : $CURRENT_DBID"
    echo "CDB            : $CURRENT_CDB"
    echo "OPEN_MODE      : $CURRENT_MODE"
    echo "DB_UNIQUE_NAME : $CURRENT_DB_UNIQUE"
    echo "ORACLE_SID     : $ORACLE_SID"
    echo "------------------------------------------------------------"

    ###########################################################################
    # VALIDATE DATABASE
    ###########################################################################

    if [[ "$CURRENT_NAME" != "$OLD_CDB" ]]; then

        log_error "DB_NAME does not match expected OLD name."

        echo "Expected:"
        echo "  $OLD_CDB"

        echo "Actual:"
        echo "  $CURRENT_NAME"

        continue
    fi

    if [[ "$CURRENT_CDB" != "YES" ]]; then

        log_error "Database is not a CDB."

        continue
    fi

    if [[ "$CURRENT_MODE" != "READ WRITE" ]]; then

        log_error "Database is not READ WRITE."

        echo "Current OPEN_MODE:"
        echo "  $CURRENT_MODE"

        continue
    fi

    ###########################################################################
    # RAC CHECK
    ###########################################################################

    CLUSTER_DB=$(get_cluster_database 2>&1)
    CLUSTER_RC=$?

    if [[ $CLUSTER_RC -ne 0 ]]; then

        log_error "Unable to query cluster_database."
        echo "$CLUSTER_DB"

        continue
    fi

    CLUSTER_DB=$(echo "$CLUSTER_DB" | xargs)

    if [[ "$CLUSTER_DB" == "TRUE" ]]; then

        log_error "RAC database detected."

        echo "This script is for single-instance databases only."

        continue
    fi

    ###########################################################################
    # TARGET PMON CHECK
    ###########################################################################

    if pmon_exists "$NEW_CDB"; then

        log_error "Target PMON already exists:"
        echo "  ora_pmon_${NEW_CDB}"

        echo
        echo "Do not continue because the target SID is already in use."

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

    if [[ ! -f "$CURRENT_SPFILE" ]]; then

        log_error "SPFILE does not exist:"
        echo "  $CURRENT_SPFILE"

        continue
    fi

    echo
    echo "SPFILE:"
    echo "  $CURRENT_SPFILE"

    ###########################################################################
    # TIMESTAMP / BACKUPS
    ###########################################################################

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    SPFILE_BACKUP="${BACKUP_DIR}/spfile_${OLD_CDB}_${TIMESTAMP}.ora"

    NID_LOG="${LOG_DIR}/${OLD_CDB}_to_${NEW_CDB}_nid_${TIMESTAMP}.log"

    ###########################################################################
    # BACKUP SPFILE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Backing up SPFILE"
    echo "============================================================"
    echo
    echo "Source:"
    echo "  $CURRENT_SPFILE"
    echo
    echo "Backup:"
    echo "  $SPFILE_BACKUP"
    echo

    if ! cp -p "$CURRENT_SPFILE" "$SPFILE_BACKUP"; then

        log_error "SPFILE backup failed."

        continue
    fi

    log_ok "SPFILE backup created."

    ###########################################################################
    # SHOW CONFIGURATION
    ###########################################################################

    echo
    echo "============================================================"
    echo "Current Oracle configuration"
    echo "============================================================"
    echo

    show_database

    CONFIG_RC=$?

    if [[ $CONFIG_RC -ne 0 ]]; then

        log_error "Could not display database configuration."

        continue
    fi

    ###########################################################################
    # CONFIRMATION
    ###########################################################################

    echo
    echo "============================================================"
    echo "IMPORTANT"
    echo "============================================================"
    echo
    echo "This operation will change:"
    echo
    echo "  DB_NAME"
    echo "      $OLD_CDB -> $NEW_CDB"
    echo
    echo "  ORACLE_SID"
    echo "      $OLD_CDB -> $NEW_CDB"
    echo
    echo "  PMON"
    echo "      ora_pmon_${OLD_CDB}"
    echo "          ->"
    echo "      ora_pmon_${NEW_CDB}"
    echo
    echo "The following MUST remain unchanged:"
    echo
    echo "  DBID"
    echo "      $CURRENT_DBID"
    echo
    echo "  DB_UNIQUE_NAME"
    echo "      $CURRENT_DB_UNIQUE"
    echo
    echo "RESETLOGS:"
    echo "  NOT USED"
    echo
    echo "NID command:"
    echo
    echo "  nid TARGET=/ DBNAME=$NEW_CDB SETNAME=YES"
    echo
    echo "============================================================"
    echo

    read -r -p \
        "Type YES to rename $OLD_CDB -> $NEW_CDB: " \
        CONFIRM < /dev/tty

    if [[ "$CONFIRM" != "YES" ]]; then

        log_warn "Skipped by user."

        continue
    fi

    ###########################################################################
    # SHUTDOWN
    ###########################################################################

    echo
    echo "============================================================"
    echo "Shutting down database"
    echo "============================================================"
    echo

    if ! shutdown_database; then

        log_error "SHUTDOWN IMMEDIATE failed."

        continue
    fi

    ###########################################################################
    # WAIT FOR OLD PMON TO STOP
    ###########################################################################

    echo
    echo "Waiting for old PMON to stop..."

    if ! wait_for_pmon_stop "$OLD_CDB" 120; then

        log_error "Old PMON is still running."

        echo "  ora_pmon_${OLD_CDB}"

        continue
    fi

    log_ok "Old instance stopped."

    ###########################################################################
    # STARTUP MOUNT
    ###########################################################################

    echo
    echo "============================================================"
    echo "Starting OLD SID in MOUNT mode"
    echo "============================================================"
    echo

    if ! startup_mount; then

        log_error "STARTUP MOUNT failed."

        continue
    fi

    ###########################################################################
    # WAIT FOR OLD PMON
    ###########################################################################

    if ! wait_for_pmon "$OLD_CDB" 90; then

        log_error "Old PMON did not appear after STARTUP MOUNT."

        continue
    fi

    log_ok "Old PMON running in MOUNT mode."

    ###########################################################################
    # VERIFY MOUNT
    ###########################################################################

    MOUNT_INFO=$(get_database_info 2>&1)
    MOUNT_RC=$?

    if [[ $MOUNT_RC -ne 0 ]]; then

        log_error "Could not query V\$DATABASE in MOUNT mode."

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
    echo "------------------------------------------------------------"
    echo "DB_NAME        : $MOUNT_NAME"
    echo "DBID           : $MOUNT_DBID"
    echo "CDB            : $MOUNT_CDB"
    echo "OPEN_MODE      : $MOUNT_MODE"
    echo "DB_UNIQUE_NAME : $MOUNT_DB_UNIQUE"
    echo "------------------------------------------------------------"

    if [[ "$MOUNT_MODE" != "MOUNTED" ]]; then

        log_error "Database is not MOUNTED."

        continue
    fi

    if [[ "$MOUNT_DBID" != "$CURRENT_DBID" ]]; then

        log_error "DBID changed before NID."

        echo "Original:"
        echo "  $CURRENT_DBID"

        echo "Current:"
        echo "  $MOUNT_DBID"

        continue
    fi

    ###########################################################################
    # NID
    ###########################################################################

    echo
    echo "============================================================"
    echo "Running DBNEWID"
    echo "============================================================"
    echo
    echo "ORACLE_SID:"
    echo "  $ORACLE_SID"
    echo
    echo "OLD DB_NAME:"
    echo "  $OLD_CDB"
    echo
    echo "NEW DB_NAME:"
    echo "  $NEW_CDB"
    echo
    echo "Command:"
    echo
    echo "  nid TARGET=/ DBNAME=$NEW_CDB SETNAME=YES"
    echo
    echo "NID LOG:"
    echo "  $NID_LOG"
    echo
    echo "============================================================"
    echo

    run_nid "$NEW_CDB" "$NID_LOG"

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
        echo "Return code:"
        echo "  $NID_RC"
        echo
        echo "NID log:"
        echo "  $NID_LOG"
        echo
        echo "DO NOT automatically rerun NID."
        echo

        continue
    fi

    log_ok "DBNEWID completed successfully."

    ###########################################################################
    # NID SETNAME=YES SHOULD STOP INSTANCE
    ###########################################################################

    echo
    echo "Waiting for NID to stop old instance..."

    if ! wait_for_pmon_stop "$OLD_CDB" 120; then

        log_error "Old PMON still exists after NID."

        echo "  ora_pmon_${OLD_CDB}"

        continue
    fi

    log_ok "Old instance stopped after NID."

    ###########################################################################
    # IMPORTANT
    #
    # NID changed the database name in the control files.
    #
    # The initialization parameter may still contain OLD_CDB.
    #
    # DO NOT sed-edit a PFILE.
    #
    # We first attempt startup using OLD SID.
    #
    # If Oracle reports:
    #
    #   ORA-01103: control file database name 'NEW'
    #   does not match parameter file DB_NAME 'OLD'
    #
    # we then use:
    #
    #   ALTER SYSTEM SET DB_NAME=NEW SCOPE=SPFILE;
    #
    # followed by:
    #
    #   STARTUP FORCE;
    ###########################################################################

    export ORACLE_SID="$OLD_CDB"

    echo
    echo "============================================================"
    echo "Starting renamed database using OLD SID"
    echo "============================================================"
    echo
    echo "ORACLE_SID:"
    echo "  $ORACLE_SID"
    echo

    START_OUTPUT=$(
        startup_normal 2>&1
    )

    START_RC=$?

    echo "$START_OUTPUT"

    ###########################################################################
    # STARTUP SUCCESS
    ###########################################################################

    if [[ $START_RC -eq 0 ]]; then

        log_ok "Database started."

    else

        #######################################################################
        # Check specifically for ORA-01103
        #######################################################################

        if echo "$START_OUTPUT" | grep -q "ORA-01103"; then

            echo
            log_warn "ORA-01103 detected."
            echo
            echo "The control file now contains:"
            echo "  DB_NAME = $NEW_CDB"
            echo
            echo "but the SPFILE still contains:"
            echo "  DB_NAME = $OLD_CDB"
            echo
            echo "Updating DB_NAME in SPFILE using Oracle..."
            echo

            if ! set_db_name_spfile "$NEW_CDB"; then

                log_error "ALTER SYSTEM SET DB_NAME failed."

                echo
                echo "Database is currently unavailable."
                echo
                echo "SPFILE backup:"
                echo "  $SPFILE_BACKUP"
                echo
                echo "NID log:"
                echo "  $NID_LOG"
                echo

                continue
            fi

            log_ok "DB_NAME parameter updated in SPFILE."

            ###################################################################
            # STARTUP FORCE
            ###################################################################

            echo
            echo "============================================================"
            echo "Starting database with STARTUP FORCE"
            echo "============================================================"
            echo

            if ! startup_force; then

                log_error "STARTUP FORCE failed."

                echo
                echo "Do not rerun NID."
                echo
                echo "SPFILE backup:"
                echo "  $SPFILE_BACKUP"
                echo
                echo "NID log:"
                echo "  $NID_LOG"
                echo

                continue
            fi

            log_ok "Database started successfully."

        else

            ###################################################################
            # Other startup failure
            ###################################################################

            echo
            log_error "Database startup failed for a reason other than ORA-01103."
            echo
            echo "$START_OUTPUT"
            echo
            echo "Do not automatically continue."
            echo

            continue
        fi
    fi

    ###########################################################################
    # DATABASE SHOULD NOW BE RUNNING UNDER OLD SID
    ###########################################################################

    if ! wait_for_pmon "$OLD_CDB" 120; then

        log_error "Old PMON did not appear after startup."

        continue
    fi

    log_ok "Database is running."

    ###########################################################################
    # VERIFY NEW DB_NAME BEFORE SID CHANGE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Verifying DB_NAME after NID"
    echo "============================================================"
    echo

    AFTER_NID_INFO=$(get_database_info 2>&1)
    AFTER_NID_RC=$?

    if [[ $AFTER_NID_RC -ne 0 ]]; then

        log_error "Unable to query V\$DATABASE after NID."

        echo "$AFTER_NID_INFO"

        continue
    fi

    IFS='|' read -r \
        AFTER_NAME \
        AFTER_DBID \
        AFTER_CDB \
        AFTER_MODE \
        AFTER_DB_UNIQUE <<< "$AFTER_NID_INFO"

    AFTER_NAME=$(echo "$AFTER_NAME" | xargs)
    AFTER_DBID=$(echo "$AFTER_DBID" | xargs)
    AFTER_CDB=$(echo "$AFTER_CDB" | xargs)
    AFTER_MODE=$(echo "$AFTER_MODE" | xargs)
    AFTER_DB_UNIQUE=$(echo "$AFTER_DB_UNIQUE" | xargs)

    echo "DB_NAME        : $AFTER_NAME"
    echo "DBID           : $AFTER_DBID"
    echo "CDB            : $AFTER_CDB"
    echo "OPEN_MODE      : $AFTER_MODE"
    echo "DB_UNIQUE_NAME : $AFTER_DB_UNIQUE"
    echo

    if [[ "$AFTER_NAME" != "$NEW_CDB" ]]; then

        log_error "DB_NAME is not $NEW_CDB."

        continue
    fi

    if [[ "$AFTER_DBID" != "$CURRENT_DBID" ]]; then

        log_error "DBID changed!"

        echo "Original:"
        echo "  $CURRENT_DBID"

        echo "Current:"
        echo "  $AFTER_DBID"

        continue
    fi

    log_ok "DB_NAME is now $NEW_CDB."
    log_ok "DBID remains unchanged."

    ###########################################################################
    # NOW CHANGE SID
    #
    # Oracle SID is not stored in the database control file.
    #
    # It is the environment/instance identity.
    #
    # To make PMON become:
    #
    #   ora_pmon_NEW
    #
    # we shut down the old instance and start the database with:
    #
    #   ORACLE_SID=NEW
    #
    ###########################################################################

    echo
    echo "============================================================"
    echo "Changing Oracle SID"
    echo "============================================================"
    echo
    echo "OLD SID:"
    echo "  $OLD_CDB"
    echo
    echo "NEW SID:"
    echo "  $NEW_CDB"
    echo

    ###########################################################################
    # Shutdown OLD SID
    ###########################################################################

    if ! shutdown_database; then

        log_error "Shutdown before SID change failed."

        continue
    fi

    if ! wait_for_pmon_stop "$OLD_CDB" 120; then

        log_error "Old PMON did not stop."

        echo "  ora_pmon_${OLD_CDB}"

        continue
    fi

    log_ok "Old SID instance stopped."

    ###########################################################################
    # CHANGE ORACLE_SID
    ###########################################################################

    export ORACLE_SID="$NEW_CDB"

    echo
    echo "New ORACLE_SID:"
    echo "  $ORACLE_SID"
    echo

    ###########################################################################
    # TARGET PMON MUST NOT EXIST
    ###########################################################################

    if pmon_exists "$NEW_CDB"; then

        log_error "New PMON already exists."

        echo "  ora_pmon_${NEW_CDB}"

        continue
    fi

    ###########################################################################
    # START NEW SID
    ###########################################################################

    echo
    echo "============================================================"
    echo "Starting database under NEW SID"
    echo "============================================================"
    echo
    echo "ORACLE_SID:"
    echo "  $ORACLE_SID"
    echo

    if ! startup_normal; then

        log_error "Startup under NEW ORACLE_SID failed."

        echo
        echo "Current ORACLE_SID:"
        echo "  $ORACLE_SID"
        echo
        echo "Previous SID:"
        echo "  $OLD_CDB"
        echo
        echo "The database is currently stopped."
        echo
        echo "Try manually:"
        echo
        echo "  export ORACLE_SID=$NEW_CDB"
        echo "  export ORACLE_HOME=$ORACLE_HOME"
        echo "  sqlplus / as sysdba"
        echo "  startup;"
        echo

        continue
    fi

    ###########################################################################
    # WAIT FOR NEW PMON
    ###########################################################################

    echo
    echo "Waiting for new PMON..."

    if ! wait_for_pmon "$NEW_CDB" 120; then

        log_error "New PMON did not appear."

        echo "Expected:"
        echo "  ora_pmon_${NEW_CDB}"

        continue
    fi

    log_ok "New PMON is running:"
    echo "  ora_pmon_${NEW_CDB}"

    ###########################################################################
    # VERIFY SYSDBA UNDER NEW SID
    ###########################################################################

    echo
    echo "============================================================"
    echo "Checking SYSDBA connectivity under NEW SID"
    echo "============================================================"
    echo

    NEW_CONNECT=$(test_sysdba 2>&1)
    NEW_CONNECT_RC=$?

    if [[ $NEW_CONNECT_RC -ne 0 ]]; then

        log_error "SYSDBA connectivity failed under NEW SID."

        echo "$NEW_CONNECT"

        continue
    fi

    log_ok "SYSDBA connectivity confirmed under NEW SID."

    ###########################################################################
    # FINAL VERIFICATION
    ###########################################################################

    if final_verification \
        "$OLD_CDB" \
        "$NEW_CDB" \
        "$CURRENT_DBID" \
        "$CURRENT_DB_UNIQUE"
    then

        echo
        echo "############################################################"
        echo "SUCCESS"
        echo "############################################################"
        echo
        echo "OLD DB_NAME       : $OLD_CDB"
        echo "NEW DB_NAME       : $NEW_CDB"
        echo
        echo "OLD ORACLE_SID    : $OLD_CDB"
        echo "NEW ORACLE_SID    : $NEW_CDB"
        echo
        echo "OLD PMON          : ora_pmon_${OLD_CDB}"
        echo "NEW PMON          : ora_pmon_${NEW_CDB}"
        echo
        echo "DBID              : $CURRENT_DBID"
        echo "DBID CHECK        : UNCHANGED"
        echo
        echo "DB_UNIQUE_NAME    : $CURRENT_DB_UNIQUE"
        echo "DB_UNIQUE CHECK   : UNCHANGED"
        echo
        echo "CDB               : YES"
        echo "OPEN_MODE         : READ WRITE"
        echo
        echo "RESETLOGS         : NOT USED"
        echo
        echo "SPFILE BACKUP:"
        echo "  $SPFILE_BACKUP"
        echo
        echo "NID LOG:"
        echo "  $NID_LOG"
        echo
        echo "############################################################"

    else

        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_error "FINAL VERIFICATION FAILED"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo
        echo "Do not proceed with dependent work."
        echo
        echo "Master log:"
        echo "  $MASTER_LOG"
        echo
        echo "NID log:"
        echo "  $NID_LOG"
        echo
        echo "SPFILE backup:"
        echo "  $SPFILE_BACKUP"
        echo

        continue
    fi

    ###########################################################################
    # PER DATABASE COMPLETE
    ###########################################################################

    echo
    echo "============================================================"
    echo "Completed database"
    echo "============================================================"
    echo
    echo "$OLD_CDB -> $NEW_CDB"
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
echo "SPFILE/PFILE backups:"
echo "  $BACKUP_DIR"
echo
echo "============================================================"
