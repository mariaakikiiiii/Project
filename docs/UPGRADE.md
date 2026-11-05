> Current API: apply [migration 18 for contacts/deposits and 5% fees](DEPOSITS.md) after version 16. The instructions below describe the earlier version.

> Latest: [Update 16](UPDATE-16.md) adds the new theme, venue maps and manual Whish transfers. Follow that guide after version 13. Automated merchant checkout remains unconnected.

# GameOn platform upgrade — existing Windows installation

**Commercial update:** once version 9 is installed, apply `13-commercial-layer.sql` in SQLCMD Mode. Optional demo campaigns use `14-sponsored-demo-seed.sql`. Follow [COMMERCIAL.md](COMMERCIAL.md) for 2% fee policy and safe mock checkout.

**Latest sports + activities edition:** after version 7, also install `09-categories-and-events.sql` in SQLCMD Mode. Then run `10-user-analytics-seed.sql` for the GIN401 analytics fixture. If version 7 is already installed, skip it. See [GIN401.md](GIN401.md) for the final schema, 17 event types and concurrency runner.

This upgrade adds the redesigned responsive interface, profiles, saved sport/area preferences, personalized discovery, host editing/cancellation, host-covered venue places, an in-app notification inbox, map links/API embedding, and password recovery infrastructure. It preserves your users, games and audit rows.

## 1. Update the project

Stop the two terminals with Ctrl+C. In Visual Studio use Git > Pull if you cloned the repository. If you downloaded a ZIP, download the new ZIP and extract to a NEW folder, then open its GameOn.sln. Do not overwrite private local files. User Secrets use the same project id and normally remain available.

## 2. Back up and upgrade SQL Server

Connect in SSMS with Windows Authentication (your migration/admin identity).

1. Right-click GameOn > Tasks > Back Up and save a full backup.
2. Open database/07-platform-upgrade.sql.
3. Select GameOn in the database dropdown.
4. Enable **Query > SQLCMD Mode**. This is required by `:ON ERROR EXIT`; it stops immediately on a failed batch and closes the connection, rolling back the upgrade transaction. Do not remove that command or execute individual selected portions.
5. Execute the whole file once. It installs version 7 and keeps the old data. If it was already installed, skip this file. Then execute 09-categories-and-events.sql in SQLCMD Mode before starting the latest app.
6. Reconnect if needed. Disable SQLCMD Mode for regular queries.
7. Execute database/08-platform-tests.sql against a disposable upgraded copy. Its fixtures roll back.

Command-line equivalent, using your existing trusted Windows authentication:

```powershell
sqlcmd -S localhost -d GameOn -E -b -i database/07-platform-upgrade.sql
```

Do not rerun 01-schema.sql on an existing database. The upgrade deliberately refuses to run twice. If any error appears, stop, keep the backup and report the exact error before further changes. Syntax parsing passed in the cloud; live upgrade and concurrency validation require your SQL Server.

## 3. Start the backend

```powershell
cd backend
$env:ASPNETCORE_ENVIRONMENT = "Development"
dotnet restore
dotnet run --urls https://localhost:7043
```

Visual Studio F5 also uses the checked-in https launch profile (port 7043 and Development). Keep your existing ConnectionStrings:GameOn in Manage User Secrets. Database encryption/certificate verification stays enabled. Your existing gameon_api role receives only the additional named procedure grants.

## 4. Start the frontend

In a second terminal at the repository root:

```powershell
dotnet dev-certs https --export-path "$env:TEMP\gameon-dev.pem" --format PEM --no-password
$env:NODE_EXTRA_CA_CERTS = "$env:TEMP\gameon-dev.pem"
cd frontend
npm ci
npm run dev
```

Open Vite's printed address. Sign in again: this upgrade uses a new session cookie and security-version claim.

## 5. Try the new features

