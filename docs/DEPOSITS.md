# Venue contacts and commitment deposits — migration 18

The confirmed policy is **USD 1 commitment deposit + 5% of the game share**. The earlier requested USD 2 schema default was superseded by the user's clarification. A USD 2 share therefore costs USD 3.10 when fully paid now: share 2 + deposit 1 + fee 0.10.

## Install on your existing GameOn database

1. Stop the API and frontend. Back up GameOn.
2. Pull the updated repository in Visual Studio, or use Developer PowerShell:

```powershell
Set-Location "$env:USERPROFILE\source\repos\GameOn-Full"
git pull --ff-only origin main
```

3. Open `database/18-security-deposits.sql` in SSMS using your migration/Windows identity. Choose **Query → SQLCMD Mode**, clear any selection, and execute the **whole file**. Migration 16 must already be installed. The script selects `GameOn` explicitly, records version 18, and refuses a second application. Do not use `install-fresh.sql` on your existing database.
4. Run `database/19-security-deposit-tests.sql` on a **disposable upgraded database copy**. The fixtures roll back and never call Whish. Earlier SQL test scripts target their original schema versions; they are not the acceptance suite for version 18.
5. Restart the API with F5. Restart `npm run dev` from the frontend folder.

[Deposit checkout preview](deposit-checkout-preview.png) uses explicit browser fixtures, not a real payment.

The Visual Studio solution includes the new SQL files, React components and this guide. Server source: `backend/Payments/DepositEndpoints.cs`; UI: `DepositCheckout.jsx`, `DepositHistory.jsx`, `VenueContactCard.jsx`.

## Venue phone and verification

No venue phone numbers are invented. Synthetic seed venues have no real contact number and cannot collect deposits until an operator supplies/checks one. The public payment destination **+96171364432 is not used as a venue phone number**.

Use the existing trusted `PaymentOperators` role from [update 16](UPDATE-16.md). A signed-in operator opens **Payments → Commitment deposits → Manage verified venue contact numbers**, enters the actual international venue number, checks the verification box after checking the venue, and saves. Ordinary players and hosts cannot approve their own contacts.

`Venues.ContactPhoneNumber` is `varchar(20)`; `IsVerified` has the requested default of 1. A default alone is not evidence: the migration marks existing venues unverified, and custom map-created venues explicitly start unverified. Deposits require both a checked contact and a phone number. Direct-call links use validated international numbers; no-phone cards explain the missing contact.

Contact verification checks the venue identity/contact, **not** an individual court reservation. Players/hosts must call to confirm availability, price and the reservation. A GameOn deposit is not a court booking and cannot prove a host has actually booked that court.

## Joining and money handling

