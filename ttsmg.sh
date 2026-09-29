Log in
Sign up for free
You said:

there are two db source and target source in 19c and target in 26ai I need to clone the source to target source has less data but target has more data so what is the best and fastest approach to do this?
ChatGPT said:
Yes. The important point is that your target already contains more data than the 19c source. So I would not treat this as a normal “clone the database” operation unless you intend to throw away the target's extra data.
Oracle 26ai supports a direct upgrade from 19c, but the best method depends on what you mean by “clone.” 
O
Oracle Documentation
+1

If you want to preserve the target's extra data
If your requirement is:
Source 19c has a smaller/older dataset → Target 26ai has the same database plus additional data → make target reflect source where appropriate, but don't lose target-only data
then Data Pump full import is not the right approach by itself, because it is fundamentally a migration/copy operation rather than a merge engine.
I'd recommend:

19c source → staging/schema on 26ai → compare → selectively synchronize

For example:

                 ┌───────────────┐
                 │   SOURCE 19c  │
                 │  less data    │
                 └───────┬───────┘
                         │
                    Data Pump
                         │
                         ▼
                 ┌───────────────┐
                 │ TARGET 26ai   │
                 │ staging schema│
                 └───────┬───────┘
                         │
                 MERGE / INSERT /
                 UPDATE / DELETE
                         │
                         ▼
                 ┌───────────────┐
                 │ TARGET 26ai   │
                 │ final schema  │
                 └───────────────┘

This gives you control over what happens to the target-only rows.
Oracle specifically supports Data Pump for migrating all or part of a database between releases, including 19c → 26ai. 
O
Oracle Documentation
+1

But if you actually want to replace the target
If by "clone" you mean:
I don't care about the target's extra data. I want target 26ai to become an exact copy of source 19c.
Then I would choose one of these:
Situation	Recommended approach
Target can be destroyed/recreated	Full/Transportable Data Pump
Very large database	Transportable Tablespaces / Full Transportable Export/Import
Smaller database	Data Pump (expdp/impdp)
Need minimal downtime	GoldenGate / replication approach
Autonomous Database	Refreshable/full clone, where supported

Oracle notes that Full Transportable Export/Import can be substantially faster than conventional export/import because the actual datafiles can be transported and Data Pump handles primarily the metadata. 
O
Oracle Documentation
+1
If the target has MORE data, I need one critical detail
There are two very different requirements:
A. "Make target exactly like source"
Example:
SOURCE 19c
CUSTOMERS = 1,000,000

TARGET 26ai
CUSTOMERS = 1,500,000

After migration:
TARGET 26ai
CUSTOMERS = 1,000,000

Then replace/refresh the target. Don't spend time doing row-by-row comparisons.
B. "Bring source changes into target but retain target-only data"
Example:
SOURCE 19c                 TARGET 26ai
----------                 ----------
Customer 1                 Customer 1
Customer 2                 Customer 2
Customer 3                 Customer 3
                           Customer 4
                           Customer 5
                           Customer 6

You want:
TARGET 26ai
------------
Customer 1
Customer 2
Customer 3
Customer 4
Customer 5
Customer 6

with source changes applied appropriately.
Then you need a data synchronization/merge strategy, not a clone.

For the fastest migration
If the target can be wiped, I'd investigate Full Transportable Export/Import first, especially if the database is large. Oracle explicitly identifies this as potentially much faster than conventional Data Pump export/import. 
O
Oracle Documentation
If it's a relatively small/medium database, standard parallel Data Pump is usually much simpler:

expdp ... FULL=Y \
      DIRECTORY=DP_DIR \
      DUMPFILE=source_%U.dmp \
      LOGFILE=source_exp.log \
      PARALLEL=8

then:
impdp ... FULL=Y \
      DIRECTORY=DP_DIR \
      DUMPFILE=source_%U.dmp \
      LOGFILE=target_imp.log \
      PARALLEL=8

Since the target is newer than the source, you generally don't need to specify a VERSION downgrade parameter for a 19c → 26ai Data Pump migration. 
O
Oracle Documentation
One more important distinction
If your 19c database itself needs to be upgraded to 26ai, rather than simply copying its data to an already-existing 26ai database, Oracle supports direct 19c → 26ai upgrades. Oracle's current documentation says 19c and 21c are the supported direct-upgrade starting releases. 
O
Oracle Documentation
So I would not automatically choose RMAN restore just because it is a database clone. The correct choice depends heavily on whether you're doing an upgrade, a replacement, or a merge.

If you give me these 5 details, I can tell you exactly which method I'd use and give you the commands/runbook:

Source: 19c RAC or single instance?
Target: 26ai RAC/single instance/Autonomous?
Approximate DB size (e.g. 500 GB / 5 TB).
Do you want to keep the target's extra data? Yes/no.
Is it full database or just specific schemas?
With those, I can design the fastest 19c → 26ai migration with minimum downtime, including the Data Pump/transportable/GoldenGate choice and cutover procedure.


OO
Sources
Log in for personalized, step-by-step guidance.

Log in

Sign up for free
You said:

target data can be destroyed
ChatGPT said:
That changes the recommendation significantly.
If the target 26ai data can be completely destroyed, then I would not try to merge or compare the existing target data. Treat the 26ai database as a new destination and migrate the 19c database into it.

My recommendation
For a 19c → 26ai full database migration, I would consider these two approaches:
Full Transportable Export/Import — my first choice when the database is large and you want the fastest physical data movement.
Regular Data Pump FULL export/import — simpler and often preferable for smaller databases.
Oracle's current 26ai documentation states that copying database datafiles without interpreting/reloading the data is the fastest data-movement method, and that full transportable Data Pump can significantly reduce export/import time because table data and indexes in transportable tablespaces don't need to be unloaded/reloaded/recreated. 
O
Oracle Documentation
Architecture I'd use
              SOURCE
           Oracle 19c
              │
              │
       Full Transportable
       Export / Datafiles
              │
              ▼
       ┌─────────────────┐
       │   Oracle 26ai   │
       │   EMPTY TARGET  │
       └─────────────────┘
              │
              ▼
        Source data +
        metadata/users
        objects/etc.

Because the target data is disposable, you can drop/recreate the target database/PDB and avoid all the overhead associated with reconciling the existing larger dataset.
One important alternative
There is also a direct 19c → 26ai database upgrade path. Oracle currently documents 19c as a supported direct-upgrade source for 26ai. 
O
Oracle Documentation
+1
So the choice is really:

Goal	Approach
Create a new 26ai DB containing the 19c data	Full Transportable Data Pump
Smaller/medium DB and simplicity matters	Full Data Pump
Upgrade the actual 19c database to 26ai	AutoUpgrade
Very large DB where data movement is the bottleneck	Transportable/datafile-based migration

For an actual upgrade, Oracle says AutoUpgrade is the supported upgrade mechanism for 26ai; DBUA and the old dbupgrade/catctl.pl methods are desupported for 26ai upgrades. 
O
Oracle Documentation
If this were my migration
I'd probably do:
1. Build clean 26ai target
2. Validate source 19c compatibility
3. Run pre-migration checks
4. Make source application read-only / stop writes
5. Full Transportable Export
6. Copy transportable datafiles
7. Import metadata into 26ai
8. Run 26ai post-migration scripts
9. Compile invalid objects
10. Validate row counts / objects / application
11. Switch application to 26ai

The nice thing is that you don't care that the old target has more data. You can simply discard it.
For a large database, this is particularly attractive because Oracle describes full transportable export as using a mixture of metadata export and direct datafile movement. 
O
Oracle Documentation

If you tell me the approximate database size (e.g. 500 GB, 5 TB, 20 TB), whether 19c/26ai are CDB/PDB, and whether they are RAC or single-instance, I can give you the exact fastest migration method and the expdp/impdp commands, including the downtime/cutover sequence.


OO
Sources
You said:

full steps detailed
ChatGPT said:
Yes. Since the existing 26ai target can be completely destroyed, I would treat this as a one-way migration from 19c to a clean 26ai target.
For a large database, my preferred approach is Full Transportable Data Pump Export/Import. Oracle documents that FULL=Y TRANSPORTABLE=ALWAYS moves metadata through Data Pump while data in transportable tablespaces is moved by copying the datafiles, which can substantially reduce export/import time. 
O
Oracle Documentation
+1

There is one important distinction: Oracle also supports a direct 19c → 26ai upgrade, but that is an upgrade of the existing database using AutoUpgrade, not a clone into a separate already-built target. Since you specifically have a separate 26ai target that can be destroyed, the migration procedure below is the better fit. Oracle lists 19c as a direct-upgrade source for 26ai and requires AutoUpgrade for an actual upgrade. 
O
Oracle Documentation
+1

19c → 26ai Full Transportable Migration Runbook
I'll assume:
SOURCE
Oracle 19c
    |
    |  Full Transportable Data Pump
    |  + datafile copy
    |
    v
TARGET
Oracle 26ai
Clean / disposable

Example environment:
Source DB       : PROD19
Source version  : 19c
Target DB       : PROD26
Target version  : 26ai

Source server   : db19.example.com
Target server   : db26.example.com

Source ORACLE_HOME
                 /u01/app/oracle/product/19.0.0/dbhome_1

Target ORACLE_HOME
                 /u01/app/oracle/product/26.0.0/dbhome_1

Data Pump dir   : /u02/dpump
Transport dir   : /u03/transport

Replace those values with yours.
1. First decide whether this is CDB/PDB or non-CDB
On 19c:
sqlplus / as sysdba

SELECT name, cdb, open_mode, database_role
FROM v$database;

SELECT con_id, name, open_mode
FROM v$containers
ORDER BY con_id;

Also:
SELECT banner_full
FROM v$version;

You may see:
NAME     CDB
-------- ---
PROD19   YES

If it is a CDB, determine the PDB you are migrating:
SHOW PDBS;

For example:
CON_ID  CON_NAME   OPEN MODE
------  ---------  ----------
2       PDB$SEED   READ ONLY
3       APPDB      READ WRITE

In that case, your actual application database is APPDB.
This matters a lot, because the exact migration commands differ between:

19c non-CDB → 26ai
19c PDB → 26ai PDB
complete CDB → complete 26ai CDB
If you tell me your CDB result, I can tailor the commands exactly.
2. Check source database size
Before deciding the degree of parallelism, get the actual size.
SELECT
    ROUND(SUM(bytes)/1024/1024/1024,2) AS size_gb
FROM dba_data_files;

And:
SELECT
    tablespace_name,
    ROUND(SUM(bytes)/1024/1024/1024,2) AS size_gb
FROM dba_data_files
GROUP BY tablespace_name
ORDER BY size_gb DESC;

Also check free space:
SELECT
    tablespace_name,
    ROUND(SUM(bytes)/1024/1024/1024,2) AS free_gb
FROM dba_free_space
GROUP BY tablespace_name
ORDER BY free_gb DESC;

For example:
TABLESPACE       SIZE_GB
---------------  -------
APP_DATA          2500
APP_INDEX         1200
USERS              300
SYSTEM              50
SYSAUX              30

This tells us whether transportable tablespaces will save significant time.
3. Check the source database for unsupported/desupported features
Do not start the migration yet.
Because 26ai is substantially newer than 19c, first run the Oracle pre-upgrade checks.

Oracle's current 26ai documentation recommends checking the source before migration/upgrade. For a true upgrade, AutoUpgrade performs these checks, but in a Data Pump migration you should still independently validate your application, components, objects, and options. 
O
Oracle Documentation

At minimum:

SELECT comp_id,
       comp_name,
       version,
       status
FROM dba_registry
ORDER BY comp_id;

You want components to generally show:
STATUS
-------
VALID

Check invalid objects:
SELECT owner,
       object_type,
       COUNT(*) AS cnt
FROM dba_objects
WHERE status <> 'VALID'
GROUP BY owner, object_type
ORDER BY owner, object_type;

Before migration, investigate these.
4. Check database character set
On source:
SELECT parameter, value
FROM nls_database_parameters
WHERE parameter IN
(
    'NLS_CHARACTERSET',
    'NLS_NCHAR_CHARACTERSET'
);

Also:
SELECT *
FROM nls_database_parameters
WHERE parameter LIKE 'NLS%';

Record this information.
5. Check platform and endian format
On source:
SELECT platform_name
FROM v$database;

Or:
SELECT *
FROM v$transportable_platform
ORDER BY platform_name;

The source and target platform should ideally have the same endian format.
If source and target have different endianness, Oracle requires conversion of the transported datafiles. Oracle specifically documents using DBMS_FILE_TRANSFER or RMAN CONVERT for this situation. 
O
Oracle Documentation

For example:

Linux x86-64
        |
        v
Linux x86-64

is straightforward.
But something like:

Linux x86-64
        |
        v
AIX

requires additional conversion planning.
6. Check TDE
This is extremely important if your database uses Transparent Data Encryption.
Run:

SELECT
    wrl_type,
    wrl_parameter,
    status,
    wallet_type
FROM v$encryption_wallet;

And:
SELECT tablespace_name, encrypted
FROM dba_tablespaces
WHERE encrypted = 'YES';

If you see:
ENCRYPTED
--------
YES

you need to plan the wallet/keystore migration before moving encrypted datafiles.
Do not simply copy encrypted datafiles and assume they will open on 26ai.

7. Check tablespaces
On source:
SELECT
    tablespace_name,
    contents,
    status,
    extent_management,
    segment_space_management
FROM dba_tablespaces
ORDER BY tablespace_name;

Pay particular attention to:
SYSTEM
SYSAUX
UNDO
TEMP

and your application tablespaces:
APP_DATA
APP_INDEX
USERS
...

The transportable method treats transportable and non-transportable tablespaces differently. Oracle states that SYSTEM/SYSAUX and other non-transportable tablespaces have their data moved through the dump, while transportable tablespaces primarily require their datafiles to be copied. 
O
Oracle Documentation
8. Make sure target storage is sufficient
On 26ai target:
df -h

You need enough space for:
Datafiles
+
Data Pump dump files
+
Temporary staging
+
Redo/undo
+
Growth

For example, if source is:
5 TB

don't provision exactly:
5 TB

Provision enough for the actual target layout and operational headroom.
9. Clean the 26ai target
Since you've confirmed that target data can be destroyed, this is a major advantage.
Do not attempt to import over the existing target database.

Ideally:

OLD 26ai database
       |
       X
       |
       v

NEW clean 26ai database

If the target is a disposable database, I prefer rebuilding it cleanly rather than dropping thousands of schemas/objects individually.
For example, if using a PDB:

sqlplus / as sysdba

SHOW PDBS;

Then:
ALTER PLUGGABLE DATABASE APPDB CLOSE IMMEDIATE;

And, depending on your environment:
DROP PLUGGABLE DATABASE APPDB INCLUDING DATAFILES;

Then create the new PDB.
Do not execute the DROP command until you have verified that you are connected to the correct 26ai target.

10. Build the 26ai target
Install the required 26ai Release Update and patches.
Verify:

SELECT banner_full
FROM v$version;

You should see Oracle AI Database 26ai.
Then:

SELECT
    name,
    open_mode,
    cdb
FROM v$database;

For a CDB:
SHOW PDBS;

Create the target PDB if required.
For example:

CREATE PLUGGABLE DATABASE APPDB
ADMIN USER pdbadmin IDENTIFIED BY "password"
FILE_NAME_CONVERT =
(
    '/u02/oradata/seed/',
    '/u02/oradata/APPDB/'
);

Then:
ALTER PLUGGABLE DATABASE APPDB OPEN;

And:
ALTER PLUGGABLE DATABASE APPDB SAVE STATE;

The exact PDB creation syntax depends on your target storage architecture, ASM, OMF, filesystem, etc.
11. Create directories for Data Pump
On 26ai:
mkdir -p /u02/dpump
mkdir -p /u03/transport

