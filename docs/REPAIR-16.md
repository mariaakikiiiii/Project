# Repair falsely recorded migrations 13 and 16

Use this guide only if version 16 is recorded but its location columns/manual-transfer tables are missing. The reported screenshot also lacked `Payments`, so the repair checks the commercial schema from version 13 too. A row in `PlatformMigrations` alone is not proof that all objects were installed.

## Steps in SSMS

1. Keep the GameOn API stopped. Back up the current GameOn database using your migration/Windows identity.
2. Download `database/16-repair-partial-install.sql` from the current repository. It is a new repair file, not the original `16-location-manual-whish.sql`.
3. In SSMS use **File → Open → File** to open the downloaded repair in a new query tab. Use your Windows migration/admin connection, not the restricted `gameon_api` application login.
4. Clear any text selection and press **F5** to execute the whole file. Ordinary SSMS mode works; **SQLCMD Mode is not required**. Do not remove version entries or run selected fragments.
5. Confirm the result says **Repair completed successfully. Migrations 13 and 16 schema restored.** The following results list the version rows, venue/payment columns and non-null IDs for all three manual-transfer tables.
6. Keep the application stopped and send the results before proceeding to migration 18. Use the newly corrected version 18 file from the current repository, not a previous ZIP's copy. That file now also works in ordinary SSMS mode.

## What it changes

The repair adds missing commercial/manual-transfer tables and columns, adds missing commercial indexes, validates/reinstates the known payment/coordinate constraints, and reinstalls the canonical version 13 procedures followed by the version 16 overrides and their named execute grants. Existing table data is not deleted, reset or replaced. Existing version rows and timestamps remain intact; missing version rows are inserted only after the schema has been restored.

All work runs inside one `TRY...CATCH` transaction. Fixed DDL strings execute in separate compilation scopes, so a constraint/procedure can see columns created by earlier statements. A failure rolls back the repair and cannot commit an additional version marker.

The repair refuses to run if migration 18 is recorded or known deposit columns/tables are already present. It also refuses a missing base version 9 schema or missing application role. It does not downgrade deposit features, grant table-write privileges to the application, verify transfers, alter invoices, enroll players or send money.

The old error had two causes: SQLCMD directives were executed in ordinary query mode, and the script referenced columns added earlier in the same compilation batch. Earlier advice to toggle SQLCMD Mode alone did not address the latter. The current version 16/18 files no longer depend on SQLCMD directives or multi-batch transaction continuation. `install-fresh.sql` still uses SQLCMD because it includes other files and is **not** for this existing database.

## Validation limits

The wrappers and their decoded constant DDL/module bodies are parsed with Microsoft ScriptDom. The source generator has deterministic output and keeps the original module bodies as non-executable templates under `scripts/migration-bodies`. SQL Server is unavailable in the development workspace, so the repair has not been engine-executed there. Back up first and review the success/error output; if any guard/error occurs, stop rather than deleting markers or retrying an older migration file.
