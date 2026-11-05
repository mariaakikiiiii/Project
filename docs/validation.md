# Validation record

Executed in the cloud workspace on 2026-11-04:

- .NET SDK 8.0.427: `dotnet build --no-restore` passed with 0 warnings and 0 errors.
- React/Vite 6.4.5: `npm run build` passed (24 modules transformed).
- `npm audit --audit-level=high`: reported 0 known vulnerabilities across the installed frontend dependency graph.
- `dotnet list package --vulnerable --include-transitive`: reported no known vulnerable packages against its current feeds. An explicit System.Security.Cryptography.Pkcs 8.0.2 reference patches the older transitive dependency.
- API started at local HTTPS with its development certificate. `python3 scripts/security-smoke.py /tmp/gameon-dev.pem` passed: TLS certificate validation, CSRF token issuance, anonymous /auth/me and Join denial, missing-CSRF rejection, and login input validation. This script does not touch SQL Server or validate successful login.

Not executed:

- SQL schema/procedure compilation, 200,000-row seed, invariant tests, two-session concurrency tests and actual execution-plan benchmarks.
- Database-backed API requests, successful registration/login, and browser end-to-end workflows.

SQL Server was not installed. Pulling `mcr.microsoft.com/mssql/server:2022-latest` through the managed Docker daemon failed with `download failed after attempts=6: Forbidden`. No TLS or artifact verification was disabled. No database credentials were requested or created, and no real database connection string was supplied. Run database/01 through 06 with an authorized SQL Server, configure the dedicated API connection securely, and perform the README's functional validation before claiming end-to-end readiness.

Development Data Protection keys in this environment are ephemeral; sessions will invalidate after API restart. Production must configure secure persistent keys. The generated dev certificate and private key are outside the repository and must not be committed.

## Platform upgrade verification (2026-11-05, Beirut)

- Backend build: passed, zero warnings/errors.
- Frontend production build: passed; approximately 69 KB gzip of JavaScript and 5 KB gzip of CSS. These are bundle measurements, not latency or load benchmarks.
- Saved Playwright/Chromium UI suite: passed desktop and 390-pixel mobile checks, sign-in, preference persistence requests, host-covered creation/claim, host-only controls, editing, notifications, direction links, cancellation and cancelled-game action removal. Explicit mocked API fixtures were used. No JavaScript page errors or horizontal mobile overflow were observed.
- Actual HTTPS API smoke suite: passed TLS validation, CSRF checks, anonymous rejection for profile/edit/cancel/sponsorship/notifications, public configuration boundaries and reset input validation. This requires no SQL and does not prove authenticated ownership enforcement in SQL.
- Microsoft ScriptDom parser, SQL Server 2022 syntax mode: all eight SQL files parsed without syntax errors (SQLCMD control lines excluded from parsing). Parsing does not resolve object names, check permissions or execute transactions.
- npm and NuGet dependency audits: no known vulnerable dependencies reported by the current feeds.

Still unverified in the cloud: live upgrade execution, database constraints and concurrent sponsorship/promotion/cancellation, successful reset email delivery, Google Maps Embed with a restricted live key, real provider payment collection/payouts. SQL image GET requests redirect to a destination blocked by the session proxy, even though initial HEAD responses succeeded. Verification was kept enabled and no blocked destination was bypassed. Database/08-platform-tests.sql and docs/UPGRADE.md provide local checks.

The user demonstrated the original lookup, registration/sign-in and game creation flows against their local SQL Server. Those observations concern the original version, not this new migration.

Online payments and cash-out are disabled pending the merchant-provider name, API documentation and secure sandbox configuration. Password email delivery remains disabled until configured. Google Maps directions work without a key; embedded API maps require configuration. In-app notifications poll while the app is visible; background push notifications are not implemented.

## GIN401 category/event edition (2026-11-05, Beirut)