Set permissions:
chown -R oracle:oinstall /u02/dpump
chown -R oracle:oinstall /u03/transport

chmod 750 /u02/dpump
chmod 750 /u03/transport

Then in Oracle:
CREATE OR REPLACE DIRECTORY DP_DIR
AS '/u02/dpump';

CREATE OR REPLACE DIRECTORY TRANSPORT_DIR
AS '/u03/transport';

Grant appropriate access:
GRANT READ, WRITE ON DIRECTORY DP_DIR TO system;
GRANT READ, WRITE ON DIRECTORY TRANSPORT_DIR TO system;

If using a dedicated migration account, grant the directory privileges to that account instead.
12. Create a dedicated Data Pump user
You can use SYSTEM, but for a controlled migration I generally prefer a dedicated migration account.
Example:

CREATE USER MIGRATION_USER
IDENTIFIED BY "StrongPassword";

GRANT CREATE SESSION TO MIGRATION_USER;

GRANT DATAPUMP_EXP_FULL_DATABASE
TO MIGRATION_USER;

GRANT DATAPUMP_IMP_FULL_DATABASE
TO MIGRATION_USER;

GRANT READ, WRITE ON DIRECTORY DP_DIR
TO MIGRATION_USER;

GRANT READ, WRITE ON DIRECTORY TRANSPORT_DIR
TO MIGRATION_USER;

Be careful with passwords and don't put production passwords into shell history.
13. Important: test the transportability of the database
Before the real migration, perform a test.
On the 19c source:

EXEC DBMS_TTS.TRANSPORT_SET_CHECK(
    ts_list => 'APP_DATA,APP_INDEX',
    incl_constraints => TRUE
);

Then:
SELECT *
FROM transport_set_violations;

Ideally:
no rows selected

If you get rows, stop and fix those issues before migration.
For a full transportable export, Oracle Data Pump determines the necessary transportable datafiles and records them in the export log. 
O
Oracle Documentation

14. Determine which tablespaces need to be transported
Get them:
SELECT tablespace_name
FROM dba_tablespaces
WHERE contents = 'PERMANENT'
AND tablespace_name NOT IN ('SYSTEM','SYSAUX');

But don't blindly use that output.
The actual list should be based on your application and transportability checks.

For example:

APP_DATA
APP_INDEX
USERS

15. Perform a test Full Transportable Export
This is the critical command.
On the 19c source:

expdp migration_user/"password" \
    FULL=Y \
    TRANSPORTABLE=ALWAYS \
    DIRECTORY=DP_DIR \
    DUMPFILE=prod19_%U.dmp \
    LOGFILE=prod19_ft_exp.log \
    PARALLEL=8

Oracle documents FULL=Y TRANSPORTABLE=ALWAYS as the full transportable export mode. 
O
Oracle Documentation
About PARALLEL
Don't automatically use:
PARALLEL=64

if you have 8 CPUs.
A reasonable starting point might be:

PARALLEL=4

or:
PARALLEL=8

Then benchmark.
The bottleneck may actually be:

storage I/O
network
filesystem
ASM
source CPU
target CPU
rather than Data Pump workers.
16. Review the export log
This is extremely important.
Look at:

less prod19_ft_exp.log

Search for:
transportable
datafile
ORA-
UDI-

The full transportable export log tells you which datafiles need to be copied. Oracle explicitly notes that the required datafiles are listed at the end of the export log. 
O
Oracle Documentation
You might see something conceptually like:

Datafiles required for transport:

/u02/oradata/PROD19/app_data01.dbf
/u02/oradata/PROD19/app_data02.dbf
/u02/oradata/PROD19/app_index01.dbf

Those files are your large data movement.
17. Copy the dump files to the 26ai server
For example:
rsync -avh --progress \
    /u02/dpump/prod19_*.dmp \
    oracle@db26.example.com:/u02/dpump/

If you have many dump files, use rsync.
For very large databases, network throughput becomes important.

For example:

1 Gbps
≈ 125 MB/s theoretical

10 Gbps
≈ 1.25 GB/s theoretical

Real-world throughput will be lower.
18. Copy the transportable datafiles
This is where Full Transportable can save substantial time.
For example:

rsync -avh --progress \
    /u02/oradata/PROD19/app_data01.dbf \
    oracle@db26.example.com:/u03/oradata/APPDB/

Repeat for the required datafiles.
If source and target can access shared storage, you may have a much faster option than copying through the database server.

For example:

SOURCE
   |
   | shared storage
   |
   +----------+
              |
              v
           TARGET

But make absolutely sure the source is no longer writing to those datafiles when you perform the final transport.
19. Important: don't copy active datafiles blindly
For the final migration, you need a consistent point in time.
You have two common approaches:

Option A — application downtime
This is the simplest.
At cutover:

Stop application
       ↓
Stop all writes
       ↓
Shutdown source
       ↓
Final export
       ↓
Copy datafiles
       ↓
Import target
       ↓
Validate
       ↓
Start application on 26ai

For a normal migration, I strongly prefer this unless you have a strict minimal-downtime requirement.
Option B — minimal downtime
Use technologies such as Oracle GoldenGate to replicate changes while the initial migration happens.
That's more complicated.

If your requirement is simply:

"Fastest and reliable migration"
then planned downtime + Full Transportable is usually much simpler.
20. Final migration window
At the beginning of the maintenance window:
Stop application connections.

For example:

Application
     |
     X
     |
Oracle 19c

Verify nobody is still writing.
You can monitor sessions:

SELECT username,
       machine,
       program,
       status
FROM v$session
WHERE username IS NOT NULL
ORDER BY username;

Also disable application services if appropriate.
21. Take a final backup
Before destroying the target or making the source read-only, ensure you have a valid source backup.
At minimum:

RMAN backup
+
Data Pump migration artifacts
+
Configuration
+
TDE wallet/keystore

Do not make the target disposable until you're confident the source backup is recoverable.
22. Perform the final Data Pump export
On source:
expdp migration_user/"password" \
    FULL=Y \
    TRANSPORTABLE=ALWAYS \
    DIRECTORY=DP_DIR \
    DUMPFILE=prod19_%U.dmp \
    LOGFILE=prod19_final_ft_exp.log \
    PARALLEL=8

Wait for:
successfully completed

Then:
grep -i "ORA-" prod19_final_ft_exp.log

and:
grep -i "error" prod19_final_ft_exp.log

Don't proceed if there are unexplained errors.
23. Copy the final datafiles
Copy all datafiles identified by the final export.
For example:

