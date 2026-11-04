# Payment integration boundary

Online money movement is intentionally disabled until the merchant provider is identified. The confirmed market is Lebanon. Venue shares can be denominated in USD or LBP; conversion is not performed. Host-covered places are a commitment by the host to settle a player's share at the venue, not a stored-value wallet or payout to the player.

Required provider information: legal merchant country, supported collection and payout currencies, hosted checkout API, webhook signing/versioning rules, sandbox endpoints, connected-recipient/KYC requirements, refunds, chargebacks, payout limits and payout eligibility in Lebanon. Provider names alone do not establish availability or approval.

Implementation contract after provider selection:

- Browser requests an order using GameId, never a client-controlled amount or host account id. Server verifies current membership and sponsorship, derives the authoritative currency/share and persists an idempotent order.
- Card/bank credentials remain in the provider-hosted checkout/onboarding. Store only opaque provider references and masked display information authorized by the provider.
- A success redirect never credits an account. Verify webhook signatures against the raw request bytes, enforce timestamp/replay rules and record each unique event id transactionally before applying state changes.
- Use immutable, currency-specific balanced ledger entries. Settlement, available funds, refunds and disputes remain distinct. Never add USD and LBP balances together.
- Payouts require a verified provider recipient and provider-confirmed available funds. A transaction reserves the balance before calling the provider with a stable idempotency key. Reconcile callbacks and retries without double payout. Cancellation/refund races must be tested in the provider sandbox.
- Provider credentials and webhook secrets use secure server configuration. Disable collection and payout endpoints until configuration and sandbox tests succeed. Real charges/payouts require merchant approval and explicit operational activation.

No payment-provider API has been invented or called by this upgrade.
