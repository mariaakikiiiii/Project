# Update 25: GameOn wallet, real maps, layout fix

Needs migration 22 (already on your database). Nothing here deletes or rewrites existing accounts, games or payments.

## 1. Install (SSMS)

1. Stop the API (Visual Studio red square) and Vite (Ctrl+C). Back up **GameOn** (right-click → Tasks → Back Up…).
2. **File → Open → File…** → `database\25-wallet.sql` → SQLCMD Mode off → **F5**. Expect `Migration 25 completed successfully`.
3. Optional, only on a copy named `…_Tests`: `database\26-wallet-tests.sql` (19 checks).
4. Visual Studio: **F5** on GameOn.Api. In the `frontend` folder: `npm ci`, then `npm run dev` (Leaflet was added, so `npm ci` is required once).

## 2. The GameOn wallet

| Step | What happens | Automatic? |
|---|---|---|
| Player taps **Wallet → Top up** (e.g. $10) | App shows: send $10 with Whish to **+96171364432** | – |
| Player pastes the Whish reference | Top-up shows "being checked" | – |
| Operator finds it on GameOn's Whish statement → **Money received** | Balance +$10 | Manual (no Whish merchant API) |
| Player joins a game → **Pay $1 from wallet** | Place confirmed instantly; venue share + 5% fee paid in cash at the venue | ✅ instant, in one database transaction |
| Host cancels / both confirm attendance / dispute resolved for player | $1 back in the wallet | ✅ instant |
| Player → **Withdraw to Whish** | Balance held immediately | – |
| Operator sends Whish and records reference | Marked Sent | Manual |

Protections: append-only ledger with balance after every entry; balance can never go below 0 or above USD 500; every top-up, payment, refund and withdrawal can be posted only once (unique indexes); idempotency keys stop double taps; Whish references can't be reused; operators can't approve their own money; the operator screen shows a reconciliation check (balances = ledger).

### What this is and isn't (important before selling it)

- **Whish does not send money "into the app".** Players still send to GameOn's Whish number; the app only *records* the balance after an operator confirms it. True in-app Whish payment (pay button → Whish → automatic confirmation and refunds) needs a **Whish merchant/business account and API contract**. Contact Whish Money business support and ask for: collection API with server callbacks, refunds/payouts API, sandbox credentials. `backend/Payments/IWhishGateway.cs` is where that integration goes.
- **Holding customer balances is regulated.** A stored-value wallet in Lebanon is likely e-money under Banque du Liban rules. Before real launch or sale, get legal advice; until then keep the USD 500 cap, use a **separate business Whish account** (not a personal number), and reconcile daily.
- The $1 reserves a place in the GameOn game. It does not book the court with the venue.

## 3. Maps: any real place in Lebanon

**Works now, no keys needed.** When hosting, choose **Any place on the map**, then:
- search a place (OpenStreetMap data, Lebanon only), or
- paste a Google Maps link (in Google Maps: open the place → **Share → Copy link**), or
- tap the map and drag the pin.

The server checks every pin really is in Lebanon before saving. Game pages show the pin on a map with a **Directions** link that opens Google Maps.

**Switch to real Google Maps (optional).** You don't edit any file in Git. Keys are secrets, so they go in Visual Studio User Secrets:

1. https://console.cloud.google.com → create project → **Billing** → link a card (Google gives monthly free credit).
2. **APIs & Services → Library** → enable **Maps JavaScript API**, **Places API (New)**, **Geocoding API**.
3. **Credentials → Create credentials → API key** twice:
   - *Browser key*: Application restriction = Websites → `http://localhost:5173/*` (+ your domain later). API restriction = Maps JavaScript API, Places API (New).
   - *Server key*: API restriction = Geocoding API only.
4. Visual Studio → right-click **GameOn.Api → Manage User Secrets** → this opens `secrets.json`. Keep your connection string and add:

```json
{
  "ConnectionStrings": { "GameOn": "…keep yours…" },
  "Maps": { "BrowserApiKey": "AIza…browser", "ServerApiKey": "AIza…server", "MapId": "" }
}
```

5. Restart the API. The host screen and Venues page switch to Google Maps automatically.

The free OpenStreetMap services are fine for development and small use; their policy forbids heavy use. Before a commercial launch, either add the Google keys above or use a paid tile/geocoding provider.

## 4. Fixed

- Game page: the booking card no longer slides over "Your game, your crew" when scrolling; the whole right column scrolls as one unit under the header.

## 5. Tests

```powershell
dotnet run --project tests\GameOn.PaymentChecks
```

API end-to-end (needs a second API on a `_Tests` database; the script refuses to run against your real database):

```powershell
$env:NODE_EXTRA_CA_CERTS="$env:TEMP\gameon-dev.pem"; $env:GAMEON_API="https://localhost:7044"; $env:GAMEON_TEST_DB="GameOn_Tests"; node tests\api-flow.mjs
```
