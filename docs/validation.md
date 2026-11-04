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
