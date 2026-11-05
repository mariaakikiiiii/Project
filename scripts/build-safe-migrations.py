"""Build ordinary-SSMS migration wrappers from the checked-in migration bodies.
No user input is interpolated into SQL. Constant DDL is compiled separately at
execution time so columns added earlier in the transaction are visible.
"""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def statements(text):
    start=0; quoted=False; i=0
    while i<len(text):
        if text[i]=="'":
            if quoted and i+1<len(text) and text[i+1]=="'": i+=2;continue
            quoted=not quoted
        if text[i]==';' and not quoted:
            value=text[start:i+1].strip()
            if value: yield value
            start=i+1
        i+=1
    if text[start:].strip(): yield text[start:].strip()
def execute(sql): return " EXEC(N'"+sql.replace("'","''")+"');\n"
def parts(text):
    batches=re.split(r'^GO\s*$',text,flags=re.M|re.I)
    header=batches[0]
    if 'BEGIN TRANSACTION;' not in header:
        header=batches[1]; batches=batches[1:]
    ddl=header.split('BEGIN TRANSACTION;',1)[1].strip()
    ddl='\n'.join(line for line in ddl.splitlines() if not line.lstrip().startswith('--'))
    modules=[b.strip() for b in batches[1:] if re.search(r'^CREATE OR ALTER ',b,re.I|re.M)]
    expected=len(re.findall(r'^CREATE OR ALTER ',text,re.I|re.M))
    if len(modules)!=expected: raise ValueError(f'Module extraction lost definitions: {len(modules)} of {expected}')
    grants=re.findall(r'^GRANT EXECUTE ON .*?;',text,re.M)
    return list(statements(ddl)),modules,grants

def wrapper(version,prior,ddl,modules,grants):
    result=f'''-- Run the WHOLE file in a NEW SSMS query using your migration/Windows identity.
-- Ordinary SSMS mode works. No SQLCMD Mode or : commands are needed.
-- Back up GameOn and stop the API before applying this migration.
USE GameOn;
GO
IF @@TRANCOUNT<>0 THROW 50002,'Open a fresh query with no active transaction.',1;
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
BEGIN TRY
 BEGIN TRANSACTION;
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version={prior}) THROW 50002,'Install migration {prior} first.',1;
 IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version={version}) THROW 50002,'Migration {version} is already recorded. If a previous attempt failed, use its repair guide instead of rerunning it.',1;
'''
    if version==16:
        result+=" IF OBJECT_ID(N'dbo.Payments',N'U') IS NULL OR COL_LENGTH(N'dbo.Waitlists',N'AcceptedServiceFee') IS NULL THROW 50002,'Migration 13 schema is incomplete. Use 16-repair-partial-install.sql first.',1;\n"
    if version==18:
        result+=" IF OBJECT_ID(N'dbo.PaymentOperators',N'U') IS NULL OR COL_LENGTH(N'dbo.Venues',N'Latitude') IS NULL OR COL_LENGTH(N'dbo.Payments',N'RecipientNumber') IS NULL THROW 50002,'Migration 16 schema is incomplete. Use 16-repair-partial-install.sql first.',1;\n"
    for sql in ddl+modules+grants: result+=execute(sql)
    result+=f''' INSERT dbo.PlatformMigrations(Version) VALUES({version});
 COMMIT;
 SELECT 'Migration {version} completed successfully' AS Result;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
'''
    return result

# After the first conversion the original body lives in the source snapshot files.
# These snapshots are not independently executable migrations.
for version,name in [(16,'16-location-manual-whish'),(18,'18-security-deposits')]:
    target=ROOT/'database'/f'{name}.sql'
    snapshot=ROOT/'scripts'/'migration-bodies'/f'{name}.sql.txt'
    if not snapshot.exists():
        snapshot.parent.mkdir(exist_ok=True)
        snapshot.write_text(target.read_text())
    text=snapshot.read_text(); ddl,modules,grants=parts(text)
    target.write_text(wrapper(version,13 if version==16 else 16,ddl,modules,grants))

old=(ROOT/'database/13-commercial-layer.sql').read_text()
v16=(ROOT/'scripts/migration-bodies/16-location-manual-whish.sql.txt').read_text()
d13,m13,g13=parts(old); d16,m16,g16=parts(v16)
repair='''-- Repair incomplete migrations 13/16; preserve application data and existing version rows.
-- Stop the API, take a backup, then run this WHOLE file in a NEW SSMS query.
-- Ordinary SSMS mode works. Do not select a fragment. No SQLCMD Mode is required.
USE GameOn;
GO
IF @@TRANCOUNT<>0 THROW 50002,'Open a fresh query with no active transaction.',1;
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
BEGIN TRY
 BEGIN TRANSACTION;
 IF OBJECT_ID(N'dbo.PlatformMigrations',N'U') IS NULL THROW 50002,'The migration ledger is missing. Stop and check the database.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=9) THROW 50002,'Migration 9 is required before this repair.',1;
 IF EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=18)
  OR OBJECT_ID(N'dbo.DepositBookings',N'U') IS NOT NULL
  OR COL_LENGTH(N'dbo.GamesAndEvents',N'RequiresDeposit') IS NOT NULL
  OR COL_LENGTH(N'dbo.Payments',N'FeeRate') IS NOT NULL
  OR COL_LENGTH(N'dbo.Venues',N'ContactPhoneNumber') IS NOT NULL
  OR COL_LENGTH(N'dbo.Venues',N'IsVerified') IS NOT NULL
  OR COL_LENGTH(N'dbo.Participations',N'DepositStatus') IS NOT NULL
  OR COL_LENGTH(N'dbo.UserActivityLogs',N'DepositStatus') IS NOT NULL
  THROW 50002,'Migration 18 has been started or installed. Stop: this repair will not overwrite deposit features.',1;
 IF DATABASE_PRINCIPAL_ID(N'gameon_executor') IS NULL THROW 50002,'The application executor role is missing. Use the original GameOn database.',1;
 IF OBJECT_ID(N'dbo.GamesAndEvents',N'U') IS NULL OR OBJECT_ID(N'dbo.Subtypes',N'U') IS NULL
  OR OBJECT_ID(N'dbo.Categories',N'U') IS NULL OR OBJECT_ID(N'dbo.UserActivityLogs',N'U') IS NULL
  THROW 50002,'Migration 9 schema is incomplete. No repair changes have been committed.',1;
'''
# Recreate missing commercial and manual-transfer tables, without touching existing rows.
for sql in d13+d16:
    match=re.match(r'CREATE TABLE dbo\.(\w+)',sql,re.I)
    if match:
        name=match.group(1);repair+=f" IF OBJECT_ID(N'dbo.{name}',N'U') IS NULL\n"+execute(sql)
