# Cash and Whish boundary

Confirmed scope: Lebanon, cash paid in person, Whish online player payments. Host cash-outs are not requested in this edition. The merchant supplied its base URLs and explicitly requested skipping/mocking payment execution to focus on the database and app. This release skips execution; it does not pretend a mock is a real transfer.

## Configuration

- Sandbox: https://lb.sandbox.whish.money/itel-service/api/
- Production: https://whish.money/itel-service/api/
- Server-only keys: Whish:ChannelId, Whish:SecretKey, Whish:WebsiteUrl.
- Whish:Environment selects Sandbox (default) or Production. Root URLs are fixed; arbitrary remote hosts cannot be supplied by clients.

The named server HttpClient and IWhishGateway boundary are provided. WhishMerchantConfiguration records the required settings without exposing values. No authentication header name, operation path, signature scheme or response schema is invented from the base URLs. The current gateway is unavailable even if credentials are configured; there is no switch that enables unsupported payment execution.

## Current behavior

Cash is persisted on participation/waitlist records and carried through promotion. It means the player intends to settle at the venue, not that payment was received. Host-covered places waive the player's venue share by agreement with the host.

Whish is visible but unavailable. Positive-price Whish joins are also rejected in the SQL transaction, preventing direct API calls from bypassing the UI. No funds, wallet balances, receipts, refunds or provider statuses are fabricated. The app never asks for a player's Whish password, PIN or one-time code.

## Work required before real checkout

Obtain the private merchant operation paths, authentication/signing rules, hosted checkout/status schemas, sandbox test cases, supported currencies and webhook verification contract. Derive amounts from the locked event and actual membership, never a client-controlled amount. Persist unique orders and provider references with idempotent reconciliation. A browser success redirect must not mark an order paid: verify status/signature on the server. Handle cancellation, timeout, duplicate callbacks and refunds in the sandbox before operational activation. Keep USD and LBP amounts separate and do not perform implicit conversion. Merchant credentials belong in User Secrets or production secure injection, never source or chat.

## Commercial mock update

See [COMMERCIAL.md](COMMERCIAL.md) and migration 13. Real Whish remains unavailable; a separate, development-only WhishMock choice now demonstrates signed verification and booking. No private merchant endpoints or authentication headers have been guessed.