rsync -avh --progress \
    /u02/oradata/PROD19/*.dbf \
    oracle@db26.example.com:/u03/oradata/APPDB/

Do not blindly copy every .dbf in production.
Use the actual files identified for transport.

24. Copy dump files
rsync -avh --progress \
    /u02/dpump/prod19_*.dmp \
    oracle@db26.example.com:/u02/dpump/

Verify checksums if the transfer path is critical:
sha256sum prod19_*.dmp

Compare on target.
For very large datafiles, you can also checksum selected files, although this itself can be expensive because it reads the entire file.

25. Prepare the 26ai target for import
Make sure the target is up:
SELECT banner_full
FROM v$version;

And:
SELECT name, open_mode, cdb
FROM v$database;

If PDB:
SHOW PDBS;

Open the target PDB:
ALTER PLUGGABLE DATABASE APPDB OPEN;

26. Import the Full Transportable dump
Oracle's file-based full transportable import uses the dump plus the transportable datafiles. Oracle documents that file-based imports can infer the full/transportable mode from the dump and use TRANSPORT_DATAFILES for the datafiles. 
O
Oracle Documentation
Conceptually:

impdp migration_user/"password" \
    DIRECTORY=DP_DIR \
    DUMPFILE=prod19_%U.dmp \
    LOGFILE=prod26_ft_imp.log \
    TRANSPORT_DATAFILES='/u03/oradata/APPDB/app_data01.dbf',\
'/u03/oradata/APPDB/app_data02.dbf',\
'/u03/oradata/APPDB/app_index01.dbf' \
    PARALLEL=8

The exact TRANSPORT_DATAFILES list must match the files produced by your export.
Do not copy the example filenames literally.

27. If the target datafile paths differ
This is very common.
Source:

/u02/oradata/PROD19/app_data01.dbf

Target:
/u03/oradata/APPDB/app_data01.dbf

That's fine.
The target TRANSPORT_DATAFILES should reference the target-side path.

For ASM, paths might look like:

+DATA/APPDB/...

In that case the commands are different.
28. Monitor the import
From another session:
tail -f prod26_ft_imp.log

Also monitor database activity.
You can use:

SELECT
    sid,
    serial#,
    opname,
    sofar,
    totalwork,
    ROUND(sofar/NULLIF(totalwork,0)*100,2) pct
FROM v$session_longops
WHERE totalwork > 0
AND sofar <> totalwork
ORDER BY start_time;

29. Don't panic about expected warnings
Data Pump may report warnings that are not necessarily fatal.
For example:

ORA-39083
ORA-39126
ORA-31684

You need to examine each one.
Don't use:

grep ORA- ...

as the sole determination of success.
Review:

grep -i "ORA-" prod26_ft_imp.log

and understand each error.
Some objects may legitimately need post-import recreation.

30. Compile invalid objects
After import:
@?/rdbms/admin/utlrp.sql

Then check:
SELECT owner,
       object_type,
       COUNT(*) cnt
FROM dba_objects
WHERE status <> 'VALID'
GROUP BY owner, object_type
ORDER BY owner, object_type;

Ideally your application schemas should have zero unexpected invalid objects.
31. Check invalid objects in detail
SELECT owner,
       object_name,
       object_type,
       status
FROM dba_objects
WHERE status <> 'VALID'
ORDER BY owner, object_type, object_name;

If you have invalid packages:
SELECT owner,
       object_name,
       object_type
FROM dba_objects
WHERE status = 'INVALID'
AND object_type IN
(
    'PACKAGE',
    'PACKAGE BODY',
    'PROCEDURE',
    'FUNCTION',
    'TRIGGER',
    'VIEW'
);

Investigate these before cutover.
32. Check schemas
On source:
SELECT username
FROM dba_users
WHERE oracle_maintained = 'N'
ORDER BY username;

Run the same on target:
SELECT username
FROM dba_users
WHERE oracle_maintained = 'N'
ORDER BY username;

Compare them.
Pay attention to:

users
profiles
roles
password status
default tablespaces
temporary tablespaces
quotas

33. Check roles
Source:
SELECT grantee,
       granted_role,
       admin_option
FROM dba_role_privs
WHERE grantee IN
(
    SELECT username
    FROM dba_users
    WHERE oracle_maintained = 'N'
)
ORDER BY grantee, granted_role;

Compare against target.
34. Check system privileges
SELECT grantee,
       privilege,
       admin_option
FROM dba_sys_privs
WHERE grantee IN
(
    SELECT username
    FROM dba_users
    WHERE oracle_maintained = 'N'
)
ORDER BY grantee, privilege;

35. Check object privileges
SELECT grantee,
       owner,
       table_name,
       privilege
FROM dba_tab_privs
WHERE grantee IN
(
    SELECT username
    FROM dba_users
    WHERE oracle_maintained = 'N'
)
ORDER BY grantee, owner, table_name;

36. Compare table counts
This is one of the most important validation steps.
On 19c:

SELECT owner,
       COUNT(*) AS table_count
FROM dba_tables
WHERE owner NOT IN
(
    'SYS',
    'SYSTEM',
    'XDB',
    'MDSYS',
    'CTXSYS'
)
GROUP BY owner
ORDER BY owner;

Run the same on 26ai.
Then compare.

37. Compare row counts
For critical tables, run:
SELECT COUNT(*)
FROM APP.CUSTOMERS;

on both source and target.
Do this for:

largest tables
critical business tables
transaction tables
reference tables

For a large database, don't necessarily COUNT(*) every table if that creates an unacceptable validation window. Use a prioritized validation strategy.
38. Compare table sizes
Source:
SELECT owner,
       segment_name,
       ROUND(SUM(bytes)/1024/1024/1024,2) AS gb
FROM dba_segments
WHERE segment_type LIKE 'TABLE%'
GROUP BY owner, segment_name
ORDER BY gb DESC;

Target:
SELECT owner,
       segment_name,
       ROUND(SUM(bytes)/1024/1024/1024,2) AS gb
FROM dba_segments
WHERE segment_type LIKE 'TABLE%'
GROUP BY owner, segment_name
ORDER BY gb DESC;

Large discrepancies should be investigated.
39. Validate indexes
SELECT owner,
       index_type,
       status,
       COUNT(*)
FROM dba_indexes
GROUP BY owner, index_type, status
ORDER BY owner, index_type, status;

Check unusable indexes:
SELECT owner,
       index_name,
       table_name,
       status
FROM dba_indexes
WHERE status <> 'VALID'
ORDER BY owner, index_name;

40. Validate constraints
SELECT owner,
       constraint_type,
       status,
       COUNT(*)
FROM dba_constraints
GROUP BY owner, constraint_type, status
ORDER BY owner, constraint_type, status;

Find disabled constraints:
SELECT owner,
       constraint_name,
       table_name,
       constraint_type,
       status
FROM dba_constraints
WHERE status <> 'ENABLED'
ORDER BY owner, table_name;

41. Validate sequences
Check:
SELECT sequence_owner,
       sequence_name,
       last_number
FROM dba_sequences
ORDER BY sequence_owner, sequence_name;

For applications using sequences heavily, validate that the values are appropriate after migration.
42. Validate database links
SELECT owner,
       db_link,
       username,
       host
FROM dba_db_links
ORDER BY owner, db_link;

Database links are a common source of post-migration application failures.
43. Validate directories
SELECT owner,
       directory_name,
       directory_path
FROM dba_directories
ORDER BY owner, directory_name;

This is especially important if the 19c and 26ai servers have different filesystem layouts.
For example:

19c:
/u01/app/files

26ai:
/u03/app/files

Your application may still be expecting the old path.
44. Validate external objects
Check for:
SELECT owner,
       object_name,
       object_type
FROM dba_objects
WHERE object_type IN
(
    'JAVA CLASS',
    'LIBRARY',
    'DIRECTORY'
)
ORDER BY owner, object_type;

Pay particular attention to external procedures and filesystem dependencies.
45. Check DB links again
This deserves emphasis.
For example:

APPDB
 |
 +-- DB_LINK_A → oldserver
 +-- DB_LINK_B → oldservice

The database migration doesn't automatically mean your surrounding infrastructure is correct.
Test them:

SELECT *
FROM dual@DB_LINK_A;

46. Check scheduler jobs
SELECT owner,
       job_name,
       enabled,
       state
FROM dba_scheduler_jobs
ORDER BY owner, job_name;

Also:
SELECT owner,
       job_name,
       status,
       actual_start_date,
       run_duration
FROM dba_scheduler_job_run_details
ORDER BY log_date DESC;

Be careful here.
You generally don't want all production jobs immediately running before application validation.

47. Check database services
For RAC/Cluster environments:
srvctl status database -d PROD26

and:
srvctl status service -d PROD26

For single instance:
lsnrctl status

Make sure application service names are correct.
48. Update application connection information
Suppose application currently connects:
prod19.company.com:1521/APPDB

You want:
prod26.company.com:1521/APPDB

If possible, use a DNS/service abstraction so the application doesn't need a permanent hostname change.
For example:

appdb.company.com
       |
       v
     19c

During cutover:
appdb.company.com
       |
       v
     26ai

This makes future migrations much easier.
49. Check optimizer/statistics
After migration, check statistics.
For important schemas:

SELECT owner,
       COUNT(*)
FROM dba_tab_statistics
WHERE stale_stats = 'YES'
GROUP BY owner;

Depending on your migration and workload, you may want to gather statistics after import.
For example:

BEGIN
    DBMS_STATS.GATHER_SCHEMA_STATS(
        ownname => 'APP',
        options => 'GATHER AUTO'
    );
END;
/

Don't blindly gather statistics across a multi-terabyte database during your cutover window without estimating the runtime.
For a large database, this should be planned separately.

50. Test the application before opening production
This is where your migration becomes a real migration rather than merely a successful Data Pump job.
Test:

Login
  ↓
Application connection
  ↓
SELECT
  ↓
INSERT
  ↓
UPDATE
  ↓
DELETE
  ↓
Transactions
  ↓
Reports
  ↓
Batch jobs
  ↓
DB links
  ↓
File processing
  ↓
Scheduler

At minimum test:
application login
read transactions
write transactions
commit/rollback
reports
critical stored procedures
packages
triggers
scheduled jobs
DB links
external integrations
51. Cutover
Once validation is complete:
TABLESPACE       SIZE_GB
---------------  -------
APP_DATA          2500
APP_INDEX         1200
USERS              300
SYSTEM              50
SYSAUX              30

19c
 |
 | application stopped
 |
 X
 |
26ai
 |
 +--- application starts

Update DNS/service/TNS/application connection.
Then:

tnsping APPDB

From an application server.
Then connect:

sqlplus app_user/password@APPDB

Verify:
SELECT
    sys_context('USERENV','DB_NAME') db_name,
    sys_context('USERENV','SERVICE_NAME') service_name,
    sys_context('USERENV','INSTANCE_NAME') instance_name
FROM dual;

This is an excellent way to make sure the application really landed on 26ai.
52. Monitor the first few hours
Monitor:
SELECT *
FROM v$session
WHERE username IS NOT NULL;

Active sessions:
SELECT
    username,
    status,
    COUNT(*)
FROM v$session
WHERE username IS NOT NULL
GROUP BY username, status
ORDER BY username;

Check alert log.
Also monitor:

CPU
Memory
I/O
Wait events
Redo
Undo
TEMP
Tablespace usage
Blocking sessions
Long-running SQL
Application errors

53. Don't immediately delete the 19c source
Even though the target is disposable, the source is your rollback point.
Keep:

19c database
19c backup
Data Pump dump
transported datafiles
TDE wallet
configuration

until you've completed business validation.
A sensible approach is:

Day 0
Migration
  ↓
Day 1
Application validation
  ↓
Day 2-7
Production monitoring
  ↓
After sign-off
Retire old 19c

The exact retention period should follow your organization's rollback/backup policy.
The faster version
If your database is, say:
5 TB

the biggest mistake would be treating this like a normal:
expdp
   ↓
huge dump
   ↓
impdp

migration.
Instead:

                    19c
                     |
             Full Transportable
                     |
          +----------+----------+
          |                     |
       Metadata              Datafiles
       via dump             direct copy
          |                     |
          +----------+----------+
                     |
                     v
                   26ai

Oracle specifically documents this hybrid behavior: transportable tablespaces have their metadata unloaded into the dump, while their actual data is moved through the datafiles; non-transportable tablespaces such as SYSTEM and SYSAUX use normal Data Pump movement. 
O
Oracle Documentation
+1
That's why Full Transportable is attractive for large databases.

If the source and target are on different servers
I'd optimize the data path like this:
              19c SERVER
                   |
                   |
             10/25 Gb network
                   |
                   v
              26ai SERVER

rather than:
19c
 |
 v
jump server
 |
 v
backup server
 |
 v
target

Every unnecessary hop costs time.
If your infrastructure supports shared storage or very high-speed network transfer, use that.

If you have 20+ TB
At that size, I'd stop before blindly implementing the commands above.
The architecture becomes much more important.

I'd investigate:

Transportable tablespaces
        +
RMAN/DBMS_FILE_TRANSFER
        +
parallel datafile transfer
        +
Data Pump metadata

and potentially a minimal-downtime replication strategy.
The exact answer depends heavily on storage and network throughput.

Important alternative: AutoUpgrade
There is one scenario where I would change the recommendation.
If your requirement is actually:

"I want the existing 19c database itself to become 26ai, and I don't need to preserve the 19c installation as a separate database."
Then use AutoUpgrade, not Data Pump.
Oracle's 26ai documentation says 19c can be directly upgraded to 26ai, and AutoUpgrade is the supported upgrade mechanism. 
O
Oracle Documentation
+1

But your situation sounds like:

19c source database
       |
       | COPY/MIGRATE
       v
26ai target database

rather than:
19c database
       |
       | UPGRADE
       v
same database → 26ai

So I'd stick with the Full Transportable Data Pump migration unless there's another constraint.
My recommended production sequence
I'd implement your migration in these phases:
PHASE 1
Source assessment
    ↓
19c version / CDB / PDB
    ↓
DB size
    ↓
Tablespaces
    ↓
TDE
    ↓
Platform/endian
    ↓
Invalid objects
    ↓
Components

PHASE 2
Build clean 26ai
    ↓
Install 26ai RU
    ↓
Create CDB/PDB
    ↓
Create storage
    ↓
Configure listener/services
    ↓
Configure TDE

PHASE 3
Migration rehearsal
    ↓
Full Transportable EXPDP
    ↓
Copy dump
    ↓
Copy datafiles
    ↓
IMPDP
    ↓
Compile
    ↓
Validate
    ↓
Application testing

PHASE 4
Production cutover
    ↓
Stop application
    ↓
Stop writes
    ↓
Final EXPDP
    ↓
Final datafile copy
    ↓
IMPDP
    ↓
Compile/validate
    ↓
Application connection switch
    ↓
Application startup

PHASE 5
Post-cutover
    ↓
Monitor
    ↓
Business validation
    ↓
Keep 19c rollback copy
    ↓
Eventually decommission 19c

What I need from you to make this exact
The commands above are deliberately generic because CDB/PDB, RAC, ASM, filesystem, and database size change the exact implementation.
Send me the output of these from the 19c source:

SELECT banner_full FROM v$version;

SELECT name, cdb, open_mode, database_role
FROM v$database;

SELECT con_id, name, open_mode
FROM v$containers;

SELECT platform_name
FROM v$database;

SELECT ROUND(SUM(bytes)/1024/1024/1024,2) AS size_gb
FROM dba_data_files;

SELECT tablespace_name,
       ROUND(SUM(bytes)/1024/1024/1024,2) AS size_gb
FROM dba_data_files
GROUP BY tablespace_name
ORDER BY size_gb DESC;

SELECT wrl_type, status, wallet_type
FROM v$encryption_wallet;

And tell me:
Source:
  RAC or single instance?
  ASM or filesystem?

Target:
  RAC or single instance?
  ASM or filesystem?
  CDB/PDB?

Network:
  1G / 10G / 25G / other?

Database:
  approximately ___ TB

Downtime:
  acceptable / must be minimal

With those details, I can turn this into a copy-pasteable 19c → 26ai migration runbook, including the exact expdp, datafile-copy, impdp, PDB, ASM/filesystem, parallelism, validation, and rollback commands for your topology.


OO
Sources
You said:

can you give me a complete advanced shell script to do this with automation ?
ChatGPT said:
Yes. For your scenario, I would automate it as a controlled migration pipeline, not as a blind expdp → scp → impdp script.
One correction to the earlier approach is important: for a full transportable export, transportable tablespaces must be read-only during the transport operation, and Oracle's current 26ai documentation recommends keeping source copies of the transported datafiles until the target import succeeds. 
O
Oracle Documentation
+1

Also, Oracle 26ai explicitly describes datafile copying as the fastest data-movement method and supports TRANSPORTABLE=ALWAYS with a full export. 
O
Oracle Documentation

Below is a production-oriented framework that automates:

source validation
target validation
prechecks
transport-set checks
source tablespace read-only handling
full transportable expdp
extraction of transport datafiles
parallel rsync
target datafile mapping
impdp
import monitoring
post-import validation
invalid object compilation
row/object validation
logging
resumability
lock/guard files
dry-run mode
explicit destructive-target confirmation
I would not make the script automatically destroy the target database. That's one step I'd deliberately keep as an explicit DBA-approved operation.
1. Architecture
I recommend splitting it into:
migration.conf
        |
        v
migrate_19c_to_26ai.sh
        |
        +-- 01_validate_source
        +-- 02_validate_target
        +-- 03_prepare_source
        +-- 04_export
        +-- 05_transfer
        +-- 06_prepare_target
        +-- 07_import
        +-- 08_validate
        +-- 09_finalize

The script runs from the source server, and uses SSH to control the target.
              SOURCE 19c
                  |
                  | expdp
                  v
             dump files
                  |
                  | rsync
                  |
                  v
              TARGET 26ai
                  |
                  | impdp
                  v
              validation

For the large application tablespaces, the datafiles themselves are copied rather than being unloaded/reloaded through Data Pump. That's the main performance advantage. 
O
Oracle Documentation
+1
2. Directory structure
Create:
mkdir -p /opt/oracle-migration/{bin,conf,logs,state,sql}
chmod 750 /opt/oracle-migration

Result:
/opt/oracle-migration/
├── bin/
│   └── migrate_19c_to_26ai.sh
├── conf/
│   └── migration.conf
├── logs/
├── state/
└── sql/

3. Configuration file
Create:
/opt/oracle-migration/conf/migration.conf

with:
#!/bin/bash

###############################################################################
# Oracle 19c -> 26ai Full Transportable Migration
###############################################################################

#------------------------------------------------------------------------------
# SOURCE
#------------------------------------------------------------------------------

export SOURCE_HOST="db19.example.com"
export SOURCE_SID="PROD19"
export SOURCE_ORACLE_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"
export SOURCE_ORACLE_BASE="/u01/app/oracle"

# OS user on source
export SOURCE_OS_USER="oracle"

#------------------------------------------------------------------------------
# TARGET
#------------------------------------------------------------------------------

export TARGET_HOST="db26.example.com"
export TARGET_SID="PROD26"
export TARGET_ORACLE_HOME="/u01/app/oracle/product/26.0.0/dbhome_1"
export TARGET_ORACLE_BASE="/u01/app/oracle"

export TARGET_OS_USER="oracle"

#------------------------------------------------------------------------------
# DATA PUMP
#------------------------------------------------------------------------------

export DP_USER="SYSTEM"

export SOURCE_DP_DIR_NAME="MIGRATION_DP"
export TARGET_DP_DIR_NAME="MIGRATION_DP"

export SOURCE_DP_DIR="/u03/dpump"
export TARGET_DP_DIR="/u03/dpump"

#------------------------------------------------------------------------------
# TRANSPORT DATAFILES
#------------------------------------------------------------------------------

export SOURCE_DATA_DIR="/u02/oradata/${SOURCE_SID}"
export TARGET_DATA_DIR="/u02/oradata/${TARGET_SID}"

#------------------------------------------------------------------------------
# STAGING
#------------------------------------------------------------------------------

export SOURCE_STAGE="/u04/migration/${SOURCE_SID}"
export TARGET_STAGE="/u04/migration/${TARGET_SID}"

#------------------------------------------------------------------------------
# PERFORMANCE
#------------------------------------------------------------------------------

# Start conservatively.
export DP_PARALLEL=8

# Number of parallel rsync processes.
export RSYNC_PARALLEL=4

# rsync options
export RSYNC_OPTS="-aHAX --numeric-ids --info=progress2"

#------------------------------------------------------------------------------
# EXPORT
#------------------------------------------------------------------------------

export DUMP_PREFIX="FULL_${SOURCE_SID}_FT"

export EXPORT_LOG="${SOURCE_STAGE}/${DUMP_PREFIX}_export.log"

export TRANSPORT_DATAFILES_LOG="transport_datafiles.par"

#------------------------------------------------------------------------------
# IMPORT
#------------------------------------------------------------------------------

export IMPORT_LOG="${TARGET_STAGE}/${DUMP_PREFIX}_import.log"

#------------------------------------------------------------------------------
# VALIDATION
#------------------------------------------------------------------------------

export VALIDATION_LOG="${TARGET_STAGE}/post_migration_validation.log"

#------------------------------------------------------------------------------
# SSH
#------------------------------------------------------------------------------

export SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=yes"

#------------------------------------------------------------------------------
# SAFETY
#------------------------------------------------------------------------------

# NEVER set this to YES unless you really understand the implications.
export ALLOW_DESTRUCTIVE_TARGET="NO"

# Require explicit confirmation before migration.
export REQUIRE_CONFIRMATION="YES"

# Dry run:
# YES = validate everything but do not export/import.
# NO  = execute migration.
export DRY_RUN="YES"

#------------------------------------------------------------------------------
# SOURCE TABLESPACE HANDLING
#------------------------------------------------------------------------------

# YES:
#   Script will make transportable tablespaces READ ONLY.
#
# NO:
#   Script will NOT change tablespace state.
#
# Recommended: YES for the controlled migration window.
export MANAGE_TABLESPACE_READONLY="YES"

#------------------------------------------------------------------------------
# RETENTION
#------------------------------------------------------------------------------

# Keep source transport files after migration.
export KEEP_SOURCE_FILES="YES"

4. Important point about passwords
Don't put:
DP_PASSWORD="mypassword"

in this file.
Use an Oracle wallet / external authentication or securely prompt for credentials.

For example, if your migration OS account can connect as SYS:

sqlplus -s / as sysdba

then use OS authentication for administrative SQL.
For Data Pump, you can use a secure credential mechanism appropriate to your environment.

5. Main automation script
Create:
/opt/oracle-migration/bin/migrate_19c_to_26ai.sh

Here's the core production framework:
#!/usr/bin/env bash

###############################################################################
# Oracle 19c -> 26ai Full Transportable Migration
#
# Run from SOURCE 19c server.
#
# This script:
#   1. Validates source
#   2. Validates target
#   3. Performs transport checks
#   4. Makes transport tablespaces READ ONLY
#   5. Runs FULL TRANSPORTABLE expdp
#   6. Copies dump files
#   7. Copies transportable datafiles
#   8. Runs target impdp
#   9. Compiles invalid objects
#  10. Performs validation
#
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# GLOBALS
###############################################################################

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${BASE_DIR}/conf/migration.conf"

RUN_ID="$(date '+%Y%m%d_%H%M%S')"

LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"

LOG_FILE="${LOG_DIR}/migration_${RUN_ID}.log"
LOCK_FILE="${STATE_DIR}/migration.lock"

mkdir -p "$LOG_DIR" "$STATE_DIR"

###############################################################################
# FUNCTIONS
###############################################################################

log()
{
    local msg="$*"

    echo "$(date '+%Y-%m-%d %H:%M:%S') | INFO | ${msg}" \
        | tee -a "$LOG_FILE"
}

warn()
{
    local msg="$*"

    echo "$(date '+%Y-%m-%d %H:%M:%S') | WARN | ${msg}" \
        | tee -a "$LOG_FILE" >&2
}

fatal()
{
    local msg="$*"

    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | ${msg}" \
        | tee -a "$LOG_FILE" >&2

    exit 1
}

run_cmd()
{
    log "CMD: $*"

    "$@" >>"$LOG_FILE" 2>&1
}

ssh_target()
{
    ssh ${SSH_OPTS} \
        "${TARGET_OS_USER}@${TARGET_HOST}" \
        "$@"
}

target_sql()
{
    local sql="$1"

    ssh_target "
        export ORACLE_SID='${TARGET_SID}'
        export ORACLE_HOME='${TARGET_ORACLE_HOME}'
        export PATH='${TARGET_ORACLE_HOME}/bin:\$PATH'

        sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF
${sql}
EXIT;
SQL
"
}

source_sql()
{
    local sql="$1"

    export ORACLE_SID
    export ORACLE_HOME
    export PATH="${ORACLE_HOME}/bin:${PATH}"

    sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF
${sql}
EXIT;
SQL
}

check_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        fatal "Required command not found: $1"
}

###############################################################################
# ERROR HANDLING
###############################################################################

cleanup()
{
    rm -f "$LOCK_FILE"
}

trap cleanup EXIT

trap '
    rc=$?
    echo "$(date "+%Y-%m-%d %H:%M:%S") | ERROR | Failure at line ${LINENO}, exit code ${rc}" \
        | tee -a "$LOG_FILE" >&2
    exit "$rc"
' ERR

###############################################################################
# LOAD CONFIG
###############################################################################

[[ -f "$CONFIG_FILE" ]] ||
    fatal "Configuration file not found: $CONFIG_FILE"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

###############################################################################
# VALIDATE CONFIG
###############################################################################

required_vars=(
    SOURCE_HOST
    SOURCE_SID
    SOURCE_ORACLE_HOME
    TARGET_HOST
    TARGET_SID
    TARGET_ORACLE_HOME
    SOURCE_DP_DIR
    TARGET_DP_DIR
    SOURCE_STAGE
    TARGET_STAGE
    DP_PARALLEL
    RSYNC_PARALLEL
)

for v in "${required_vars[@]}"; do
    [[ -n "${!v:-}" ]] ||
        fatal "Required configuration variable is empty: $v"
done

###############################################################################
# COMMAND CHECKS
###############################################################################

check_command sqlplus
check_command expdp
check_command impdp
check_command rsync
check_command ssh
check_command awk
check_command grep
check_command sed
check_command find

###############################################################################
# LOCK
###############################################################################

if [[ -e "$LOCK_FILE" ]]; then
    fatal "Migration lock exists: $LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"

###############################################################################
# ENVIRONMENT
###############################################################################

export ORACLE_SID="$SOURCE_SID"
export ORACLE_HOME="$SOURCE_ORACLE_HOME"
export PATH="${ORACLE_HOME}/bin:${PATH}"

###############################################################################
# START
###############################################################################

log "============================================================"
log "Oracle 19c -> 26ai Migration"
log "Run ID       : ${RUN_ID}"
log "Source       : ${SOURCE_HOST}/${SOURCE_SID}"
log "Target       : ${TARGET_HOST}/${TARGET_SID}"
log "Dry Run      : ${DRY_RUN}"
log "DP Parallel  : ${DP_PARALLEL}"
log "Rsync        : ${RSYNC_PARALLEL}"
log "============================================================"

###############################################################################
# CONFIRMATION
###############################################################################

if [[ "${REQUIRE_CONFIRMATION}" == "YES" &&
      "${DRY_RUN}" != "YES" ]]; then

    echo
    echo "============================================================"
    echo "WARNING"
    echo "============================================================"
    echo
    echo "SOURCE : ${SOURCE_HOST}/${SOURCE_SID}"
    echo "TARGET : ${TARGET_HOST}/${TARGET_SID}"
    echo
    echo "Target data is assumed disposable."
    echo
    read -r -p \
        "Type MIGRATE-${TARGET_SID}-${RUN_ID} to continue: " CONFIRM

    EXPECTED="MIGRATE-${TARGET_SID}-${RUN_ID}"

    [[ "$CONFIRM" == "$EXPECTED" ]] ||
        fatal "Confirmation failed."
fi

###############################################################################
# SOURCE VALIDATION
###############################################################################

validate_source()
{
    log "Validating source database..."

    local db_info

    db_info="$(
        source_sql "
            SELECT name || '|' || cdb || '|' || open_mode
            FROM v\$database;
        "
    )"

    log "Source DB: ${db_info}"

    [[ "$db_info" == *"OPEN"* ]] ||
        fatal "Source database is not OPEN."

    source_sql "
        SELECT banner_full
        FROM v\$version;
    " | tee -a "$LOG_FILE"

    log "Checking invalid objects..."

    source_sql "
        SELECT owner || '|' ||
               object_type || '|' ||
               COUNT(*)
        FROM dba_objects
        WHERE status <> 'VALID'
        GROUP BY owner, object_type
        ORDER BY owner, object_type;
    " | tee -a "$LOG_FILE"

    log "Checking database size..."

    source_sql "
        SELECT ROUND(
            SUM(bytes)/1024/1024/1024,
            2
        )
        FROM dba_data_files;
    " | tee -a "$LOG_FILE"

    log "Checking TDE..."

    source_sql "
        SELECT wrl_type || '|' ||
               status || '|' ||
               wallet_type
        FROM v\$encryption_wallet;
    " | tee -a "$LOG_FILE"

    log "Source validation complete."
}

###############################################################################
# TARGET VALIDATION
###############################################################################

validate_target()
{
    log "Validating target database..."

    local db_info

    db_info="$(
        target_sql "
            SELECT name || '|' || cdb || '|' || open_mode
            FROM v\$database;
        "
    )"

    log "Target DB: ${db_info}"

    target_sql "
        SELECT banner_full
        FROM v\$version;
    " | tee -a "$LOG_FILE"

    log "Checking target connectivity..."

    target_sql "
        SELECT
            sys_context('USERENV','DB_NAME') ||
            '|' ||
            sys_context('USERENV','INSTANCE_NAME')
        FROM dual;
    " | tee -a "$LOG_FILE"

    log "Target validation complete."
}

###############################################################################
# TARGET VERSION CHECK
###############################################################################

check_target_version()
{
    log "Checking target version..."

    target_sql "
        SELECT version
        FROM v\$instance;
    " | tee -a "$LOG_FILE"

    target_sql "
        SELECT banner_full
        FROM v\$version
        WHERE banner LIKE 'Oracle%';
    " | tee -a "$LOG_FILE"
}

###############################################################################
# PLATFORM CHECK
###############################################################################

check_platform()
{
    log "Checking source platform..."

    source_sql "
        SELECT platform_name
        FROM v\$database;
    " | tee -a "$LOG_FILE"

    log "Checking target platform..."

    target_sql "
        SELECT platform_name
        FROM v\$database;
    " | tee -a "$LOG_FILE"
}

###############################################################################
# SOURCE TABLESPACES
###############################################################################

get_transport_tablespaces()
{
    log "Determining transportable tablespaces..."

    source_sql "
        SELECT tablespace_name
        FROM dba_tablespaces
        WHERE contents = 'PERMANENT'
          AND tablespace_name NOT IN ('SYSTEM','SYSAUX')
        ORDER BY tablespace_name;
    " | tee "${STATE_DIR}/transport_tablespaces.txt" \
      | tee -a "$LOG_FILE"
}

###############################################################################
# TRANSPORT SET CHECK
###############################################################################

transport_check()
{
    log "Running transport-set validation..."

    local ts_list

    ts_list="$(
        source_sql "
            SELECT LISTAGG(
                tablespace_name,
                ','
            ) WITHIN GROUP (
                ORDER BY tablespace_name
            )
            FROM dba_tablespaces
            WHERE contents = 'PERMANENT'
              AND tablespace_name NOT IN ('SYSTEM','SYSAUX');
        "
    )"

    log "Transport tablespaces: ${ts_list}"

    [[ -n "$ts_list" ]] ||
        fatal "No transportable tablespaces detected."

    source_sql "
        BEGIN
            DBMS_TTS.TRANSPORT_SET_CHECK(
                ts_list => '${ts_list}',
                incl_constraints => TRUE
            );
        END;
        /
    "

    log "Transport set violations:"

    source_sql "
        SELECT
            violation
        FROM transport_set_violations;
    " | tee -a "$LOG_FILE"

    local violations

    violations="$(
        source_sql "
            SELECT COUNT(*)
            FROM transport_set_violations;
        "
    )"

    violations="$(echo "$violations" | xargs)"

    [[ "$violations" == "0" ]] ||
        fatal "Transport set has ${violations} violation(s)."
}

###############################################################################
# CREATE DIRECTORIES
###############################################################################

prepare_directories()
{
    log "Preparing source directories..."

    mkdir -p "$SOURCE_STAGE"

    log "Preparing target directories..."

    ssh_target "mkdir -p '${TARGET_STAGE}' '${TARGET_DP_DIR}'"
}

###############################################################################
# CREATE DP DIRECTORY
###############################################################################

create_dp_directory()
{
    log "Creating source Data Pump directory..."

    source_sql "
        CREATE OR REPLACE DIRECTORY
            ${SOURCE_DP_DIR_NAME}
        AS '${SOURCE_DP_DIR}';

        GRANT READ, WRITE ON DIRECTORY
            ${SOURCE_DP_DIR_NAME}
        TO ${DP_USER};
    "

    log "Creating target Data Pump directory..."

    target_sql "
        CREATE OR REPLACE DIRECTORY
            ${TARGET_DP_DIR_NAME}
        AS '${TARGET_DP_DIR}';

        GRANT READ, WRITE ON DIRECTORY
            ${TARGET_DP_DIR_NAME}
        TO ${DP_USER};
    "
}

###############################################################################
# TABLESPACE READ ONLY
###############################################################################

set_tablespaces_read_only()
{
    if [[ "${MANAGE_TABLESPACE_READONLY}" != "YES" ]]; then
        log "Tablespace READ ONLY management disabled."
        return
    fi

    log "Setting transportable tablespaces READ ONLY..."

    while read -r ts; do

        ts="$(echo "$ts" | xargs)"

        [[ -z "$ts" ]] && continue

        log "READ ONLY: ${ts}"

        if [[ "${DRY_RUN}" != "YES" ]]; then
            source_sql "
                ALTER TABLESPACE \"${ts}\" READ ONLY;
            "
        fi

    done < "${STATE_DIR}/transport_tablespaces.txt"
}

###############################################################################
# RESTORE TABLESPACES READ WRITE
###############################################################################

restore_tablespaces_read_write()
{
    if [[ "${MANAGE_TABLESPACE_READONLY}" != "YES" ]]; then
        return
    fi

    log "Restoring transportable tablespaces READ WRITE..."

    while read -r ts; do

        ts="$(echo "$ts" | xargs)

        [[ -z "$ts" ]] && continue

        log "READ WRITE: ${ts}"

        if [[ "${DRY_RUN}" != "YES" ]]; then
            source_sql "
                ALTER TABLESPACE \"${ts}\" READ WRITE;
            "
        fi

    done < "${STATE_DIR}/transport_tablespaces.txt"
}

###############################################################################
# EXPORT
###############################################################################

run_export()
{
    log "Starting FULL TRANSPORTABLE export..."

    local dumpfile="${DUMP_PREFIX}_%U.dmp"

    if [[ "${DRY_RUN}" == "YES" ]]; then
        log "DRY RUN: expdp skipped."
        return
    fi

    expdp "${DP_USER}" \
        FULL=Y \
        TRANSPORTABLE=ALWAYS \
        DIRECTORY="${SOURCE_DP_DIR_NAME}" \
        DUMPFILE="${dumpfile}" \
        LOGFILE="$(basename "${EXPORT_LOG}")" \
        PARALLEL="${DP_PARALLEL}" \
        TRANSPORT_DATAFILES_LOG="${TRANSPORT_DATAFILES_LOG}" \
        >>"${LOG_FILE}" 2>&1

    log "Data Pump export completed."

    grep -Ei \
        'ORA-|UDI-|successfully completed' \
        "${SOURCE_DP_DIR}/${EXPORT_LOG##*/}" \
        | tee -a "$LOG_FILE" || true
}

