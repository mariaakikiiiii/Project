# Update 22: deposit lifecycle, disputes, venue directory

Applies on top of your database at **migration 20**. Nothing here resets data, reruns the original schema, or touches existing accounts, bookings or payment history.

## 1. Apply the database changes (SSMS, in this order)

1. Stop the API (red square in Visual Studio) and Vite (Ctrl+C).
2. Back up GameOn: in SSMS right-click **GameOn → Tasks → Back Up…** (or keep the copy-only backup created during development: `…\MSSQL\Backup\GameOn_before_v22_copyonly.bak`).
3. Open **`database/22-deposit-lifecycle-venues.sql`** with your Windows/admin login. SQLCMD Mode **off**. Clear any selection and press **F5** once. Expect `Migration 22 completed successfully`. It is one transaction: on any error nothing changes. Running it a second time stops with "already installed" and changes nothing.
4. Open **`database/24-lebanon-venue-directory.sql`** and press **F5**. It adds 6 researched venues with their source and check date. It is safe to rerun and only inserts venues that are missing.
5. Optional, **only on a disposable copy** whose name ends in `_Tests`: `database/23-deposit-lifecycle-tests.sql` (27 SQL checks). It refuses to run on `GameOn`.

Do **not** run `install-fresh.sql`, `01-…`, or any earlier migration.

## 2. Make someone a payment/venue operator (once)

Operators verify transfers, record refunds, resolve disputes and edit venues. Use a separate account from the one you host and play with: operators cannot review their own bookings or games.

```sql
USE GameOn;
SELECT UserId, Email, DisplayName FROM dbo.Users ORDER BY UserId;
-- replace 123 with the real UserId:
INSERT dbo.PaymentOperators(UserId) SELECT 123 WHERE NOT EXISTS(SELECT 1 FROM dbo.PaymentOperators WHERE UserId=123);
```

## 3. Run the app (Windows)

1. Visual Studio: open `GameOn.sln`, select **GameOn.Api** and the **https** profile, press **F5**. Keep it running.
2. Developer PowerShell in the project folder, one command at a time:

```powershell
cd frontend
npm ci
dotnet dev-certs https --export-path "$env:TEMP\gameon-dev.pem" --format PEM --no-password
$env:NODE_EXTRA_CA_CERTS = "$env:TEMP\gameon-dev.pem"
npm run dev
```

3. Open http://localhost:5173/ and press Ctrl+F5.

## 4. How the $1 commitment deposit now works

| Step | Who | Status |
|---|---|---|
| Player opens checkout; amounts are computed on the server (share + 5% fee + $1 deposit) | Player | — |
| Player sends the "due now" amount to **+96171364432** in Whish and enters the reference | Player | `PENDING` (a reference is **not** proof of payment) |
| Operator finds the transfer on the actual Whish statement and verifies it. The seat is reserved in the same locked transaction | Operator | `PAID_HELD` |
| Host cancels before the start, or reports "did not take place" | Host | `REFUND_PENDING` for every held deposit |
| After the start, the host reports attendance **and** the player confirms "I played". Both must agree | Host + player | `REFUND_PENDING` |
| Host and player disagree, or a player says the game did not happen | — | `DISPUTED` (frozen) |
| Operator sends the refund in Whish, then records the refund reference | Operator | `REFUNDED` (only after the reference is recorded; each reference can be used once) |
| Refund never arrived | Player | `DISPUTED`. Operator resolves it as refund owed, and a new reference is required |

Neither the host nor a player can move money alone, and deposits are never paid to the host. Operators cannot act on games or bookings they are part of. **Host hold**: an operator can freeze a suspected host. That blocks new games and new deposit verifications for their events. Held deposits can then only be refunded to players.

This is a **manual** workflow. GameOn has no Whish merchant API connection, and GameOn's Whish number is a normal account, not escrow. Nothing in the app sends or confirms money by itself.

### Policy decisions still needed from you (not implemented on purpose)

- **Player leaves before the start.** The deposit stays held and shows "Player left. No policy decided". Options: always refund, refund if they leave more than X hours before the start, or keep it. Until you decide, operators refund case by case.
- **Confirmed no-show.** `FORFEIT` is disabled in the API and the database. Decide whether a no-show loses the $1, and who receives it (it must not silently go to the host).
- **Reports never filed.** If neither side reports within 14 days, the deposit appears as "AttendanceIncomplete" for an operator. Decide the default.
- **Venue share collected through Whish.** Paying it out to the host is still manual and outside GameOn.

## 5. Venue directory

- Every listing has a status: **Demo** (synthetic, shown as "not real"), **Unverified**, or **Verified**. Verified requires an official source link and a check date, enforced in the database.
- A listing existing, the venue taking reservations ("How to reserve"), and a time slot being free are shown separately. **Live availability is never shown**, because no venue booking integration exists.
- The 6 starter venues (Saida, Aley, Jounieh ×2, Kaslik, Beirut) come from the sources recorded on each one. Only Hariri Sports Complex is "Verified" (official foundation page). **No phone is marked confirmed.** An operator must call before deposits can be taken at that venue. This is not complete coverage of Lebanon.
- Operators: **Payments → Venue directory** to correct or verify, or **Venues → Add a venue**. Every change is audited with a required note.

## 6. Google Maps: why it is not working, and what you must configure

Diagnosis: the code is correct, but **no Google keys are configured**. Your user-secrets contain only the connection string, so `/api/config` returns empty map keys. The embedded map and Google listings stay off, and hosts cannot drop a custom pin. In-app venue search and "Directions in Google Maps" links work without keys. Live Google Maps was **not** verified, because no key exists.

To enable it:

1. https://console.cloud.google.com → create or select a project → **enable billing** (Google requires it even within the free tier).
2. Enable **Maps JavaScript API**, **Places API (New)** and **Geocoding API**.
3. Create a **browser key**: restrict it to Maps JavaScript API and Places API (New), with website referrers `http://localhost:5173/*` and your real domain.
4. Create a **server key**: restrict it to Geocoding API only (and your server's IP when deployed). It never reaches the browser.
5. Optional: create a **Map ID** (Map Management → Create, JavaScript, Vector).
6. Visual Studio: right-click **GameOn.Api → Manage User Secrets**, and **keep** your existing connection string:

```json
"Maps": { "BrowserApiKey": "…", "ServerApiKey": "…", "MapId": "…" }
```

7. Restart the API. Open Venues and search a town: the map and Google listings appear. If the browser console shows `RefererNotAllowedMapError`, `ApiNotActivatedMapError` or `BillingNotEnabledMapError`, fix steps 3, 2 or 1 respectively.

Hosts' custom meeting points are re-checked on the server (country must be LB) before saving.
