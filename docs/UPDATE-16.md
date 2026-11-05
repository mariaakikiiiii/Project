> Current API: apply [migration 18 for contacts/deposits and 5% fees](DEPOSITS.md) after version 16. The instructions below describe the earlier version.

# Update 16: themes, Lebanese venue discovery and manual Whish

Previews use explicit test fixtures: [dark discovery](discovery-preview.png), [light discovery](light-theme-preview.png), [checkout](checkout-preview.png), [manual Whish](manual-whish-preview.png).

## Update your existing installation

Your SQL backup is already done; take a new backup before applying another migration if you have added data since then.

1. Stop the API in Visual Studio (red square). Stop Vite with Ctrl+C.
2. In Developer PowerShell, run these as **separate commands**:

```powershell
Set-Location "$env:USERPROFILE\source\repos\GameOn-Full"
git pull --ff-only origin main
```

If Git reports local changes, preserve/review them before pulling; do not reset your project or database.

3. In SSMS connect with your Windows migration/admin identity. Open `database/16-location-manual-whish.sql`. Choose **Query → SQLCMD Mode**, clear any selected text, and execute the **whole file**. It explicitly selects `GameOn` and requires migrations 7, 9 and 13. Do not rerun older migrations or `install-fresh.sql` on this database. Version 16 refuses a second installation.
4. On a **disposable database copy**, run `database/17-location-payment-tests.sql` (and existing tests). The new test fixtures roll back. This environment syntax-checked the scripts but could not run a SQL Server engine.
5. Restart the API with F5. In Developer PowerShell:

```powershell
Set-Location "$env:USERPROFILE\source\repos\GameOn-Full\frontend"
npm ci
npm run dev
```

Open the URL Vite prints. Dark is the default; the sun/moon button remembers your chosen theme on that browser. No new frontend package is required.

## Google Maps: what works now

Discovery → **Find courts & activity venues in Lebanon** opens an activity-specific Google Maps search, with optional town text. This link works without an API key. Hosts have the same search in the venue step.

For in-app listings, interactive pins and host-selected locations, create/use a Google Cloud project you own at https://console.cloud.google.com/google/maps-apis/overview. Enable billing, Maps JavaScript API, Places API (New) and Geocoding API. No Google credentials are configured in the development workspace; the app cannot obtain your billing identity or invent a valid key.

Create two separate restricted keys:

- Browser key: allow Maps JavaScript API and Places API (New), with HTTP referrer restrictions for your frontend origins (development `http://localhost:5173/*` / `http://127.0.0.1:5173/*`, then your actual HTTPS domain).
- Server key: allow Geocoding API only, with your deployed server's outbound IP restrictions. Store it only in backend User Secrets/environment/your secret manager. It is never returned by `/api/config`. Configure quotas/budget alerts in Google Cloud.

Right-click **GameOn.Api → Manage User Secrets** in Visual Studio. Merge the following property into your existing JSON; **keep your current connection string**:

```json
"Maps": {
  "BrowserApiKey": "YOUR_RESTRICTED_BROWSER_KEY",
  "ServerApiKey": "YOUR_SERVER_GEOCODING_KEY",
  "MapId": "YOUR_GOOGLE_MAP_ID"
}
```

`MapId` is optional in development (the official `DEMO_MAP_ID` fallback supports the marker preview); configure your own map ID for deployment. Optional `Maps:EmbedApiKey` retains the existing details iframe. The browser key is necessarily public; restrict it by referrer and API. Never paste server keys into React, Git, screenshots or chat.

Once configured, hosts can check **Choose my own location on Google Maps**, search for a venue or click a custom pin, and enter/confirm its name. Publishing reverse-geocodes the pin on the server and requires country `LB`, then saves the event/host participation/venue in one transaction. A client-provided country or place ID is never accepted as country proof. Editing retains the existing venue to avoid silently moving an already booked group.

Search covers Lebanon, returns up to 20 matching Google listings per search, and supports all 17 activity types. Try a narrower town for further results. Google does **not** guarantee every venue is listed, court reservability, prices, opening times or availability. There is no direct court-operator booking integration. A GameOn booking reserves a participant place; the host must confirm the venue reservation separately. Existing seed venues are synthetic lab fixtures, not a verified Lebanese venue directory.

Review Google's current Maps/Places attribution and storage terms before launch. Search responses remain in browser memory; do not bulk copy them into a permanent venue directory. Host-confirmed event location records are separate from the transient listing results. Keep Google map attribution visible. Adapt the supplied nginx CSP when deploying maps.

## Manual Whish transfers

Player checkout offers Cash and **Whish Money transfer**. The configured recipient is **+96171364432**. This is a manual transfer destination, not a connected merchant checkout API.

1. Checkout computes the base price + 2% fee on the server and reserves a normal participant place under the existing event lock. No transfer instructions are shown until the reservation/payment record is committed. This uses the same pay-later booking policy as cash; it does not enforce an unpaid-reservation expiry.
2. The player opens their own Whish app and sends the exact displayed total/currency. No conversion is performed. Whish handles sending; GameOn never asks for a PIN, password or OTP.
3. The player submits the Whish transaction reference. Status becomes **Awaiting verification**, never paid automatically.
4. A designated GameOn payment operator checks the real Whish statement and verifies/rejects the reference under **Payments → Whish transfer reviews**. The operator must match reference, amount, currency and recipient. Each verified reference can settle only one payment, including after cancellation. Reviews are audited.
5. Payments shows the player's own records and allows resuming instructions/reference submission. Ordinary players and event hosts cannot grant themselves payment-operator access or verify transfers.

Configure a trusted operator **once**, using a DBA account in SSMS. First find your real registered account (not a disabled seed user):

```sql
USE GameOn;
SELECT UserId, Email, DisplayName FROM dbo.Users ORDER BY UserId;
```

Then use its actual ID in the parameter below (replace `123`, do not run it unchanged):

```sql
USE GameOn;
DECLARE @OperatorUserId int = 123;
IF NOT EXISTS(SELECT 1 FROM dbo.Users WHERE UserId=@OperatorUserId)
    THROW 50002, 'Choose an existing registered operator account.', 1;
IF NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=@OperatorUserId)
    INSERT dbo.PaymentOperators(UserId) VALUES(@OperatorUserId);
```

Do not grant the application table-write permissions or give ordinary players this role. Do not use SQL `sysadmin` credentials in the API.

If a participant leaves or a host cancels, associated manual transfers enter **Refund review required**. GameOn does not send refunds or cash-outs. The operator must check whether funds arrived and arrange any required refund outside GameOn. Reconciliation notes record the handling. Platform-to-host settlement is also manual: reconcile collected venue shares with hosts and prevent double collection at the venue. Cash remains payable to the host in person.

`backend/appsettings.json` contains only the authorized public destination and the nonsecret feature flag `Payments:ManualWhishEnabled`. Set that flag to false to stop offering new manual transfers; existing payments remain visible for reconciliation. Recipient numbers are snapshotted on the payment record. Merchant API execution remains disabled until the private Whish contract is implemented; the development mock remains explicitly labeled and cannot transfer real money.

## Validation limits

The build, browser flows with explicit fixtures, Google-country validation with fake HTTP responses, decimal fee checks and mock HMAC checks are automated. SQL scripts are parsed with Microsoft ScriptDom. Run the engine tests on your disposable SQL Server copy, and test the real Google configuration before accepting real customer bookings. No money was sent and no external Google API request was made during development verification.
