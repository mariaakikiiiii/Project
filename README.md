# Latest update

**Current update: migration 22.** Read [docs/UPDATE-22.md](docs/UPDATE-22.md). Run `database/22-deposit-lifecycle-venues.sql`, then `database/24-lebanon-venue-directory.sql`, on your existing database (version 20). It adds attendance-based $1 deposit refunds, disputes, host holds, a sourced venue directory and the Google Maps setup steps. Earlier notes below are historical.

**Current update — database + backend + frontend:** [signup, in-app venue search and the screenshot-inspired design](docs/ONBOARDING-VENUES.md). Apply **migration 20 after migration 18** before starting the new API. Guest menus hide private pages; signup requires gender, DOB and 1–3 sports.

**Migration errors near `:` or missing latitude/payment columns despite version 16 being recorded?** Follow [the guarded repair guide](docs/REPAIR-16.md). Do not delete version rows or rerun the older scripts.

Venue direct contact and commitment deposits: follow [the migration 18 instructions](docs/DEPOSITS.md) after migration 16. New events require a $1 deposit; new booking shares use a 5% service fee. Transfer references remain pending until an operator verifies received funds. Existing bookings/invoices retain their financial snapshots. [Dark/light themes and Google Maps setup](docs/UPDATE-16.md) remain available.

# GameOn

**Commercial layer:** [migration 13 historical guide: mock Whish and sponsored venues (superseded by migration 18)](docs/COMMERCIAL.md). Real Whish execution remains disabled; the local demo never transfers money.

**GIN401 sports + activities edition:** read [the lab and schema guide](docs/GIN401.md). Existing databases apply version 7 if needed, then version 9; do not rerun the original schema. See [the Windows upgrade steps](docs/UPGRADE.md). Whish network execution is skipped as requested; cash-at-venue reservations work without merchant credentials.

![Redesigned GameOn discovery interface](docs/screenshots/discovery-preview.png)

*Design preview uses synthetic UI test fixtures.*

A university lab implementation using SQL Server 2022, T-SQL, ASP.NET Core 8 + ADO.NET, and React 19. No ORM is used.

## 1. Create the database and schema

A DBA creates an empty `GameOn` database using SQL Server or Azure SQL. Run these scripts in order in that database (SSMS or `sqlcmd -b -d GameOn -i <file>`; use integrated authentication or securely injected SQLCMDPASSWORD):

1. [01-schema.sql](database/01-schema.sql): complete normalized schema, keys, constraints, indexes, summary view and waitlist function.
2. [02-procedures.sql](database/02-procedures.sql): transactional join/cancel/promotion, creation, discovery, roster, account and history operations.
3. [03-seed.sql](database/03-seed.sql): development fixtures and **200,000 activity events**, generated without per-row loops. The fixture host cannot sign in; register your own account.
4. Provision a dedicated `gameon_api` server login securely outside source control, then run [04-security.sql](database/04-security.sql). Use a distinct migration identity. Do not grant the API identity admin or direct table permissions.
5. Install [07-platform-upgrade.sql](database/07-platform-upgrade.sql) in SQLCMD Mode as described in the upgrade guide.
6. Install [09-categories-and-events.sql](database/09-categories-and-events.sql) in SQLCMD Mode, then run [10-user-analytics-seed.sql](database/10-user-analytics-seed.sql) for the additional 200,000-row analytics fixture.
7. Install [13-commercial-layer.sql](database/13-commercial-layer.sql). Optional [14-sponsored-demo-seed.sql](database/14-sponsored-demo-seed.sql) adds synthetic featured campaigns only.
8. Run [05-tests.sql](database/05-tests.sql), [08-platform-tests.sql](database/08-platform-tests.sql), [12-category-event-tests.sql](database/12-category-event-tests.sql) and [15-commercial-tests.sql](database/15-commercial-tests.sql) on a disposable upgraded database.
9. Run [11-analytics-performance.sql](database/11-analytics-performance.sql) and [06-performance.sql](database/06-performance.sql) with actual execution plans enabled.
10. Follow [COMMERCIAL.md](docs/COMMERCIAL.md) for fee/security checks and [GIN401.md](docs/GIN401.md) for the true two-connection race runner. A fresh lab installer is also provided: database/install-fresh.sql (run sqlcmd from the repository root; it refuses to replace an existing database).

