-- LAB/DEVELOPMENT ONLY. Run sqlcmd from the REPOSITORY ROOT, using a DBA identity:
-- sqlcmd -S localhost -E -b -i database/install-fresh.sql
-- Provision the dedicated gameon_api server login securely BEFORE running this.
-- Existing GameOn installations use the migration guide; this refuses replacement.
:ON ERROR EXIT
USE master;
GO
IF DB_ID(N'GameOn') IS NOT NULL THROW 50002,'GameOn already exists. Follow the migration guide; do not replace it.',1;
IF SUSER_ID(N'gameon_api') IS NULL THROW 50002,'Provision the gameon_api server login securely first.',1;
CREATE DATABASE GameOn;
GO
USE GameOn;
GO
:r database/01-schema.sql
:r database/02-procedures.sql
:r database/03-seed.sql
:r database/04-security.sql
:r database/07-platform-upgrade.sql
:r database/09-categories-and-events.sql
:r database/10-user-analytics-seed.sql
:r database/13-commercial-layer.sql
:r database/16-location-manual-whish.sql
PRINT 'GameOn lab database installed. Run 05, 08, 12, 15 and 17 tests on a disposable copy.';
GO
