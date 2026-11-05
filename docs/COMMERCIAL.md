# Commercial layer: 2% fees, sponsored venues and mock Whish checkout

## Existing installation

1. Stop the API and frontend. Back up GameOn in SSMS (Tasks > Back Up).
2. Make sure upgrades 7 and 9 are already installed. Do not rerun them if their version markers exist.
3. Open database/13-commercial-layer.sql, select GameOn, enable Query > SQLCMD Mode, execute the WHOLE file once. SQLCMD stops on error; the upgrade transaction is rolled back on connection exit. Never run selected fragments.
4. Optional, development only: run database/14-sponsored-demo-seed.sql to feature the two original synthetic venues. It never automatically advertises an unrelated real venue. Production campaigns are entered by a separately privileged administrator, not the application user.
5. Restart the API and frontend using your existing trusted database connection in User Secrets. Your users, event ids and private settings are preserved.

Fresh lab installs use database/install-fresh.sql, which now includes migration 13. Optional ad seed 14 is deliberately separate. GameOn.sln contains the API, React/SQL solution items, database checks and payment policy/security checks.

## Money policy

Base price is the event's stored CostPerPlayer. ServiceFee = round(Base × 0.02, 2), with half cents rounded away from zero (up for these nonnegative prices). Total = Base + ServiceFee. SQL decimal columns/functions and C# decimal arithmetic agree. JavaScript only formats server values; it does not decide the charge.

Examples: USD 15 + 0.30 = 15.30. USD 0.25 + 0.01 = 0.26. USD 1.25 + 0.03 = 1.28. USD and LBP remain separate currencies, each stored to two decimals; there is no conversion. Free and host-covered places have no player fee or payment record.

Existing confirmed bookings are not charged retrospectively. Existing waitlist rows have AcceptedServiceFee=0 and are grandfathered on promotion. New paid reservations/waitlist entries accept the displayed fee policy. Waitlists have no payment due until promoted; promotion creates an awaiting-cash record only for new entries that accepted the fee.

Cash statuses remain PendingCash until cancelled. This release does not claim to verify receipt of physical cash or recognize settled platform revenue. There is no endpoint that fabricates real Paid receipts.

## Tables and integrity

Payments contains PaymentID, UserID, GameID, Amount, ServiceFee, computed TotalAmount, Currency, Mode, Status, GatewayTransactionID, IdempotencyKey, event revision and timestamps. Foreign keys preserve history. Unique indexes enforce per-user idempotency, one pending cash/mock checkout per user/event, and unique non-null gateway references. Amounts are immutable snapshots and a CHECK enforces the 2% rule.

PaymentWebhookEvents stores each processed mock event id and SHA-256 payload digest. It does not store secrets. SponsoredVenues stores VenueID, Gold/Silver/Bronze tier, inclusive UTC StartDate, exclusive EndDate, and IsActive. Public discovery returns at most 12 active campaigns and clearly labels them Sponsored. Dates, activation and tier are administered outside the runtime database role.

Checkout, joins, cancellation, promotion, host edits and callback application all lock GamesAndEvents first, then payment/membership rows. Cash enrollment and its receivable are atomic. Mock initialization does not reserve a place. Verification rechecks the locked capacity, event revision, start/status and membership. Two demo successes racing for the final place cannot both enroll; the loser becomes MockFailed. Cancellation closes pending records and marks successful demos MockCancelled. Mock state is never treated as real paid money.

## API

All database calls use fixed procedure names and explicitly typed SqlCommand.Parameters.Add calls.

| Route | Behavior |
|---|---|
| GET /api/venues/sponsored | Public, active campaign cards, rate limited. |
| GET /api/games/{id}/quote | Authenticated authoritative base/fee/total, revision and booking availability. |
| POST /api/games/{id}/checkout | Owner from cookie claim; body Method, IdempotencyKey, Revision. Cash reserves/queues; WhishMock initializes a demo. Client amounts are not accepted. |
| GET /api/payments/{id} | Owner only; other users receive 404. |
| POST /api/payments/{id}/mock-complete | Owner + CSRF, demo environments only; simulates a signed mock provider confirmation. |
| POST /api/payments/whish/mock/webhook | Exact CSRF exemption; authenticates raw-body HMAC, timestamp and persistent event id. No cookie is required. |