- My profile: save favorite sports and neighborhood, then return to Discover. Sport matches rank first, then area matches, then time. Explicit filters still apply. Skill level is a profile field, not a game-matching filter yet.
- Host: set a venue share in USD or LBP and reserve host-covered places. The host is promising to settle those shares at the venue. The app does not charge, escrow, refund or pay money.
- Another account: use Claim a free place. Its place and sponsorship are committed atomically. Duplicate clicks do not add claims. A full game cannot promise a sponsored queue place.
- Host: edit time/description. Participants and waitlisted users receive an inbox update. Price/currency cannot change after another player joins. Capacity cannot shrink below occupied places. Increasing capacity automatically promotes queued players in FIFO order inside the same transaction.
- Host: cancel the game using the confirmation button. It disappears from upcoming discovery but remains in My Games history, and players are notified.
- Leave a full game: the next queued player is promoted with their standard fee and receives a notification. A released host-covered place is not automatically attached to that player.
- Inbox: unread badge, read state, game links and older updates. It refreshes every 30 seconds while the page is visible. There is no push delivery while the app is closed.
- Venue: Directions opens Google Maps without configuration. The initial seed venues are synthetic; a DBA must replace their addresses with real venue details before people use directions.

## 6. Activate the Google Maps API

In your Google Cloud project, enable Maps Embed API and its billing prerequisites. Create a browser key restricted to Maps Embed API and HTTP referrers for your actual frontend origins (including localhost during development). Check Google's current quotas and billing terms.

Set `Maps:EmbedApiKey` in Manage User Secrets. This is a browser-visible, referrer-restricted key by design; never reuse a server API key. Restart the backend. Game details will embed the venue map. Without a key, Google Maps search/directions links remain usable.

## 7. Activate password-reset email

An HTTPS Resend email adapter is included. Verify your sending domain in your email provider account. Add these settings securely to Manage User Secrets or production secret injection:

- Email:ApiKey — the email service API credential (never send it in chat)
- Email:From — your verified sender, such as GameOn <hello@your-domain>
- App:PublicOrigin — the frontend origin, e.g. http://localhost:5173 in local development, HTTPS in production

Outbound HTTPS to api.resend.com must be permitted in the hosting environment. No credential is committed and no email is sent until configured.

Reset requests return the same response for known and unknown emails. Only SHA-256 token hashes are used for validation. Email delivery payloads are encrypted with ASP.NET Data Protection before being queued. A worker leases a pending email, sends through HTTPS and retries failed deliveries up to five times, with an idempotency key. Links expire in 30 minutes and are single-use. Reset increments SecurityVersion; subsequent authenticated API requests reject previous sessions.

Production must persist Data Protection keys securely and share them among instances; protect keys at rest with the deployment platform's key management. Losing them invalidates sessions and undelivered reset payloads. Delete expired reset/outbox rows periodically under a separately privileged maintenance identity. Do not expose reset payloads, token bodies or credentials in logs.

## 8. Payments and cash-out — pending provider integration

Lebanon, cash at the venue and Whish player payments were confirmed. The user supplied the sandbox/production base URLs and asked to skip live execution. Those roots are configured server-side; private operation paths/signing rules are not guessed. Host cash-outs are not requested in this edition.

The current Payments & venue shares page honestly shows offline settlement and disabled online payouts. It has no fabricated wallet balance, bank form or simulated cash-out. When the private Whish contract is available, implement its hosted collection, verified status/webhook checks and idempotent reconciliation using sandbox credentials first. Merchant KYC, supported currencies, refund/payout eligibility and fees must be verified against that provider's actual contract.

## Verification commands

```powershell
cd backend
dotnet build
# In another terminal, with frontend npm run dev already running:
cd frontend
npm run test:ui
npm run build
```

UI tests use explicit API fixtures and a local Chrome/Chromium installation. Set GAMEON_CHROMIUM_PATH if your executable is elsewhere. They verify UI flows, not SQL behavior. `scripts/security-smoke.py` checks actual HTTPS middleware without a database. SQL tests and the two-session lab require SQL Server; do not equate syntax parsing with executing transactions.