- API build passed with zero warnings/errors. The reproducible database-check runner also compiled with zero warnings/errors.
- All 13 SQL files passed Microsoft ScriptDom's SQL Server 2022 grammar. Reproduce from the repository root: `dotnet run --project tests/GameOn.DatabaseChecks -- --syntax`. This is syntax validation, not engine execution or schema binding.
- Browser suite passed 17-type catalog presentation, All/Sports/Activities and open-spot filters, sports and activity wizard paths, preference updates, host-only UI controls, editing, sponsor claims, cash reservation request/state, unavailable Whish, waitlist/withdrawal, cancellation, notifications and 390-pixel mobile overflow checks. API responses were explicit fixtures; no payment or SQL execution was simulated as real.
- Actual HTTPS middleware checks passed CSRF enforcement, anonymous route rejection, malformed category/conflicting subtype validation, reset input validation and public cash/Whish readiness flags. Certificate verification remained enabled.
- Frontend production build passed at approximately 71 KB gzip JavaScript and 6.4 KB gzip CSS. These are bundle sizes, not load-test results.
- Current npm and backend NuGet audits reported no known vulnerabilities.

Not run: live 09 migration, distributed analytics seed, SQL invariant tests, actual two-connection concurrency checks, query-plan/throughput benchmarks, live/sandbox Whish operations. The database runner requires a disposable SQL Server database ending in _Tests and securely configured test credentials; compiling it is not a passing database test. The cloud registry download limitation remains; no connection to the user's local SQL Server is available.

The user confirmed cash in person + Whish player payments, supplied sandbox/production roots and explicitly requested skipping/mocking execution. This release skips execution, stores no payment-provider secrets and creates no fake successful payments. Merchant operation paths/authentication and verification rules remain unimplemented until the private contract is available. No host cash-out workflow was requested in this clarified scope.

The final GameOn.sln includes the API, database-check project, and virtual solution folders for SQL, React source and guides. The full solution build passed with `dotnet build --no-restore -m:1`, zero warnings/errors. Validation used single-worker mode; a parallel invocation in this sandbox returned a nonzero exit without compiler errors. SQL checks remain unexecuted against an engine.

## Commercial layer (2026-11-05, Beirut)

- Full solution build passed, single worker, zero warnings/errors.
- GameOn.PaymentChecks executed 19 checks: decimal 2% fees, half-cent rounding, invalid amounts, valid/tampered/forged HMACs, stale/future timestamps, key separation, and mock rejection in Production regardless of its config flag. No database or money movement was involved.
- All 16 SQL files passed SQL Server 2022 grammar validation, including the new migration, optional campaign seed and commercial invariant tests. This does not bind objects or execute transactions.
- Playwright/Chromium browser suite passed sponsored badges, category flows, authoritative-looking fee rows with explicit API fixtures, cash checkout, mock initialization/demo confirmation, waitlist checkout, sponsorship, cancellation and mobile layout. The fixture APIs do not verify SQL, cryptography or real gateway processing.
- Actual HTTPS smoke checks passed CSRF enforcement, anonymous checkout/payment rejection, unsigned mock webhook rejection, exact-path/POST-only CSRF exemption and public capability boundaries. TLS verification remained enabled.
- Production frontend bundle built successfully at about 73 KB gzip JavaScript and 7 KB gzip CSS. These are artifact sizes, not throughput/latency measurements.

Not executed: live migration 13, actual SQL cash/idempotency transitions, real concurrent mock confirmations, campaign query execution and signed-positive HTTP-to-database completion. database/15-commercial-tests.sql and the extended guarded database runner cover those when a disposable SQL Server is available. No real Whish endpoints were called. Cash is awaiting physical payment; MockSucceeded is explicitly a demo, never a real paid receipt. Mock operation is enabled only in Development/Testing and requires an explicit flag.


## Update 16 verification (2026-11-05)

- .NET solution build: passed, zero warnings/errors, serialized MSBuild.
- React/Vite production build: passed.
- Chromium browser regression: passed with explicit application API fixtures and a Google library fixture. Covers dark-by-default, persistent light choice across reload, reduced motion, mobile overflow, existing 17-type discovery/hosting/booking flows, manual Whish recipient and reference submission, pending verification/history, external Google Maps search, country-filtered listing rendering, and host custom-pin payloads. A listener bug when enabling host selection on an already loaded map was found and fixed.
- 23 payment/security/map checks: passed. Fee rounding and mock HMAC checks use no database. Google country/coordinate validation uses fake HTTP responses and explicit decimal parameter precision checks; it does not call Google.
- API HTTPS middleware smoke: passed, including anonymous denial for payment history, transfer submission and operator review routes; server map key absent from public configuration. This is not a database role/ownership integration test.
- Microsoft ScriptDom parsed all SQL scripts, including migrations 16 and tests 17. No SQL Server engine is available here. Script 17 (manual booking idempotency, submission, operator authorization/audit and cancellation reconciliation) is provided for a disposable SQL Server copy and has **not** been executed on an engine.
- No live Google Maps/Places/Geocoding call, real Whish transfer, refund or merchant checkout execution occurred. Those integrations require owner configuration and live/sandbox validation. Receiving a transfer reference never automatically marks a payment verified.