- Existing events keep their bookings and remain deposit-exempt. New events default to `RequiresDeposit=1`, `DepositAmount=1.00`; they currently require USD. No USD/LBP conversion is invented. The host is included in capacity and exempt from the player deposit.
- Fully online/manual Whish choice: transfer share + 5% fee + USD 1 to the configured Whish destination. The USD 2 example is **USD 3.10 due now**.
- Cash share choice: transfer **USD 1 now**, then pay the share + 5% fee in cash at the venue. Checkout subtracts the cash balance from the total due now; the operator verifying the deposit does not mark the cash share as paid.
- Free/host-covered shares have zero share/platform fee, but the USD 1 commitment deposit still applies for new events. A host-covered share is not advertised as waiving the deposit.
- Quote and intent amounts are calculated in SQL; the API accepts IDs, revision, method and idempotency key, not client-supplied amounts or a paid flag. A quote does not hold a spot.
- Whish remains **manual**, not an implemented merchant authorization/escrow API. Players submit their transfer reference and remain `PENDING`. Only a trusted operator can authorize after checking actual reference, recipient, currency and amount on the Whish statement. No Whish password/PIN/OTP is collected.
- Authorization takes the event row with `UPDLOCK,HOLDLOCK`, verifies the snapshot/revision/capacity, and invokes `sp_JoinGameOrActivity` with a matching verified deposit authorization inside the same transaction. The join procedure uses `READ COMMITTED`, `TRY...CATCH`, `XACT_ABORT` and rollback, and rejects cash/mock/direct joins that attempt to skip the deposit.
- A successful authorization makes the participation `PAID_HELD` with a UTC `DepositPaidAt`. `PAID_HELD` means GameOn's manually verified held-deposit ledger, not a bank/card authorization or regulated escrow product.
- If another authorization wins the last spot, the losing transfer goes to **refund review** and is not enrolled. Checkout warns about this before transferring. Globally retired transfer references prevent the same funds authorizing multiple bookings, including after a recorded refund.
- A pending request can be withdrawn under Payments. It then requires reconciliation, cannot authorize enrollment, and blocks another deposit for the same event until resolved. If money was already sent, the player can still submit its reference for reconciliation. Withdrawal never claims an automatic refund.
- A full roster whose nonhost players all have held deposits sets `GamesAndEvents.DepositBookingStatus='CONFIRMED_DEPOSIT_LOCKED'`. This is a separate column so the existing `GameStatus` open/cancel lifecycle and discovery filters keep working. Capacity increases, departures, refunds and cancellation refresh/reset this derived state.
- Full events allow a waitlist without collecting a deposit. Legacy automatic FIFO promotion continues for exempt events. New deposit-backed events do not automatically enroll unpaid waiters: when space opens, the next queued player is notified and can open deposit checkout, and an operator authorizes the actual spot. Do not promise an automatic seat merely for joining that waitlist.

The fee change applies to new payments only. `Payments.FeeRate` snapshots existing 2% records and defaults new records to 5%, with a matching amount constraint. Existing issued invoices and transfers retain their stored fee/total; no retroactive surcharge is added.

## Refunds and no-shows

**No funds are refunded or forfeited automatically by this implementation.** Operators must check attendance/venue evidence and record the actual action under **Payments → Deposit & attendance reviews**.

- Leaving/cancellation moves held deposits to `REFUND_PENDING`. A submitted but unverified transfer also requires reconciliation if the event is cancelled. The persistent deposit ledger survives participation deletion.
- For a failed/cancelled reservation, reconcile/refund the collected amount: full Whish total, or only the deposit when the share was payable in cash. Operator UI shows that amount. Record the actual external refund transaction reference before marking `REFUNDED`.
- For ordinary attendance release after the event begins, refund the USD 1 deposit; the paid venue share/fee remain separate. This implementation uses manual attendance review, not a check-in or automatic no-show detector.
- `FORFEITED` is allowed only for a held deposit after the event starts and following an operator no-show review with a note. A cancelled event is not eligible. No automatic absence inference is made.
- Every review is audited. A refund of a received transfer that was cancelled before authorization also retires its original reference. Reject only references that could not be verified; never use rejection to hide received funds.
- Refunds of linked base payments must use the deposit review workflow so the deposit/base records remain consistent. Platform-to-host settlement remains manual.

## Analytics and checks

`UserActivityLogs` keeps the existing 200,000+ row lab dataset and gains deposit status/amount/requirement snapshots, plus explicit deposit actions. Index `IX_Activity_Event_Deposit_Time(EventId, DepositStatus, OccurredAt)` includes user/action/amount/requirement/synthetic flag. `Participations` has a matching event/status index. Venue contact/verification fields remain normalized and are covered by the venue verification index instead of copying phone data into every analytics row. Actual query-plan performance must be measured on SQL Server with your workload; a syntax check does not establish a fast execution plan.

Validation commands:

```powershell
dotnet build GameOn.sln -m:1
dotnet run --project tests/GameOn.PaymentChecks
dotnet run --project tests/GameOn.DatabaseChecks -- --syntax
```

The live database checks additionally require `GAMEON_TEST_CONNECTION_STRING`, `GAMEON_DISPOSABLE_TESTS=yes` and a database name ending `_Tests`. They include two independently blocked operator authorizations competing for one remaining spot and a direct-join bypass rejection. These live engine checks have not been run in this workspace because SQL Server is unavailable. Build, policy checks, API middleware and browser tests with fixtures are separate evidence; none sends real Whish money.