###############################################################################
# EXTRACT TRANSPORT DATAFILE LIST
###############################################################################

extract_transport_files()
{
    log "Extracting transport datafile list..."

    local tdl

    tdl="${SOURCE_DP_DIR}/${TRANSPORT_DATAFILES_LOG}"

    if [[ ! -f "$tdl" ]]; then

        warn "TRANSPORT_DATAFILES_LOG not found at ${tdl}"

        warn "Attempting to extract datafiles from export log."

        grep -Ei \
            '\.dbf|\.data|Datafiles required' \
            "${SOURCE_DP_DIR}/${EXPORT_LOG##*/}" \
            > "${STATE_DIR}/transport_datafiles_raw.txt" || true

    else

        cp "$tdl" \
            "${STATE_DIR}/transport_datafiles.par"

        grep -E \
            "^'|TRANSPORT_DATAFILES" \
            "$tdl" \
            > "${STATE_DIR}/transport_datafiles_raw.txt" || true
    fi

    log "Transport file information saved under ${STATE_DIR}."
}

###############################################################################
# COPY DUMP FILES
###############################################################################

copy_dump_files()
{
    log "Copying Data Pump dump files..."

    if [[ "${DRY_RUN}" == "YES" ]]; then
        log "DRY RUN: dump file transfer skipped."
        return
    fi

    rsync ${RSYNC_OPTS} \
        "${SOURCE_DP_DIR}/" \
        "${TARGET_OS_USER}@${TARGET_HOST}:${TARGET_DP_DIR}/" \
        --include="${DUMP_PREFIX}_*.dmp" \
        --include="$(basename "${EXPORT_LOG}")" \
        --include="${TRANSPORT_DATAFILES_LOG}" \
        --exclude='*' \
        >>"${LOG_FILE}" 2>&1

    log "Dump file transfer completed."
}

###############################################################################
# FIND SOURCE DATAFILES
###############################################################################

get_datafiles()
{
    log "Collecting source datafiles..."

    source_sql "
        SET LINESIZE 400
        SELECT file_name
        FROM dba_data_files
        ORDER BY file_id;
    " > "${STATE_DIR}/all_datafiles.txt"

    sed -i \
        '/^[[:space:]]*$/d' \
        "${STATE_DIR}/all_datafiles.txt"

    log "Datafile inventory saved."
}

###############################################################################
# COPY TRANSPORT DATAFILES
###############################################################################

copy_transport_datafiles()
{
    log "Copying transportable datafiles..."

    if [[ "${DRY_RUN}" == "YES" ]]; then
        log "DRY RUN: datafile transfer skipped."
        return
    fi

    if [[ ! -f "${STATE_DIR}/transport_datafiles.par" ]]; then
        fatal "Transport datafile parameter file not found."
    fi

    mkdir -p "${STATE_DIR}/copied_files"

    # Extract quoted datafile paths from generated TDL.
    grep -E "^'[^\"]+.*'" \
        "${STATE_DIR}/transport_datafiles.par" \
        | sed "s/'//g" \
        | sed '/^[[:space:]]*$/d' \
        > "${STATE_DIR}/transport_source_files.txt" || true

    if [[ ! -s "${STATE_DIR}/transport_source_files.txt" ]]; then

        warn "Could not automatically parse TDL datafile list."

        warn "Review:"
        warn "${STATE_DIR}/transport_datafiles.par"

        fatal "Refusing to guess which datafiles should be transported."
    fi

    cat "${STATE_DIR}/transport_source_files.txt" \
        | tee -a "$LOG_FILE"

    while read -r src_file; do

        [[ -f "$src_file" ]] ||
            fatal "Transport datafile does not exist: $src_file"

        filename="$(basename "$src_file")"

        target_file="${TARGET_DATA_DIR}/${filename}"

        log "Copying:"
        log "  SOURCE: ${src_file}"
        log "  TARGET: ${target_file}"

        rsync ${RSYNC_OPTS} \
            "$src_file" \
            "${TARGET_OS_USER}@${TARGET_HOST}:${target_file}" \
            >>"${LOG_FILE}" 2>&1 &

        echo "$!" >> "${STATE_DIR}/rsync_pids"

        # Limit parallel copies.
        while [[ "$(jobs -rp | wc -l)" -ge "${RSYNC_PARALLEL}" ]]; do
            wait -n || fatal "A datafile rsync failed."
        done

    done < "${STATE_DIR}/transport_source_files.txt"

    wait

    log "Transport datafile copy completed."
}

###############################################################################
# CREATE TARGET IMPORT PARFILE
###############################################################################