## Migration 18: venue contacts and commitment deposits (2026-11-05)

- .NET solution build and Vite production build passed. 24 payment/security/map policy checks passed, including the updated 5% decimal and midpoint rounding cases.
- Chromium with explicit API/Google fixtures passed: USD 2 share + USD 1 deposit + USD 0.10 fee = USD 3.10, switching to a USD 1 deposit-only/cash-balance choice, pending transfer reference/history, validated venue tel link and paid-deposit roster badge, plus previous catalog/booking/theme/maps coverage. Fixtures never establish funds received.
- Actual API HTTPS middleware smoke passed for deposit quote/checkout, reference submission, history/review and operator venue-management authentication boundaries, and public 5% rate configuration. Authenticated owner/role checks require the live database tests; middleware smoke alone does not prove them.
- All SQL scripts passed Microsoft ScriptDom syntax parsing. SQL Server is unavailable here: migration 18 and acceptance script 19 are **not engine-executed**. The guarded disposable-database C# runner now includes deposit bypass rejection, two blocked authorization connections competing for a final spot, one held/one refund-review result, capacity preservation and full-event confirmation. These engine tests are supplied and compiled, not claimed as executed.
- Manual Whish only: no real transfer, authorization, refund, call or no-show forfeiture was performed. Operators must verify actual bank/Whish/attendance evidence before recording an action.


## Incomplete 13/16 migration repair

A user reported version 16 recorded with missing venue columns, missing manual-transfer tables and no Payments columns visible. Added a guarded, data-preserving repair for incomplete 13/16 schemas. Rebuilt current 16/18 migrations as ordinary-SSMS single-transaction wrappers with constant DDL/module compilation scopes, avoiding same-batch new-column binding and SQLCMD continuation hazards. The syntax checker now also parses decoded constant dynamic SQL, rather than only its string wrapper. Repair refuses recorded/partial deposit schemas. SQL Server is still unavailable here: grammar validation is not an engine execution or rollback proof.


## Navigation and discovery redesign

Frontend production build and Chromium fixture suite passed for distinct My games/Inbox destinations signed out and signed in, no anonymous private resource calls, post-login My games return, keyboard activation, active route indicators, Back/reload, touch navigation at 390px and overflow at 390px/820px. Existing booking/deposit/Whish/map fixture flows remained covered. The Sportciety reference URL could not be inspected because the workspace proxy denied that destination; no exact visual reproduction is claimed. No database migration or backend permission change was made for this frontend update.

## Signup, directory and screenshot design update — 2026-11-05

- Solution build passed with zero warnings/errors. Frontend production build passed.
- 32 payment, signature, map and onboarding policy checks passed, including missing/future/out-of-range DOB and 0/4/duplicate sport preference rejection.
- Chromium API-fixture checks passed: guest/private menu visibility, signup with private demographics and three sports, fourth-sport disabling, automatic authentication, profile persistence requests, in-app Jounieh results, selected-venue optional Maps link, host directory selection, existing account/payment/event workflows, mobile signup overflow and dark/light layouts. Google library responses were fixtures; no live Google credentials were used.
- Actual HTTPS middleware smoke checks passed, including CSRF, anonymous operator creation denial, invalid venue-search parameters, and rejection of missing gender/DOB or 0/4 signup sports before database access.
- ScriptDom parsed all SQL scripts, including decoded constant dynamic SQL in migration 20. Inspection also moved new procedure grants after procedure creation. Syntax parsing does not establish SQL engine binding, permissions or transactional execution.
- SQL Server remains unavailable here: migration 20 and rollback fixtures 21 have **not been executed** against SQL Server. Database-backed signup, directory creation, procedure ownership chaining and live Google coverage require verification on an authorized test database. No money or live Whish requests were involved.

Current preview screenshots use synthetic fixtures. Original directory seed entries are marked demo; no nationwide catalog, court availability or competitor offers/ratings are fabricated.