SQL scripts use `GO`, which is handled by SSMS/sqlcmd, not by SqlCommand. They target a fresh database; schema/security migrations are deliberately not destructive rerunnable scripts. The data seed is rerunnable. No database is created automatically by the application.

## 2. Configure and start the API

Install .NET SDK 8. Set `ConnectionStrings__GameOn` through your development secret store or environment settings. Its connection string must specify your server, database, dedicated login/authentication, `Encrypt=True;TrustServerCertificate=False`, and valid certificate trust. Do not paste credentials into source files or shell history. User-secrets is supported with id `GameOn-Local-Development`. Production requires a secret manager and secure, durable Data Protection key storage.

```sh
cd backend
dotnet restore
dotnet build --no-restore
dotnet dev-certs https --trust
dotnet run --no-build --urls https://localhost:7043
```

On Linux, install/trust the development certificate according to your distribution and .NET instructions. Node's Vite proxy must trust the signing certificate too: export the public dev certificate to a local ignored `.pem` and set `NODE_EXTRA_CA_CERTS` to that public certificate path when running Vite. Keep certificate validation enabled. Production uses a trusted HTTPS reverse proxy and same-origin `/api` forwarding. Do not expose Vite as a production server.

## 3. Start React

Node.js 22+ is recommended; Node 24 was used for the build.

```sh
cd frontend
npm ci
npm run dev
```

Vite forwards `/api` to `https://localhost:7043`. Both UI and API use one browser origin through this proxy; no permissive CORS is required. `npm run build` creates `frontend/dist` for deployment behind the same HTTPS origin as the API. The redesigned UI includes personalized discovery, editable profiles/preferences, game details/maps/rosters, host editing and cancellation, My Games, host-covered places, and a persisted notification inbox. See the upgrade guide for optional Maps Embed and password-recovery email activation. Online collection and cash-out await the merchant provider integration. Dates are stored in UTC; discovery's date filter is explicitly UTC, while game start displays and input use browser local time.

## 4. Functional validation

Register two or more accounts in separate browser profiles. Create a game with capacity 2 (the host is automatically enrolled). A second account joins; a third is queued. Leave with the second account; refresh the third account's My Games and verify Joined. Verify duplicate Join does not increment the count, an unauthenticated Join returns 401, invalid capacity fails, and a missing/invalid CSRF token rejects a state change. Check SQL results and audit events, not just HTTP status. API lookup reads and registration require database migrations and least-privilege grants first.

See [architecture and performance guide](docs/architecture.md) for transaction reasoning, execution-plan interpretation, security boundaries, and known scope limits. See [validation record](docs/validation.md) for checks actually run in this environment.

## Source layout

```text
GameOn.sln
backend/
  Program.cs                 Authentication, filters, enrollments
  Database.cs                Typed ADO.NET SqlCommand.Parameters.Add
  PlatformEndpoints.cs       Profiles, notifications, host controls
  Payments/                  Whish server-client boundary (execution skipped)
  Properties/launchSettings.json
frontend/src/
  main.jsx                   Discovery, details, dashboard, profile, auth
  components/CategoryTabs.jsx
  components/EventWizard.jsx  Category → subtype → plan → review
  components/PaymentSelector.jsx
  api.js, domain.js, style.css
database/
  install-fresh.sql           Fresh lab installation only
  01–04                     Original schema, procedures, seed, grants
  07-platform-upgrade.sql     Existing-data platform upgrade
  09-categories-and-events.sql
  10-user-analytics-seed.sql
  11-analytics-performance.sql
  05, 08, 12                SQL invariant tests
tests/GameOn.DatabaseChecks/  Actual two-connection SQL race runner
frontend/tests/ui-check.cjs   Browser checks with explicit API fixtures
docs/GIN401.md, UPGRADE.md, validation.md
```