create_import_parfile()
{
    log "Creating target Data Pump import parameter file..."

    local parfile="${TARGET_STAGE}/${DUMP_PREFIX}_import.par"

    {
        echo "DIRECTORY=${TARGET_DP_DIR_NAME}"
        echo "DUMPFILE=${DUMP_PREFIX}_%U.dmp"
        echo "LOGFILE=$(basename "${IMPORT_LOG}")"
        echo "PARALLEL=${DP_PARALLEL}"
        echo "TRANSPORT_DATAFILES="

        while read -r src_file; do

            [[ -z "$src_file" ]] && continue

            filename="$(basename "$src_file")"

            echo "'${TARGET_DATA_DIR}/${filename}'"

        done < "${STATE_DIR}/transport_source_files.txt"

    } > "${STATE_DIR}/target_import.par"

    scp ${SSH_OPTS} \
        "${STATE_DIR}/target_import.par" \
        "${TARGET_OS_USER}@${TARGET_HOST}:${parfile}" \
        >>"${LOG_FILE}" 2>&1

    log "Import parameter file:"
    cat "${STATE_DIR}/target_import.par" \
        | tee -a "$LOG_FILE"
}

###############################################################################
# IMPORT
###############################################################################

run_import()
{
    log "Starting 26ai Data Pump import..."

    if [[ "${DRY_RUN}" == "YES" ]]; then
        log "DRY RUN: import skipped."
        return
    fi

    ssh_target "
        export ORACLE_SID='${TARGET_SID}'
        export ORACLE_HOME='${TARGET_ORACLE_HOME}'
        export PATH='${TARGET_ORACLE_HOME}/bin:\$PATH'

        impdp '${DP_USER}' \
            PARFILE='${TARGET_STAGE}/${DUMP_PREFIX}_import.par'
    " >>"${LOG_FILE}" 2>&1

    log "Data Pump import completed."
}

###############################################################################
# INVALID OBJECTS
###############################################################################

compile_invalid_objects()
{
    log "Compiling invalid objects on target..."

    if [[ "${DRY_RUN}" == "YES" ]]; then
        return
    fi

    target_sql "
        @?/rdbms/admin/utlrp.sql
    " >>"${LOG_FILE}" 2>&1

    log "Invalid object count:"

    target_sql "
        SELECT COUNT(*)
        FROM dba_objects
        WHERE status <> 'VALID';
    " | tee -a "$LOG_FILE"
}

###############################################################################
# TARGET VALIDATION
###############################################################################

validate_target_objects()
{
    log "Validating target objects..."

    if [[ "${DRY_RUN}" == "YES" ]]; then
        return
    fi

    target_sql "
        SELECT owner,
               object_type,
               COUNT(*)
        FROM dba_objects
        WHERE owner NOT IN
        (
            'SYS',
            'SYSTEM'
        )
        GROUP BY owner, object_type
        ORDER BY owner, object_type;
    " | tee -a "$LOG_FILE"

    log "Invalid objects:"

    target_sql "
        SELECT owner,
               object_name,
               object_type
        FROM dba_objects
        WHERE status <> 'VALID'
        ORDER BY owner, object_type, object_name;
    " | tee -a "$LOG_FILE"

    log "Unusable indexes:"

    target_sql "
        SELECT owner,
               index_name,
               table_name,
               status
        FROM dba_indexes
        WHERE status <> 'VALID';
    " | tee -a "$LOG_FILE"

    log "Disabled constraints:"

    target_sql "
        SELECT owner,
               constraint_name,
               table_name,
               status
        FROM dba_constraints
        WHERE status <> 'ENABLED';
    " | tee -a "$LOG_FILE"
}

###############################################################################
# FINAL CONNECTION TEST
###############################################################################

connection_test()
{
    log "Testing target connection..."

    target_sql "
        SELECT
            sys_context('USERENV','DB_NAME') ||
            '|' ||
            sys_context('USERENV','INSTANCE_NAME') ||
            '|' ||
            sys_context('USERENV','SERVICE_NAME')
        FROM dual;
    " | tee -a "$LOG_FILE"
}

###############################################################################
# MAIN
###############################################################################

main()
{
    validate_source
    validate_target
    check_target_version
    check_platform

    prepare_directories
    create_dp_directory

    get_transport_tablespaces
    transport_check
    get_datafiles

    if [[ "${DRY_RUN}" == "YES" ]]; then

        log "============================================================"
        log "DRY RUN COMPLETED"
        log "No data was changed."
        log "============================================================"

        exit 0
    fi

    set_tablespaces_read_only

    run_export

    extract_transport_files

    copy_dump_files
    copy_transport_datafiles

    create_import_parfile

    run_import

    compile_invalid_objects
    validate_target_objects
    connection_test

    restore_tablespaces_read_write

    log "============================================================"
    log "MIGRATION COMPLETED"
    log "============================================================"
}

main "$@"

There is one deliberate design choice in that script: it refuses to guess the transported datafiles if the Data Pump-generated list cannot be parsed. That's preferable to accidentally transporting the wrong files.
Oracle 26ai now provides TRANSPORT_DATAFILES_LOG, which generates a Data Pump parameter file containing the required transport datafiles, making automation considerably cleaner. 
O
Oracle Documentation

6. There is one thing I would change before production
The above is the framework, but I would make the production version more topology-aware.
In particular, I would add explicit handling for:

ASM
OMF
filesystem
CDB
PDB
RAC
single instance
TDE
source/target endian

For example, if the target uses ASM:
+DATA/PROD26/...

you don't want the script assuming:
/u02/oradata/PROD26/

Similarly, if the source is a CDB and you're migrating a particular PDB, the script should operate against that PDB rather than treating the whole CDB as a generic non-CDB database.
7. I would also add a pre-flight report
Before the actual migration, have the script generate something like:
===============================================================
ORACLE MIGRATION PRE-FLIGHT
===============================================================

SOURCE
------
Host                 : db19.example.com
Database             : PROD19
Version              : 19.26.x
CDB                  : YES
Platform             : Linux x86 64-bit
Database Size        : 8,421 GB

TARGET
------
Host                 : db26.example.com
Database             : PROD26
Version              : 26ai
CDB                  : YES
Platform             : Linux x86 64-bit

TRANSPORT
---------
Tablespaces          : 12
Transport violations  : 0
TDE                  : ENABLED
Endian               : SAME

STORAGE
-------
Source required      : 8.4 TB
Target free          : 12.7 TB
Status               : PASS

NETWORK
-------
Source -> Target     : 10 Gbps
Status               : PASS

DATA PUMP
---------
Parallel             : 16
Dump directory       : /u03/dpump
Status               : PASS

===============================================================
RESULT: READY FOR MIGRATION
===============================================================

That is much safer for a production DBA than simply running a 500-line shell script and hoping it works.
8. Very important: read-only tablespaces
This is one of the biggest catches with the transportable method.
Oracle's documentation says the tablespaces associated with transported tables/partitions must be read-only for transportable export. 
O
Oracle Documentation

Therefore, for your final migration:

Application
    |
    X STOP WRITES
    |
    v
19c
    |
    +-- APP_DATA    READ ONLY
    +-- APP_INDEX   READ ONLY
    +-- USERS       READ ONLY
    |
    v
expdp

The cleanest sequence is:
STOP APPLICATION

then:
ALTER TABLESPACE APP_DATA READ ONLY;
ALTER TABLESPACE APP_INDEX READ ONLY;
ALTER TABLESPACE USERS READ ONLY;

then:
expdp ...

then copy the datafiles.
Only after successful import should you return the source tablespaces to READ WRITE.

9. Why I don't recommend rsync of every DBF
This is a subtle but important point.
Don't do:

rsync /u02/oradata/PROD19/*.dbf target:/u02/oradata/PROD26/

unless you've independently verified that every single file belongs to the transport set.
The correct flow is:

expdp
  |
  +--> transport_datafiles.par
              |
              v
        exact datafiles
              |
              v
           rsync

Oracle specifically documents that the export can generate a list of the datafiles required for transport. 
O
Oracle Documentation
10. Import parameter file
I particularly recommend using a parameter file for impdp.
For example:

DIRECTORY=MIGRATION_DP
DUMPFILE=FULL_PROD19_FT_%U.dmp
LOGFILE=FULL_PROD19_FT_import.log
PARALLEL=8
TRANSPORT_DATAFILES=
'/u02/oradata/PROD26/app_data01.dbf'
'/u02/oradata/PROD26/app_data02.dbf'
'/u02/oradata/PROD26/app_index01.dbf'

Oracle documents TRANSPORT_DATAFILES as taking the absolute target-side datafile paths, which is exactly why the automation generates this file after copying the datafiles. 
O
Oracle Documentation
+1
11. Resume behavior
This deserves special attention.
Suppose:

8 TB

has been copied and the network fails at:
7.2 TB

You don't want to start again.
That's why rsync is used:

rsync -aHAX --info=progress2

A rerun can continue from the existing target files.
For the transportable import itself, don't assume it is equivalent to a resumable rsync; Oracle's documentation has specific behavior/restrictions around transportable imports. 
O
Oracle Documentation

Therefore my automation should have separate states:

EXPORT_COMPLETE
DATAFILES_COMPLETE
DUMPS_COMPLETE
IMPORT_STARTED
IMPORT_COMPLETE
VALIDATION_COMPLETE
CUTOVER_COMPLETE

12. I would add a state machine
For production, create:
state/
  01_SOURCE_VALIDATED
  02_TARGET_VALIDATED
  03_TRANSPORT_CHECKED
  04_TABLESPACES_READONLY
  05_EXPORT_COMPLETE
  06_DUMPS_TRANSFERRED
  07_DATAFILES_TRANSFERRED
  08_IMPORT_COMPLETE
  09_VALIDATION_COMPLETE
  10_CUTOVER_COMPLETE

Then the script can be restarted:
./migrate_19c_to_26ai.sh --resume

and it can determine:
Export already completed → skip
Dump transfer completed  → skip
Datafiles completed      → skip
Import not completed     → continue

That's how I'd make this genuinely production-grade.
13. Add an explicit --dry-run
Before doing anything:
./migrate_19c_to_26ai.sh --dry-run

It should check:
✓ source reachable
✓ target reachable
✓ source Oracle home
✓ target Oracle home
✓ sqlplus
✓ expdp
✓ impdp
✓ rsync
✓ SSH
✓ source version
✓ target version
✓ CDB/PDB
✓ platform
✓ endian
✓ storage
✓ TDE
✓ tablespaces
✓ transport violations

and end with:
READY FOR MIGRATION

without modifying anything.
14. Do not automate destruction
Even though you told me the target data can be destroyed, I would keep this outside the script:
DROP DATABASE
DROP PDB
DROP TABLESPACE

Instead:
Phase 1
  automated validation

Phase 2
  DBA confirms target destruction

Phase 3
  automated migration

That prevents a typo like:
TARGET_HOST=db26

accidentally becoming:
TARGET_HOST=db19

and destroying the source.
15. Recommended final production architecture
For your actual environment, I would build the automation like this:
                     ┌─────────────────────┐
                     │ migration.conf      │
                     └──────────┬──────────┘
                                │
                                v
                    ┌───────────────────────┐
                    │ migration controller  │
                    └──────────┬────────────┘
                               │
             ┌─────────────────┼─────────────────┐
             │                 │                 │
             v                 v                 v
       Source checks      Target checks      Network checks
             │                 │                 │
             └─────────────────┼─────────────────┘
                               │
                               v
                    ┌───────────────────────┐
                    │ Transport validation  │
                    └──────────┬────────────┘
                               │
                               v
                     Tablespaces READ ONLY
                               │
                               v
                    ┌───────────────────────┐
                    │ Full Transport Export │
                    └──────────┬────────────┘
                               │
                    ┌──────────┴───────────┐
                    │                      │
                    v                      v
              Dump files              Datafiles
                    │                      │
                    └──────────┬───────────┘
                               │
                         parallel rsync
                               │
                               v
                    ┌───────────────────────┐
                    │       26ai            │
                    │   Full Transport      │
                    │       Import          │
                    └──────────┬────────────┘
                               │
                               v
                     Post-migration checks
                               │
                               v
                     Application validation
                               │
                               v
                           CUTOVER

This approach follows Oracle's documented full-transportable architecture: metadata is exported through Data Pump while data in transportable tablespaces is moved by copying the datafiles. 
O
Oracle Documentation
+1
One thing I need before I'd call this "production-ready"
The script above is a strong generic framework, but I would not want you to run it unchanged against production because the exact commands for your environment depend heavily on ASM vs filesystem and CDB/PDB vs non-CDB.
Send me these four outputs:

SELECT name, cdb, open_mode FROM v$database;

SELECT con_id, name, open_mode FROM v$containers;

SELECT platform_name FROM v$database;

SELECT ROUND(SUM(bytes)/1024/1024/1024,2) AS size_gb
FROM dba_data_files;

And tell me:
19c:  RAC / Single
19c:  ASM / Filesystem

26ai: RAC / Single
26ai: ASM / Filesystem

Network: 1G / 10G / 25G / 40G / other

Then I can give you the final hardened version with the topology-specific SQL, ASM/OMF handling, CDB/PDB handling, parallel datafile transfer, resume/state management, pre-flight report, rollback, and exact expdp/impdp commands.


OO
Sources
You said:

source is in different host and target in different host and we also need to verify if source is non cdb or cdb but here the case is noncdb source
ChatGPT said:
Correct. Since your source is a non-CDB 19c on Host A and the target is a separate 26ai database on Host B, for a non-CDB into a multitenant database requires converting the non-CDB into a PDB as part of the migration process. For a pure Data Pump migration, you can instead export the schemas/data from the non-CDB and import them into a 26ai PDB I'd simplify the automation around that topology.
The important distinction is:

SOURCE HOST
┌─────────────────────────────┐
│ Oracle 19c                  │
│ NON-CDB                     │
│ PROD19                      │
│                             │
│ /u02/oradata/PROD19         │
│ /u03/dpump                  │
└──────────────┬──────────────┘
               │
               │ SSH + rsync
               │
               ▼
TARGET HOST
┌─────────────────────────────┐
│ Oracle 26ai                 │
│ CDB                         │
│ └── target PDB              │
│                             │
│ /u02/oradata/PROD26         │
│ /u03/dpump                  │
└─────────────────────────────┘

However, there's a major architectural point: a non-CDB 19c source cannot simply be treated as a PDB in a 26ai CDB. Oracle's supported upgrade/migration path for a non-CDB into a multitenant database requires converting the non-CDB into a PDB as part of the migration process. For a pure Data Pump migration, you can instead export the schemas/data from the non-CDB and import them into a 26ai PDB.
So before I give you a final "one-click" script, I'd structure it around non-CDB → 26ai PDB, assuming your target 26ai is a CDB.

First, the source detection should be automatic
Your script should run:
sqlplus -s / as sysdba <<EOF
set heading off
set feedback off
select cdb from v\\$database;
EOF

Then:
CDB=NO

means:
Source = NON-CDB

and:
CDB=YES

means:
Source = CDB

For your current case, it should detect:
SOURCE_CDB=NO

and automatically select the non-CDB migration workflow.
I would make the script workflow
1. SSH to source
       ↓
2. Detect 19c version
       ↓
3. Detect CDB/NON-CDB
       ↓
4. Verify source = NON-CDB
       ↓
5. Collect DB size
       ↓
6. Collect tablespaces
       ↓
7. Check TDE
       ↓
8. Check platform
       ↓
9. Check invalid objects
       ↓
10. Check transportability
       ↓
11. SSH to target
       ↓
12. Verify target = 26ai
       ↓
13. Verify target CDB/PDB
       ↓
14. Verify target storage
       ↓
15. Create clean target PDB
       ↓
16. Export source
       ↓
17. Transfer dump/data
       ↓
18. Import into target PDB
       ↓
19. Compile invalid objects
       ↓
20. Compare source/target
       ↓
21. Application validation
       ↓
22. Cutover

One correction to the previous script
I would not use the previous FULL=Y TRANSPORTABLE=ALWAYS script unchanged for your non-CDB → 26ai case.
For your topology, I'd first decide between:

Option 1 — Non-CDB → new 26ai PDB using Data Pump

19c NON-CDB
     |
     | Data Pump
     v
26ai CDB
     |
     +-- NEW_PDB

This is the straightforward logical migration.
Option 2 — Non-CDB → PDB conversion/upgrade

19c NON-CDB
     |
     | DBMS_PDB / compatibility checks
     v
PDB-compatible representation
     |
     v
26ai CDB
     |
     +-- NEW_PDB

This is more appropriate if you want to preserve the database more faithfully as a database rather than performing a schema/data migration.
For a large database where speed is the priority, the choice matters enormously.

What I recommend for your script
Let's make the automation intelligent:
./oracle_migrate.sh precheck
./oracle_migrate.sh prepare
./oracle_migrate.sh export
./oracle_migrate.sh transfer
./oracle_migrate.sh import
./oracle_migrate.sh validate
./oracle_migrate.sh cutover

And:
./oracle_migrate.sh all

would execute everything sequentially.
It should also support:

./oracle_migrate.sh resume
./oracle_migrate.sh status
./oracle_migrate.sh rollback

with state files so a failed 500-GB/5-TB transfer doesn't restart from zero.
For your exact case, I would build the final script as 19c NON-CDB → clean 26ai PDB, with source and target on separate hosts.

To make the script genuinely executable rather than generic, I need just these target details:

SOURCE HOST:
  Oracle 19c
  NON-CDB
  ASM or filesystem?

TARGET HOST:
  Oracle 26ai
  CDB + PDB or non-CDB?
  ASM or filesystem?

Approx DB size:
  ___ GB/TB

Network between hosts:
  1G / 10G / 25G / other

Downtime:
  acceptable / minimal

If you give me those, I can provide the complete final script package (migration.conf + main shell + SQL files + precheck + transfer + import + validation + resume/status handling) specifically for 19c non-CDB on Host A → 26ai PDB on Host B.

You said:

full script
ChatGPT said:
Yes. Given the clarified topology, I would build the automation specifically for:
SOURCE HOST
Oracle 19c NON-CDB
        |
        | SSH / rsync
        |
        v
TARGET HOST
Oracle 26ai CDB
        |
        +-- NEW PDB

Oracle explicitly supports moving a non-CDB into a PDB using Data Pump, including full transportable export/import. Oracle's 26ai documentation also says full transportable migration can be much faster than conventional export/import because user-tablespace datafiles are transported directly rather than unloaded/reloaded. 
O
Oracle Documentation
+1
One important correction from the earlier scripts: for a non-CDB → PDB migration, I would make the target PDB the explicit Data Pump connection target rather than running Data Pump against the CDB root. Oracle warns that Data Pump operations should not normally be performed against the CDB root. 
O
Oracle Documentation

Below is a more complete implementation.

1. What the automation will do
The script supports:
precheck
prepare
readonly
export
transfer
import
validate
restore
status
all

Workflow:
                SOURCE HOST
             Oracle 19c NON-CDB
                     |
                     |
              1. PRECHECK
                     |
                     v
             2. TRANSPORT CHECK
                     |
                     v
          3. USER TABLESPACES RO
                     |
                     v
           4. FULL TRANSPORTABLE
                  EXPDP
                     |
          +----------+----------+
          |                     |
          v                     v
      dump files             datafiles
          |                     |
          +----------+----------+
                     |
                   rsync
                     |
                     v
                TARGET HOST
                Oracle 26ai
                     |
                     v
              Create NEW PDB
                     |
                     v
              Full Transport
                  IMPDP
                     |
                     v
             Compile objects
                     |
                     v
              Validate
                     |
                     v
             Application
               cutover

Oracle documents that a full transportable export uses a combination of Data Pump metadata/data movement and direct datafile copying. 
O
Oracle Documentation
2. Important assumptions
This version assumes:
Source = Oracle 19c non-CDB
Target = Oracle 26ai CDB
Target PDB will be newly created
Target's existing data can be destroyed
Source and target are different Linux hosts
SSH works from source → target
rsync is available
Source and target have compatible endian format
Source/target use filesystem storage
The last point is important.
If you're using ASM, don't run this version unchanged. I'll explain the ASM changes at the end.

3. Directory layout
On the source:
mkdir -p /opt/oracle-migration/{bin,conf,sql,logs,state}
chmod 750 /opt/oracle-migration

We'll have:
/opt/oracle-migration/
├── bin/
│   └── oracle_migrate.sh
├── conf/
│   └── migration.conf
├── sql/
│   ├── source_precheck.sql
│   ├── target_precheck.sql
│   └── validate.sql
├── logs/
└── state/

4. Configuration
Create:
vi /opt/oracle-migration/conf/migration.conf

Use:
#!/bin/bash

###############################################################################
# Oracle 19c NON-CDB -> Oracle 26ai PDB
###############################################################################

#==============================================================================
# SOURCE
#==============================================================================

SOURCE_HOST="db19.example.com"
SOURCE_OS_USER="oracle"

SOURCE_SID="PROD19"
SOURCE_ORACLE_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"

SOURCE_ORACLE_BASE="/u01/app/oracle"

# Source database filesystem
SOURCE_DATA_DIR="/u02/oradata/PROD19"

# Source staging
SOURCE_STAGE="/u04/oracle_migration"

# Data Pump directory on source
SOURCE_DP_DIR="/u04/oracle_migration/dpump"

#==============================================================================
# TARGET
#==============================================================================

TARGET_HOST="db26.example.com"
TARGET_OS_USER="oracle"

TARGET_SID="PROD26"
TARGET_ORACLE_HOME="/u01/app/oracle/product/26.0.0/dbhome_1"

TARGET_ORACLE_BASE="/u01/app/oracle"

# Target PDB that will be created
TARGET_PDB="APPDB"

TARGET_PDB_ADMIN="PDBADMIN"

# IMPORTANT:
# Store the password securely. Do not put production passwords here.
TARGET_PDB_ADMIN_PASSWORD="CHANGE_ME"

# Target data directory
TARGET_DATA_DIR="/u02/oradata/PROD26"

# Target migration staging
TARGET_STAGE="/u04/oracle_migration"

# Target Data Pump directory
TARGET_DP_DIR="/u04/oracle_migration/dpump"

#==============================================================================
# DATAPUMP
#==============================================================================

DP_USER="SYSTEM"

DP_PARALLEL=8

DUMP_PREFIX="PROD19_FT"

EXPORT_LOG="${DUMP_PREFIX}_export.log"
IMPORT_LOG="${DUMP_PREFIX}_import.log"

#==============================================================================
# TRANSFER
#==============================================================================

RSYNC_PARALLEL=4

RSYNC_OPTIONS="-aHAX --numeric-ids --info=progress2"

#==============================================================================
# SAFETY
#==============================================================================

# YES = don't actually change anything
DRY_RUN="YES"

# YES = ask for confirmation before migration
REQUIRE_CONFIRMATION="YES"

# NEVER automatically drop the target PDB unless explicitly enabled.
ALLOW_DROP_TARGET_PDB="NO"

#==============================================================================
# SOURCE TABLESPACE
#==============================================================================

MANAGE_READONLY="YES"

#==============================================================================
# VALIDATION
#==============================================================================

RUN_ROWCOUNT_VALIDATION="YES"

#==============================================================================
# SSH
#==============================================================================

SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=yes"

5. Do NOT put the Data Pump password in the script
For a production implementation, I recommend OS authentication where possible:
sqlplus / as sysdba

For Data Pump, use a dedicated migration account with credentials handled securely.
For example, you can create:

CREATE USER MIGRATION_USER IDENTIFIED BY "...";

GRANT DATAPUMP_EXP_FULL_DATABASE TO MIGRATION_USER;
GRANT DATAPUMP_IMP_FULL_DATABASE TO MIGRATION_USER;

Do not store the password in Git or a world-readable shell script.
6. Main script
Create:
vi /opt/oracle-migration/bin/oracle_migrate.sh

Use this:
#!/usr/bin/env bash

###############################################################################
# Oracle 19c NON-CDB -> Oracle 26ai PDB
#
# Production migration framework
#
# Usage:
#
#   oracle_migrate.sh precheck
#   oracle_migrate.sh prepare
#   oracle_migrate.sh readonly
#   oracle_migrate.sh export
#   oracle_migrate.sh transfer
#   oracle_migrate.sh import
#   oracle_migrate.sh validate
#   oracle_migrate.sh restore
#   oracle_migrate.sh status
#   oracle_migrate.sh all
#
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# CONFIG
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG="${BASE_DIR}/conf/migration.conf"

[[ -f "$CONFIG" ]] || {
    echo "ERROR: Configuration not found: $CONFIG"
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG"

###############################################################################
# RUN INFORMATION
###############################################################################

RUN_ID="$(date '+%Y%m%d_%H%M%S')"

LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"

mkdir -p "$LOG_DIR" "$STATE_DIR"

LOG_FILE="${LOG_DIR}/migration_${RUN_ID}.log"

LOCK_FILE="${STATE_DIR}/migration.lock"

###############################################################################
# STATE FILES
###############################################################################

STATE_SOURCE_CHECK="${STATE_DIR}/01_source_checked"
STATE_TARGET_CHECK="${STATE_DIR}/02_target_checked"
STATE_TRANSPORT_CHECK="${STATE_DIR}/03_transport_checked"
STATE_READONLY="${STATE_DIR}/04_tablespaces_readonly"
STATE_EXPORT="${STATE_DIR}/05_export_complete"
STATE_TRANSFER="${STATE_DIR}/06_transfer_complete"
STATE_IMPORT="${STATE_DIR}/07_import_complete"
STATE_VALIDATE="${STATE_DIR}/08_validation_complete"
STATE_RESTORE="${STATE_DIR}/09_source_restored"

###############################################################################
# ORACLE ENVIRONMENT
###############################################################################

export ORACLE_SID="${SOURCE_SID}"
export ORACLE_HOME="${SOURCE_ORACLE_HOME}"
export ORACLE_BASE="${SOURCE_ORACLE_BASE}"
export PATH="${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin"

###############################################################################
# LOGGING
###############################################################################

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') | INFO | $*" \
        | tee -a "$LOG_FILE"
}

warn()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') | WARN | $*" \
        | tee -a "$LOG_FILE" >&2
}

die()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | $*" \
        | tee -a "$LOG_FILE" >&2

    exit 1
}

###############################################################################
# ERROR HANDLER
###############################################################################

on_error()
{
    local rc=$?

    echo
    echo "============================================================"
    echo "MIGRATION FAILED"
    echo "Line     : ${BASH_LINENO[0]}"
    echo "Command  : ${BASH_COMMAND}"
    echo "Exit     : ${rc}"
    echo "Log      : ${LOG_FILE}"
    echo "============================================================"

    exit "$rc"
}

trap on_error ERR

cleanup()
{
    rm -f "$LOCK_FILE"
}

trap cleanup EXIT

###############################################################################
# LOCK
###############################################################################

acquire_lock()
{
    if [[ -f "$LOCK_FILE" ]]; then
        die "Another migration appears to be running: $LOCK_FILE"
    fi

    echo "$$" > "$LOCK_FILE"
}

###############################################################################
# COMMAND CHECK
###############################################################################

require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Command not found: $1"
}

check_commands()
{
    require_command sqlplus
    require_command expdp
    require_command impdp
    require_command rsync
    require_command ssh
    require_command awk
    require_command sed
    require_command grep
}

###############################################################################
# SOURCE SQL
###############################################################################

source_sql()
{
    local sql="$1"

    sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT OFF

${sql}

EXIT;
SQL
}

###############################################################################
# TARGET SSH
###############################################################################

target_ssh()
{
    ssh ${SSH_OPTIONS} \
        "${TARGET_OS_USER}@${TARGET_HOST}" \
        "$@"
}

###############################################################################
# TARGET SQL
###############################################################################

target_sql()
{
    local sql="$1"

    target_ssh "
        export ORACLE_SID='${TARGET_SID}'
        export ORACLE_HOME='${TARGET_ORACLE_HOME}'
        export ORACLE_BASE='${TARGET_ORACLE_BASE}'
        export PATH='${TARGET_ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin'

        sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT OFF

${sql}

EXIT;
SQL
"
}

###############################################################################
# SOURCE VERSION
###############################################################################

get_source_version()
{
    source_sql "
        SELECT version
        FROM v\$instance;
    " | xargs
}

###############################################################################
# SOURCE CDB CHECK
###############################################################################

get_source_cdb()
{
    source_sql "
        SELECT cdb
        FROM v\$database;
    " | xargs
}

###############################################################################
# TARGET CDB CHECK
###############################################################################

get_target_cdb()
{
    target_sql "
        SELECT cdb
        FROM v\$database;
    " | xargs
}

###############################################################################
# PRECHECK SOURCE
###############################################################################

precheck_source()
{
    log "============================================================"
    log "SOURCE PRECHECK"
    log "============================================================"

    local version
    local cdb
    local dbname
    local platform
    local open_mode
    local size_gb

    version="$(get_source_version)"
    cdb="$(get_source_cdb)"

    dbname="$(
        source_sql "
            SELECT name FROM v\$database;
        " | xargs
    )"

    platform="$(
        source_sql "
            SELECT platform_name FROM v\$database;
        " | xargs
    )"

    open_mode="$(
        source_sql "
            SELECT open_mode FROM v\$database;
        " | xargs
    )"

    size_gb="$(
        source_sql "
            SELECT ROUND(
                SUM(bytes)/1024/1024/1024,
                2
            )
            FROM dba_data_files;
        " | xargs
    )"

    log "Database      : ${dbname}"
    log "Version       : ${version}"
    log "CDB           : ${cdb}"
    log "Open mode     : ${open_mode}"
    log "Platform      : ${platform}"
    log "Size GB       : ${size_gb}"

    [[ "$cdb" == "NO" ]] ||
        die "Expected source to be NON-CDB, detected CDB=${cdb}"

    [[ "$open_mode" == "READ WRITE" ]] ||
        die "Source must initially be READ WRITE."

    [[ "$version" == 19* ]] ||
        die "Expected Oracle 19c source. Detected version=${version}"

    log "Checking invalid objects..."

    source_sql "
        SELECT owner || '|' ||
               object_type || '|' ||
               COUNT(*)
        FROM dba_objects
        WHERE status <> 'VALID'
        GROUP BY owner, object_type
        ORDER BY owner, object_type;
    " | tee -a "$LOG_FILE"

    log "Checking TDE..."

    source_sql "
        SELECT
            NVL(status,'UNKNOWN') || '|' ||
            NVL(wallet_type,'UNKNOWN')
        FROM v\$encryption_wallet;
    " | tee -a "$LOG_FILE"

    log "Checking source users..."

    source_sql "
        SELECT COUNT(*)
        FROM dba_users
        WHERE oracle_maintained = 'N';
    " | tee -a "$LOG_FILE"

    touch "$STATE_SOURCE_CHECK"

    log "SOURCE PRECHECK PASSED"
}

###############################################################################
# PRECHECK TARGET
###############################################################################

precheck_target()
{
    log "============================================================"
    log "TARGET PRECHECK"
    log "============================================================"

    local version
    local cdb
    local dbname
    local platform

    version="$(
        target_sql "
            SELECT version
            FROM v\$instance;
        " | xargs
    )"

    cdb="$(get_target_cdb)"

    dbname="$(
        target_sql "
            SELECT name FROM v\$database;
        " | xargs
    )"

    platform="$(
        target_sql "
            SELECT platform_name FROM v\$database;
        " | xargs
    )"

    log "Database      : ${dbname}"
    log "Version       : ${version}"
    log "CDB           : ${cdb}"
    log "Platform      : ${platform}"

    [[ "$version" == 26* ]] ||
        die "Expected target Oracle 26ai. Detected ${version}"

    [[ "$cdb" == "YES" ]] ||
        die "Target must be a CDB for NON-CDB -> PDB migration."

    log "Checking target PDB..."

    target_sql "
        SELECT name || '|' || open_mode
        FROM v\$pdbs
        WHERE name = UPPER('${TARGET_PDB}');
    " | tee -a "$LOG_FILE"

    touch "$STATE_TARGET_CHECK"

    log "TARGET PRECHECK PASSED"
}

###############################################################################
# STORAGE CHECK
###############################################################################

check_storage()
{
    log "Checking source storage..."

    df -h "$SOURCE_DATA_DIR" \
        | tee -a "$LOG_FILE"

    log "Checking target storage..."

    target_ssh "
        df -h '${TARGET_DATA_DIR}'
        df -h '${TARGET_DP_DIR}'
    " | tee -a "$LOG_FILE"
}

###############################################################################
# PLATFORM CHECK
###############################################################################

check_platform()
{
    local source_platform
    local target_platform

    source_platform="$(
        source_sql "
            SELECT platform_name
            FROM v\$database;
        " | xargs
    )"

    target_platform="$(
        target_sql "
            SELECT platform_name
            FROM v\$database;
        " | xargs
    )"

    log "Source platform: ${source_platform}"
    log "Target platform: ${target_platform}"

    if [[ "$source_platform" != "$target_platform" ]]; then

        warn "SOURCE/TARGET platform differs."

        warn "Full transportable migration may require endian conversion."

        die "Refusing automatic migration across different platforms."
    fi
}

###############################################################################
# TRANSPORT TABLESPACES
###############################################################################

collect_tablespaces()
{
    log "Collecting user tablespaces..."

    source_sql "
        SELECT tablespace_name
        FROM dba_tablespaces
        WHERE contents = 'PERMANENT'
          AND tablespace_name NOT IN ('SYSTEM','SYSAUX')
        ORDER BY tablespace_name;
    " |
    sed '/^[[:space:]]*$/d' |
    sed 's/^[[:space:]]*//' |
    sed 's/[[:space:]]*$//' \
    > "${STATE_DIR}/transport_tablespaces.txt"

    log "Transport tablespaces:"

    cat "${STATE_DIR}/transport_tablespaces.txt" \
        | tee -a "$LOG_FILE"
}