The ordinary /join route continues to support free places and idempotent existing membership. New priced reservations must use checkout to review fees. Host-covered claims retain their existing zero-fee route. Quotes are advisory: initialization checks the submitted revision to reject silent price changes. Retries must reuse the same idempotency key; a recorded payment key cannot be reused for a different event or method. Waitlist-only retries have no financial record and rely on the unique enrollment key. Cash retry after cancellation returns the original terminal result; a new intentional booking needs a new key.

## Safe mock Whish protocol

This is an explicit GameOn demo protocol, not an invented claim about Whish's private live API. No sandbox or production Whish network request is made.

Mock execution requires BOTH Payments:EnableMockCheckout=true and Development or Testing environment. appsettings.Development.json enables the local demo. Production rejects mock execution even if the setting is true. Use a separate development/test database; do not point a demo API at a real production booking database.

An optional Payments:MockWebhookSecret can be injected securely (at least 32 UTF-8 bytes). Without it, the process generates an ephemeral cryptographic key that is never logged or returned. Internal simulation works with that key; independently authored callback tests require a securely configured shared secret. Restarting with an ephemeral key invalidates old signatures.

Raw UTF-8 JSON payload fields:

```json
{
  "webhookEventId": "a UUID",
  "paymentId": "a UUID from initialization",
  "gatewayTransactionId": "mock reference",
  "status": "success",
  "totalAmount": 15.30,
  "currency": "USD"
}
```

Headers: X-GameOn-Mock-Timestamp (Unix seconds), X-GameOn-Mock-Signature (hex HMAC-SHA256 of timestamp + '.' + the exact raw body). Signatures use constant-time comparison. The timestamp must be within five minutes. Replays with the same event id/payload are idempotent; reusing an event id for different data is rejected. Matching amount/currency and unique gateway references are enforced in SQL, not trusted from a browser redirect. Malformed/unsigned callbacks cannot alter payment records.

Successful demos are labeled MockSucceeded and the membership method is WhishMock. The UI shows DEMO and no-real-money text before and after confirmation. The owner-triggered simulate endpoint is intentionally available only for this demonstration; remove/replace it when implementing the private verified real gateway contract. Real online checkout remains unavailable.

## UI

SponsoredVenues.jsx renders accessible horizontal cards, paid badges and local-area exploration without altering organic ranking. CheckoutModal.jsx uses a native modal dialog, authoritative fee rows, cash/demo choices, retry-safe keys, revision checks, loading/error states, and a demo confirmation stage. A pending demo has no seat hold. A full event allows waitlisting without payment. There is no bank/PIN/password collection.

## Verification

From repository root:

```sh
dotnet run --project tests/GameOn.PaymentChecks
dotnet run --project tests/GameOn.DatabaseChecks -- --syntax
```

The first executes decimal/signature/environment policy checks without SQL. The second parses T-SQL syntax only. With Vite running, frontend `npm run test:ui` executes browser checks with explicit API fixtures. scripts/security-smoke.py verifies the actual local HTTPS middleware, including unsigned callbacks and the exact CSRF exemption.

For actual SQL verification, use a disposable fully upgraded database ending in _Tests. Run database/15-commercial-tests.sql and the existing database runner with securely injected GAMEON_TEST_CONNECTION_STRING plus GAMEON_DISPOSABLE_TESTS=yes. The runner additionally races two mock confirmations for the last place, checks duplicate callbacks and mismatched totals, and cleans its fixtures. These engine tests have not been executed in the cloud due to the existing SQL Server image-download limitation; do not equate parser or mock-UI results with database execution.