# Columns are added in their own compilation scopes before dependent constraints/modules.
columns=[('Venues','Latitude','decimal(10,7) NULL'),('Venues','Longitude','decimal(10,7) NULL'),('Venues','GooglePlaceId','nvarchar(255) NULL'),
 ('Payments','RecipientNumber','nvarchar(20) NULL'),('Payments','TransferReference','nvarchar(100) NULL'),('Payments','ReviewNote','nvarchar(400) NULL'),
 ('Waitlists','AcceptedServiceFee','bit NOT NULL CONSTRAINT DF_Waitlists_AcceptedFee DEFAULT 0'),
 ('Participations','PaymentMethod',"varchar(12) NOT NULL CONSTRAINT DF_Participations_Payment_Repair DEFAULT 'Cash'"),
 ('Waitlists','PaymentMethod',"varchar(12) NOT NULL CONSTRAINT DF_Waitlists_Payment_Repair DEFAULT 'Cash'")]
for table,column,definition in columns:
    repair+=f" IF COL_LENGTH(N'dbo.{table}',N'{column}') IS NULL\n"+execute(f'ALTER TABLE dbo.{table} ADD {column} {definition};')
# Replace only the known policy constraints; WITH CHECK rejects incompatible data atomically.
for table,constraint in [('Venues','CK_Venues_Coordinates'),('Payments','CK_Payments_Mode'),('Payments','CK_Payments_State'),('Participations','CK_Participations_Payment')]:
    repair+=f" IF EXISTS(SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'dbo.{table}') AND name=N'{constraint}')\n"+execute(f'ALTER TABLE dbo.{table} DROP CONSTRAINT {constraint};')
for sql in d16:
    if 'ADD CONSTRAINT CK_' in sql: repair+=execute(sql.replace(' ADD CONSTRAINT',' WITH CHECK ADD CONSTRAINT',1))
for sql in d13:
    match=re.match(r'CREATE (?:UNIQUE )?INDEX (\w+) ON dbo\.(\w+)',sql,re.I)
    if match:
        index,table=match.groups();repair+=f" IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.{table}') AND name=N'{index}')\n"+execute(sql)
# Restore canonical v13 procedures, then the v16 overrides. No v18 objects are touched.
for sql in m13+m16+list(dict.fromkeys(g13+g16)): repair+=execute(sql)
repair+=''' IF COL_LENGTH(N'dbo.Venues',N'Latitude') IS NULL OR COL_LENGTH(N'dbo.Venues',N'Longitude') IS NULL OR COL_LENGTH(N'dbo.Venues',N'GooglePlaceId') IS NULL
  OR OBJECT_ID(N'dbo.Payments',N'U') IS NULL OR OBJECT_ID(N'dbo.PaymentOperators',N'U') IS NULL
  OR OBJECT_ID(N'dbo.VerifiedWhishTransfers',N'U') IS NULL OR OBJECT_ID(N'dbo.PaymentReviews',N'U') IS NULL
  OR OBJECT_ID(N'dbo.GetVenueLocation',N'P') IS NULL
  THROW 50002,'Repair validation failed. No changes have been committed.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=13) INSERT dbo.PlatformMigrations(Version) VALUES(13);
 IF NOT EXISTS(SELECT 1 FROM dbo.PlatformMigrations WHERE Version=16) INSERT dbo.PlatformMigrations(Version) VALUES(16);
 COMMIT;
 SELECT 'Repair completed successfully. Migrations 13 and 16 schema restored.' AS Result;
 SELECT Version,AppliedAt FROM dbo.PlatformMigrations ORDER BY Version;
 SELECT OBJECT_NAME(object_id) AS TableName,name AS ColumnName FROM sys.columns
 WHERE object_id IN(OBJECT_ID(N'dbo.Venues'),OBJECT_ID(N'dbo.Payments')) ORDER BY TableName,column_id;
 SELECT OBJECT_ID(N'dbo.PaymentOperators',N'U') AS PaymentOperators,
  OBJECT_ID(N'dbo.VerifiedWhishTransfers',N'U') AS VerifiedWhishTransfers,
  OBJECT_ID(N'dbo.PaymentReviews',N'U') AS PaymentReviews;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
'''
(ROOT/'database/16-repair-partial-install.sql').write_text(repair)