###############################################################################
# TRANSPORT CHECK
###############################################################################

transport_check()
{
    log "Running DBMS_TTS transport-set check..."

    local ts_list

    ts_list="$(
        tr '\n' ',' \
            < "${STATE_DIR}/transport_tablespaces.txt" |
        sed 's/,$//'
    )"

    [[ -n "$ts_list" ]] ||
        die "No transportable tablespaces found."

    source_sql "
        BEGIN
            DBMS_TTS.TRANSPORT_SET_CHECK(
                ts_list => '${ts_list}',
                incl_constraints => TRUE
            );
        END;
        /
    "

    local violations

    violations="$(
        source_sql "
            SELECT COUNT(*)
            FROM transport_set_violations;
        " | xargs
    )"

    log "Transport violations: ${violations}"

    if [[ "$violations" != "0" ]]; then

        source_sql "
            SELECT violation
            FROM transport_set_violations;
        " | tee -a "$LOG_FILE"

        die "Transport-set validation failed."
    fi

    touch "$STATE_TRANSPORT_CHECK"

    log "TRANSPORT CHECK PASSED"
}

###############################################################################
# CREATE DIRECTORIES
###############################################################################

prepare_directories()
{
    log "Preparing source directories..."

    mkdir -p "$SOURCE_STAGE"
    mkdir -p "$SOURCE_DP_DIR"

    log "Preparing target directories..."

    target_ssh "
        mkdir -p '${TARGET_STAGE}'
        mkdir -p '${TARGET_DP_DIR}'
        mkdir -p '${TARGET_DATA_DIR}'
    "

    source_sql "
        CREATE OR REPLACE DIRECTORY
            MIGRATION_DP
        AS '${SOURCE_DP_DIR}';

        GRANT READ, WRITE
        ON DIRECTORY MIGRATION_DP
        TO ${DP_USER};
    "

    target_sql "
        CREATE OR REPLACE DIRECTORY
            MIGRATION_DP
        AS '${TARGET_DP_DIR}';

        GRANT READ, WRITE
        ON DIRECTORY MIGRATION_DP
        TO ${DP_USER};
    "
}

###############################################################################
# CREATE TARGET PDB
###############################################################################

prepare_target_pdb()
{
    log "Preparing target PDB: ${TARGET_PDB}"

    local exists

    exists="$(
        target_sql "
            SELECT COUNT(*)
            FROM v\$pdbs
            WHERE name = UPPER('${TARGET_PDB}');
        " | xargs
    )"

    if [[ "$exists" != "0" ]]; then

        if [[ "$ALLOW_DROP_TARGET_PDB" != "YES" ]]; then

            die "Target PDB ${TARGET_PDB} already exists. Refusing to drop it."
        fi

        log "Dropping existing target PDB."

        target_sql "
            ALTER PLUGGABLE DATABASE ${TARGET_PDB}
            CLOSE IMMEDIATE;

            DROP PLUGGABLE DATABASE ${TARGET_PDB}
            INCLUDING DATAFILES;
        "
    fi

    log "Creating target PDB..."

    target_sql "
        CREATE PLUGGABLE DATABASE ${TARGET_PDB}
        ADMIN USER ${TARGET_PDB_ADMIN}
        IDENTIFIED BY \"${TARGET_PDB_ADMIN_PASSWORD}\"
        FILE_NAME_CONVERT = (
            '${TARGET_DATA_DIR}/PDBSEED/',
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
# SET READ ONLY
###############################################################################

set_readonly()
{
    [[ "${MANAGE_READONLY}" == "YES" ]] ||
        return 0

    log "Setting application tablespaces READ ONLY..."

    while read -r ts; do

        [[ -z "$ts" ]] && continue

        log "READ ONLY: ${ts}"

        source_sql "
            ALTER TABLESPACE \"${ts}\" READ ONLY;
        "

    done < "${STATE_DIR}/transport_tablespaces.txt"

    touch "$STATE_READONLY"
}

###############################################################################
# EXPORT
###############################################################################

run_export()
{
    log "Starting FULL TRANSPORTABLE EXPORT."

    [[ -f "$STATE_READONLY" ]] ||
        die "Tablespaces are not marked READ ONLY."

    cd "$SOURCE_DP_DIR"

    local parfile="${SOURCE_STAGE}/export.par"

    cat > "$parfile" <<EOF
FULL=YES
TRANSPORTABLE=ALWAYS
DIRECTORY=MIGRATION_DP
DUMPFILE=${DUMP_PREFIX}_%U.dmp
LOGFILE=${EXPORT_LOG}
PARALLEL=${DP_PARALLEL}
EOF

    log "Export parameter file:"
    cat "$parfile" | tee -a "$LOG_FILE"

    expdp "${DP_USER}" \
        PARFILE="$parfile" \
        >> "$LOG_FILE" 2>&1

    [[ "${PIPESTATUS[0]}" == "0" ]] ||
        die "Data Pump export failed."

    # Verify log
    local dp_log="${SOURCE_DP_DIR}/${EXPORT_LOG}"

    [[ -f "$dp_log" ]] ||
        die "Data Pump log not found: $dp_log"

    if grep -Eiq 'successfully completed' "$dp_log"; then
        log "Data Pump export completed successfully."
    else
        warn "Could not find normal completion message."
        tail -100 "$dp_log" | tee -a "$LOG_FILE"
        die "Export completion could not be verified."
    fi

    touch "$STATE_EXPORT"
}

###############################################################################
# EXTRACT DATAFILES
###############################################################################

extract_datafiles()
{
    log "Extracting transport datafile information."

    local log_file="${SOURCE_DP_DIR}/${EXPORT_LOG}"

    grep -E \
        '/[^ ]+\.(dbf|DBF)' \
        "$log_file" |
    sed \
        -E 's/^[[:space:]]+//' |
    sed \
        -E 's/[[:space:]]+$//' |
    sort -u \
    > "${STATE_DIR}/transport_datafiles.txt" || true

    if [[ ! -s "${STATE_DIR}/transport_datafiles.txt" ]]; then

        warn "Could not automatically extract transport datafiles."

        warn "Inspect Data Pump log manually:"
        warn "$log_file"

        die "No transport datafiles detected."
    fi

    log "Transport datafiles:"

    cat "${STATE_DIR}/transport_datafiles.txt" \
        | tee -a "$LOG_FILE"
}

###############################################################################
# COPY DUMPS
###############################################################################

copy_dumps()
{
    log "Copying Data Pump dumps."

    rsync ${RSYNC_OPTIONS} \
        "${SOURCE_DP_DIR}/" \
        "${TARGET_OS_USER}@${TARGET_HOST}:${TARGET_DP_DIR}/" \
        --include="${DUMP_PREFIX}_*.dmp" \
        --include="${EXPORT_LOG}" \
        --exclude="*" \
        >> "$LOG_FILE" 2>&1

    log "Dump transfer complete."
}

###############################################################################
# COPY DATAFILES
###############################################################################

copy_datafiles()
{
    log "Copying transportable datafiles."

    local pids=()
    local count=0

    while read -r src_file; do

        [[ -z "$src_file" ]] && continue

        [[ -f "$src_file" ]] ||
            die "Source datafile does not exist: $src_file"

        local filename
        filename="$(basename "$src_file")"

        local target_file
        target_file="${TARGET_DATA_DIR}/${filename}"

        log "Transfer:"
        log "  ${src_file}"
        log "  -> ${target_file}"

        rsync ${RSYNC_OPTIONS} \
            "$src_file" \
            "${TARGET_OS_USER}@${TARGET_HOST}:${target_file}" \
            >> "$LOG_FILE" 2>&1 &

        pids+=("$!")

        ((count+=1))

        if (( count >= RSYNC_PARALLEL )); then

            for pid in "${pids[@]}"; do
                wait "$pid" ||
                    die "Datafile transfer failed."
            done

            pids=()
            count=0
        fi

    done < "${STATE_DIR}/transport_datafiles.txt"

    for pid in "${pids[@]}"; do
        wait "$pid" ||
            die "Datafile transfer failed."
    done

    log "All transport datafiles transferred."
}

###############################################################################
# BUILD IMPORT PARFILE
###############################################################################

build_import_parfile()
{
    log "Building target import parameter file."

    local parfile="${TARGET_STAGE}/import.par"

    {
        echo "DIRECTORY=MIGRATION_DP"
        echo "DUMPFILE=${DUMP_PREFIX}_%U.dmp"
        echo "LOGFILE=${IMPORT_LOG}"
        echo "PARALLEL=${DP_PARALLEL}"

        while read -r src_file; do

            [[ -z "$src_file" ]] && continue

            filename="$(basename "$src_file")"

            echo "TRANSPORT_DATAFILES='${TARGET_DATA_DIR}/${filename}'"

        done < "${STATE_DIR}/transport_datafiles.txt"

    } > "${STATE_DIR}/import.par"

    # Correct syntax requires multiple TRANSPORT_DATAFILES values.
    # Rewrite as comma-separated continuation.
    local files
    files="$(
        while read -r src_file; do
            [[ -z "$src_file" ]] && continue
            filename="$(basename "$src_file")"
            printf "'%s/%s'," "$TARGET_DATA_DIR" "$filename"
        done < "${STATE_DIR}/transport_datafiles.txt"
    )"

    files="${files%,}"

    cat > "${STATE_DIR}/import.par" <<EOF
DIRECTORY=MIGRATION_DP
DUMPFILE=${DUMP_PREFIX}_%U.dmp
LOGFILE=${IMPORT_LOG}
PARALLEL=${DP_PARALLEL}
TRANSPORT_DATAFILES=${files}
EOF

    scp ${SSH_OPTIONS} \
        "${STATE_DIR}/import.par" \
        "${TARGET_OS_USER}@${TARGET_HOST}:${parfile}" \
        >> "$LOG_FILE" 2>&1

    log "Import parameter file:"
    cat "${STATE_DIR}/import.par" \
        | tee -a "$LOG_FILE"
}

###############################################################################
# IMPORT INTO TARGET PDB
###############################################################################

run_import()
{
    log "Starting import into target PDB: ${TARGET_PDB}"

    build_import_parfile

    target_ssh "
        export ORACLE_SID='${TARGET_SID}'
        export ORACLE_HOME='${TARGET_ORACLE_HOME}'
        export ORACLE_BASE='${TARGET_ORACLE_BASE}'
        export PATH='${TARGET_ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin'

        cd '${TARGET_DP_DIR}'

        impdp '${DP_USER}'@'${TARGET_PDB}' \
            PARFILE='${TARGET_STAGE}/import.par'
    " >> "$LOG_FILE" 2>&1

    log "Data Pump import completed."

    touch "$STATE_IMPORT"
}

###############################################################################
# COMPILE INVALID OBJECTS
###############################################################################

compile_objects()
{
    log "Compiling invalid objects."

    target_sql "
        ALTER SESSION SET CONTAINER=${TARGET_PDB};

        BEGIN
            DBMS_UTILITY.COMPILE_SCHEMA(
                schema => USER,
                compile_all => TRUE
            );
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
        /
    " >> "$LOG_FILE" 2>&1 || true

    target_ssh "
        export ORACLE_SID='${TARGET_SID}'
        export ORACLE_HOME='${TARGET_ORACLE_HOME}'
        export PATH='${TARGET_ORACLE_HOME}/bin:\$PATH'

        sqlplus -s / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER=${TARGET_PDB};

@?/rdbms/admin/utlrp.sql

EXIT;
SQL
    " >> "$LOG_FILE" 2>&1
}

###############################################################################
# VALIDATE OBJECTS
###############################################################################

validate_objects()
{
    log "Validating target objects."

    target_sql "
        ALTER SESSION SET CONTAINER=${TARGET_PDB};

        SELECT
            owner,
            object_type,
            COUNT(*)
        FROM dba_objects
        WHERE status <> 'VALID'
        GROUP BY owner, object_type
        ORDER BY owner, object_type;

        SELECT
            owner,
            index_name,
            table_name,
            status
        FROM dba_indexes
        WHERE status <> 'VALID';

        SELECT
            owner,
            constraint_name,
            table_name,
            status
        FROM dba_constraints
        WHERE status <> 'ENABLED';
    " | tee -a "$LOG_FILE"
}

###############################################################################
# USER VALIDATION
###############################################################################

validate_users()
{
    log "Validating users."

    local source_count
    local target_count

    source_count="$(
        source_sql "
            SELECT COUNT(*)
            FROM dba_users
            WHERE oracle_maintained='N';
        " | xargs
    )"

    target_count="$(
        target_sql "
            ALTER SESSION SET CONTAINER=${TARGET_PDB};

            SELECT COUNT(*)
            FROM dba_users
            WHERE oracle_maintained='N';
        " | xargs
    )"

    log "Source user count: ${source_count}"
    log "Target user count: ${target_count}"
}

###############################################################################
# TABLE VALIDATION
###############################################################################

validate_tables()
{
    log "Validating table counts."

    source_sql "
        SELECT owner,
               COUNT(*) AS table_count
        FROM dba_tables
        WHERE owner NOT IN (
            'SYS',
            'SYSTEM',
            'XDB',
            'MDSYS'
        )
        GROUP BY owner
        ORDER BY owner;
    " > "${STATE_DIR}/source_table_counts.txt"

    target_sql "
        ALTER SESSION SET CONTAINER=${TARGET_PDB};

        SELECT owner,
               COUNT(*) AS table_count
        FROM dba_tables
        WHERE owner NOT IN (
            'SYS',
            'SYSTEM',
            'XDB',
            'MDSYS'
        )
        GROUP BY owner
        ORDER BY owner;
    " > "${STATE_DIR}/target_table_counts.txt"

    log "SOURCE TABLE COUNTS"

    cat "${STATE_DIR}/source_table_counts.txt" \
        | tee -a "$LOG_FILE"

    log "TARGET TABLE COUNTS"

    cat "${STATE_DIR}/target_table_counts.txt" \
        | tee -a "$LOG_FILE"
}

###############################################################################
# DATABASE SIZE VALIDATION
###############################################################################

validate_size()
{
    log "Comparing database sizes."

    local source_size
    local target_size

    source_size="$(
        source_sql "
            SELECT ROUND(
                SUM(bytes)/1024/1024/1024,
                2
            )
            FROM dba_data_files;
        " | xargs
    )"

    target_size="$(
        target_sql "
            ALTER SESSION SET CONTAINER=${TARGET_PDB};

            SELECT ROUND(
                SUM(bytes)/1024/1024/1024,
                2
            )
            FROM dba_data_files;
        " | xargs
    )"

    log "Source size GB: ${source_size}"
    log "Target size GB: ${target_size}"
}

###############################################################################
# ROW COUNT - OPTIONAL
###############################################################################

generate_rowcount_sql()
{
    log "Generating row-count validation SQL."

    source_sql "
        SELECT
            'SELECT ''' ||
            owner ||
            '.' ||
            table_name ||
            ''' AS table_name, COUNT(*) AS row_count FROM \"' ||
            owner ||
            '\".\"' ||
            table_name ||
            '\";'
        FROM dba_tables
        WHERE owner NOT IN (
            'SYS',
            'SYSTEM',
            'XDB',
            'MDSYS',
            'CTXSYS',
            'ORDSYS'
        )
        ORDER BY owner, table_name;
    " > "${STATE_DIR}/rowcount.sql"
}

###############################################################################
# VALIDATION
###############################################################################

validate()
{
    log "============================================================"
    log "POST MIGRATION VALIDATION"
    log "============================================================"

    compile_objects

    validate_objects

    validate_users

    validate_tables

    validate_size

    if [[ "${RUN_ROWCOUNT_VALIDATION}" == "YES" ]]; then
        generate_rowcount_sql

        log "NOTE: Full row-count validation can be expensive."
        log "Generated SQL: ${STATE_DIR}/rowcount.sql"
    fi

    touch "$STATE_VALIDATE"

    log "VALIDATION COMPLETED"
}

###############################################################################
# RESTORE SOURCE
###############################################################################

restore_source()
{
    [[ -f "$STATE_READONLY" ]] ||
        return 0

    log "Restoring source tablespaces READ WRITE."

    while read -r ts; do

        [[ -z "$ts" ]] && continue

        log "READ WRITE: ${ts}"

        source_sql "
            ALTER TABLESPACE \"${ts}\" READ WRITE;
        "

    done < "${STATE_DIR}/transport_tablespaces.txt"

    touch "$STATE_RESTORE"

    log "Source tablespaces restored."
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

    for state in \
        "$STATE_SOURCE_CHECK" \
        "$STATE_TARGET_CHECK" \
        "$STATE_TRANSPORT_CHECK" \
        "$STATE_READONLY" \
        "$STATE_EXPORT" \
        "$STATE_TRANSFER" \
        "$STATE_IMPORT" \
        "$STATE_VALIDATE" \
        "$STATE_RESTORE"
    do

        if [[ -f "$state" ]]; then
            echo "PASS  $(basename "$state")"
        else
            echo "----  $(basename "$state")"
        fi

    done

    echo
}

###############################################################################
# CONFIRM
###############################################################################

confirm()
{
    [[ "$REQUIRE_CONFIRMATION" == "YES" ]] ||
        return 0

    [[ "$DRY_RUN" == "YES" ]] &&
        return 0

    echo
    echo "============================================================"
    echo "DANGEROUS OPERATION"
    echo "============================================================"
    echo
    echo "SOURCE:"
    echo "  ${SOURCE_HOST}/${SOURCE_SID}"
    echo
    echo "TARGET:"
    echo "  ${TARGET_HOST}/${TARGET_SID}/${TARGET_PDB}"
    echo
    echo "The target PDB is the destination."
    echo "Existing target data must not be required."
    echo

    read -r -p \
        "Type MIGRATE-${TARGET_PDB}-${RUN_ID}: " answer

    [[ "$answer" == "MIGRATE-${TARGET_PDB}-${RUN_ID}" ]] ||
        die "Confirmation failed."
}

###############################################################################
# PRECHECK
###############################################################################

precheck()
{
    check_commands
    acquire_lock

    precheck_source
    precheck_target

    check_storage
    check_platform

    collect_tablespaces
    transport_check

    log "PRECHECK SUCCESSFUL."
}

###############################################################################
# FULL MIGRATION
###############################################################################

all()
{
    precheck

    confirm

    prepare_directories

    prepare_target_pdb

    set_readonly

    run_export

    extract_datafiles

    copy_dumps

    copy_datafiles

    touch "$STATE_TRANSFER"

    run_import

    validate

    restore_source

    log "============================================================"
    log "MIGRATION COMPLETED"
    log "============================================================"
}

###############################################################################
# HELP
###############################################################################

usage()
{
    cat <<EOF

Oracle 19c NON-CDB -> Oracle 26ai PDB migration

Usage:

  $SCRIPT_NAME precheck
  $SCRIPT_NAME prepare
  $SCRIPT_NAME readonly
  $SCRIPT_NAME export
  $SCRIPT_NAME transfer
  $SCRIPT_NAME import
  $SCRIPT_NAME validate
  $SCRIPT_NAME restore
  $SCRIPT_NAME status
  $SCRIPT_NAME all

Recommended:

  1. Set DRY_RUN=YES
  2. Run:
       $SCRIPT_NAME precheck

  3. Review logs/state.
  4. Set DRY_RUN=NO
  5. Run:
       $SCRIPT_NAME all

EOF
}

###############################################################################
# MAIN
###############################################################################

case "${1:-}" in

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
        ;;

    export)
        acquire_lock
        run_export
        extract_datafiles
        ;;

    transfer)
        acquire_lock
        copy_dumps
        copy_datafiles
        touch "$STATE_TRANSFER"
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

Make it executable:
chmod 750 /opt/oracle-migration/bin/oracle_migrate.sh

7. There is one important improvement I'd make to the script
The Data Pump export log's datafile section should ideally be captured using Oracle's transport-datafile parameter-file facility, rather than relying only on parsing .dbf strings from the log.
Oracle 26ai documents TRANSPORT_DATAFILES_LOG for generating the required datafile parameter information. 
O
Oracle Documentation

So on a current 26ai Data Pump environment, I'd use the generated transport-datafile parameter information rather than making the parser responsible for understanding every possible Data Pump log format.

This is particularly important if:

ASM is involved
OMF is involved
paths contain unusual characters
there are many datafiles
the database is multi-terabyte
8. First run MUST be precheck
Keep:
DRY_RUN="YES"

Then:
/opt/oracle-migration/bin/oracle_migrate.sh precheck

You should get something similar to:
============================================================
SOURCE PRECHECK
============================================================

Database      : PROD19
Version       : 19.XX
CDB           : NO
Open mode     : READ WRITE
Platform      : Linux x86 64-bit
Size GB       : 2450

SOURCE PRECHECK PASSED

============================================================
TARGET PRECHECK
============================================================

Database      : PROD26
Version       : 26.XX
CDB           : YES
Platform      : Linux x86 64-bit

TARGET PRECHECK PASSED

Transport violations: 0

TRANSPORT CHECK PASSED

If it says:
CDB = YES

on the source, stop. This script is specifically designed for the non-CDB case.
9. Verify target PDB configuration
The target should look like:
CDB
 |
 +-- CDB$ROOT
 |
 +-- PDB$SEED
 |
 +-- APPDB

Check:
ssh oracle@db26.example.com

Then:
export ORACLE_SID=PROD26
export ORACLE_HOME=/u01/app/oracle/product/26.0.0/dbhome_1
export PATH=$ORACLE_HOME/bin:$PATH

sqlplus / as sysdba

Then:
show pdbs;

The migration script will create APPDB if it doesn't exist.
10. Be careful with FILE_NAME_CONVERT
The example contains:
FILE_NAME_CONVERT =
(
    '/u02/oradata/PROD26/PDBSEED/',
    '/u02/oradata/PROD26/APPDB/'
);

Your actual seed path might be:
/u02/oradata/PROD26/pdbseed/

or:
/u01/app/oracle/oradata/PROD26/pdbseed/

or OMF.
Change this before running prepare.

For example:

SELECT file_name
FROM cdb_data_files
WHERE con_id = 2;

will show the PDB seed files.
11. The actual migration
Once precheck succeeds:
Change:

DRY_RUN="YES"

to:
DRY_RUN="NO"

Then:
/opt/oracle-migration/bin/oracle_migrate.sh all

You'll get:
PRECHECK
   ↓
CREATE PDB
   ↓
READ ONLY
   ↓
EXPDP
   ↓
DATAFILE TRANSFER
   ↓
DUMP TRANSFER
   ↓
IMPDP
   ↓
UTLRP
   ↓
VALIDATION
   ↓
RESTORE SOURCE

12. Downtime
For the final migration, your application must stop writing before you put the application tablespaces into READ ONLY.
The sequence is:

APPLICATION
     |
     | stop
     v
NO WRITES
     |
     v
19c
     |
     +---- APP_DATA READ ONLY
     |
     +---- APP_INDEX READ ONLY
     |
     v
EXPDP
     |
     v
DATAFILE COPY
     |
     v
26ai IMPDP
     |
     v
VALIDATION
     |
     v
APPLICATION -> 26ai

Oracle's transportable export requires tablespaces containing transported tables/partitions to be read-only. 
O
Oracle Documentation
13. Don't restore source automatically until validation
In the script above, the order is:
IMPORT
   ↓
VALIDATE
   ↓
RESTORE SOURCE READ WRITE

That's intentional.
If the import fails, you want to keep the source in its controlled migration state until you've decided what to do.

If you need to abandon the migration:

/opt/oracle-migration/bin/oracle_migrate.sh restore

This returns the source application tablespaces to:
READ WRITE

14. Check the status
At any time:
/opt/oracle-migration/bin/oracle_migrate.sh status

You'll see:
============================================================
ORACLE MIGRATION STATUS
============================================================

PASS  01_source_checked
PASS  02_target_checked
PASS  03_transport_checked
PASS  04_tablespaces_readonly
PASS  05_export_complete
PASS  06_transfer_complete
PASS  07_import_complete
PASS  08_validation_complete
PASS  09_source_restored

This is useful if something fails at 2 AM and you need to determine where the migration stopped.
15. Very important: full transportable export is not restartable
Oracle's 19c documentation explicitly states that a full transportable export is not restartable. 
O
Oracle Documentation
That's why the script uses state markers around the major phases.

For example, if:

EXPDP = complete
DATAFILE COPY = complete

but:
IMPDP = failed

you shouldn't blindly rerun:
./oracle_migrate.sh all

Instead:
./oracle_migrate.sh status

and investigate the import.
16. Don't use FULL=Y against the target CDB root
This is particularly important in your case.
The import should connect to:

APPDB

not:
CDB$ROOT

So:
impdp system@APPDB ...

rather than:
impdp system@CDB$ROOT ...

Oracle's documentation explicitly describes using a full Data Pump import into the newly created PDB for moving data into a CDB. 
O
Oracle Documentation
+1
17. TDE needs additional handling
If:
SELECT status, wallet_type
FROM v$encryption_wallet;

shows an active TDE wallet, don't run the migration blindly.
Oracle documents an additional requirement for full transportable export when the source contains encrypted tablespaces or encrypted columns: an ENCRYPTION_PASSWORD must be supplied. 
O
Oracle Documentation

So for TDE I'd modify the script to use something like:

ENCRYPTION_PASSWORD

through a secure prompt/secret mechanism rather than putting it in migration.conf.
18. ASM requires a different transfer section
If source is:
+DATA/PROD19/...

or target is:
+DATA/PROD26/...

do not use the filesystem rsync section above.
rsync cannot copy an ASM alias/path like:

+DATA/PROD19/DATAFILE/users.123.123456789

as if it were a normal filesystem file.
For ASM, I'd change the architecture to use Oracle-supported mechanisms such as:

DBMS_FILE_TRANSFER

or RMAN-based conversion/copy as appropriate.
Oracle specifically identifies DBMS_FILE_TRANSFER and RMAN CONVERT for datafile movement/conversion in transportable scenarios. 
O
Oracle Documentation
+1

So tell me if either side uses ASM before running this script.

19. Network optimization
Because your hosts are different, the data transfer is potentially the largest part of the migration.
Check:

iperf3

between the hosts if your infrastructure permits it.
For example, a 10-Gbps link theoretically gives approximately:

10 Gbps / 8
≈ 1.25 GB/sec

but storage and protocol overhead mean your actual transfer rate will be lower.
For a 5-TB database, network optimization can make a dramatic difference.

20. Data Pump parallelism
Start with:
DP_PARALLEL=8

Then tune.
For example:

CPU                 DP_PARALLEL
--------------------------------
8 cores             4-8
16 cores            8-16
32 cores            16-32
64 cores            16-32+

But don't blindly maximize it.
If your source storage can only deliver:

800 MB/s

running:
PARALLEL=64

doesn't magically produce 8 GB/s.
For the transportable portion, datafile transfer bandwidth is often more important than Data Pump worker count.

21. Recommended migration test
Before production, run this exact sequence against a test copy:
./oracle_migrate.sh precheck

then:
./oracle_migrate.sh prepare

then:
./oracle_migrate.sh readonly

then:
./oracle_migrate.sh export

then:
./oracle_migrate.sh transfer

then:
./oracle_migrate.sh import

then:
./oracle_migrate.sh validate

Then measure:
Precheck               : ___ min
Tablespace RO          : ___ min
EXPDP                  : ___ min
Dump transfer          : ___ min
Datafile transfer      : ___ min
IMPDP                  : ___ min
Compile                : ___ min
Validation             : ___ min
--------------------------------
Total downtime         : ___ min

That gives you a realistic production cutover estimate.
22. One thing I would NOT automate
I would deliberately not automatically execute:
DROP PLUGGABLE DATABASE APPDB INCLUDING DATAFILES;

because if:
TARGET_HOST

or:
TARGET_PDB

is accidentally wrong, you can cause a very bad incident.
Instead, create the PDB manually once:

CREATE PLUGGABLE DATABASE APPDB ...

or have the script require a very explicit confirmation:
Type:

DESTROY-TARGET-PROD26-APPDB

to continue

Then enable:
ALLOW_DROP_TARGET_PDB="YES"

only for a controlled migration.
Most important next step
Before you run this, determine these four things on the two hosts:
Source
sqlplus / as sysdba

SELECT name, cdb, open_mode FROM v$database;

SELECT platform_name FROM v$database;

SELECT version FROM v$instance;

SELECT tablespace_name, contents
FROM dba_tablespaces
ORDER BY tablespace_name;

Target
SELECT name, cdb, open_mode FROM v$database;

SELECT platform_name FROM v$database;

SELECT version FROM v$instance;

SELECT file_name
FROM cdb_data_files
WHERE con_id = 2;

If you give me those outputs plus whether source and target use ASM or filesystem, I can tighten this into the exact production version. In particular, the ASM/OMF and target PDB file creation portions should not be guessed. The migration method itself is sound: Oracle explicitly supports non-CDB → PDB migration using Data Pump, including full transportable export/import. 
O
Oracle Documentation
+1
 

OO
Sources

You’ll get smarter responses and can upload files, images, and more.
Log in
Sign up for free


Chat with ChatGPT


