# GameOn: three transactions in depth (GIN401)

All three run as **one stored procedure = one transaction**, with `SET XACT_ABORT ON`,
`BEGIN TRY … BEGIN TRANSACTION … COMMIT` and `BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH`.
If **any** step fails, every change listed below is undone together, and the app receives the error.

---

## 1. `dbo.BookCourt`: a player books and pays for a court slot

| # | Step | Table(s) changed |
|---|------|------------------|
| 1 | Lock the court row `WITH (UPDLOCK, HOLDLOCK)`: two bookings for the same court are serialized | (lock only) `Courts` |
| 2 | Same request key already used? Return the first booking; never charge twice | (read) `CourtBookings` |
| 3 | Checks: future slot within 60 days, on the slot grid, not blocked, slot free, at most 6 upcoming | (read) `CourtBlocks`, `CourtBookings` |
| 4 | Price: base or peak hour, Pro discount, reward code marked **Used** | `RewardRedemptions` |
| 5 | Insert the booking (`Pending` if the club approves bookings, else `Confirmed`) | `CourtBookings` |
| 6 | Pay from the wallet: `WalletDebit` (balance − price, ledger row) | `WalletAccounts`, `WalletLedger` |
| 7 | Credit the club's balance held by GameOn: `ClubLedgerPost` | `Clubs`, `ClubLedger` |
| 8 | Loyalty points, activity log, staff notifications | `LoyaltyAccounts`, `LoyaltyLedger`, `UserActivityLogs`, `Notifications` |

**If a step fails** (slot taken, not enough money, wallet over $500, code expired…): the booking, the
reward code use, the wallet debit, the club credit and the points are all rolled back. The player is not charged.

**Two users, same slot, same moment:** the court lock makes the second wait. When it continues, step 3 finds the
slot taken and raises *"Someone just booked this slot"*. A filtered unique index `UX_CB_Slot (CourtId, StartsAt)
WHERE Status IN (active)` is a second safety net: even a bug cannot store the slot twice.

## 2. `dbo.JoinWithWallet`: a player joins a game with the $1 commitment deposit

| # | Step | Table(s) changed |
|---|------|------------------|
| 1 | Lock the game row `WITH (UPDLOCK, HOLDLOCK)`: places cannot be given twice | (lock only) `GamesAndEvents` |
| 2 | Idempotency: same key → same result, no second charge | (read) `DepositBookings` |
| 3 | Checks: game open, revision unchanged, host not on hold, not already in, not full | (read) |
| 4 | Create the deposit record (share, 5% fee, $1 deposit) | `DepositBookings` |
| 5 | Take $1 from the wallet: `WalletPost` | `WalletAccounts`, `WalletLedger` |
| 6 | Mark the deposit `PAID_HELD` | `DepositBookings` |
| 7 | Leave the waitlist, take the place (`sp_JoinGameOrActivity`) | `Waitlists`, `Participations`, `Payments`, `GameActivityLogs` |
| 8 | Activity log | `UserActivityLogs` |

**If a step fails** (game filled a millisecond earlier, wallet empty…): the deposit row, the $1 debit and the place
are all undone (*"Your place could not be confirmed. Nothing was charged."*).

## 3. `dbo.CancelGame`: the host cancels, and every wallet deposit is refunded

| # | Step | Table(s) changed |
|---|------|------------------|
| 1 | Lock the game; only the host, only before the start | `GamesAndEvents` |
| 2 | Game → `Cancelled`, revision + 1 | `GamesAndEvents` |
| 3 | Cash/mock payments cancelled; manual Whish payments → `RefundReview` | `Payments` |
| 4 | Every held deposit → `REFUND_PENDING` | `DepositBookings`, `Participations` |
| 5 | **`SettleWalletDepositRefunds`**: for each wallet-paid deposit, `WalletPost +$1`, deposit → `REFUNDED` | `WalletAccounts`, `WalletLedger`, `DepositBookings`, `Participations`, `Notifications` |
| 6 | Log + notify players | `GameActivityLogs`, `Notifications` |

**If a step fails** (for example the refund would push a wallet above $500): the game stays **Open** and no deposit
or wallet changes. A game is never half-cancelled with some players refunded and others not.

Since migration 34, step 5 is an **explicit procedure call**. It used to be hidden in a trigger. No trigger moves
money any more; the remaining triggers only **check** (`WalletLedgerBalanceCheck`, `WalletAccountBalanceCheck`,
`WalletLedgerAppendOnly`, `ApprovalRequired…`) or **log** (`CourtBlockActivity`).

---

## Wallet balance = sum of its ledger rows: how the database guarantees it

1. **One door.** The app's login `gameon_api` may only EXECUTE procedures. Balances change only inside
   `WalletPost`, `WalletDebit` or `BuyPro`, which update `WalletAccounts.Balance` **and** insert the matching
   `WalletLedger` row in the same transaction.
2. **Checked by the database on every posting.** An indexed view `WalletLedgerTotals` (SUM of Amount per user,
   kept up to date by SQL Server) lets the trigger `WalletLedgerBalanceCheck` verify after each ledger insert that
   `Balance = SUM(ledger)` and that the newest `BalanceAfter = Balance`. Otherwise the whole transaction is rolled back.
3. **No side doors.** `WalletAccountBalanceCheck` refuses any balance change that is not a posting (even by an
   administrator in SSMS), and `WalletLedgerAppendOnly` refuses UPDATE or DELETE on ledger rows (corrections are new rows).
4. **Limits.** `CHECK (Balance BETWEEN 0 AND 500)` and `CHECK (BalanceAfter >= 0)`.
5. **Two payments at the same moment.** Both read the balance with `WITH (UPDLOCK, HOLDLOCK)` on the same
   `WalletAccounts` row. The second waits until the first commits, then reads the **new** balance. Tested: a $18 wallet
   and two simultaneous $10.80 payments → one succeeds (balance $7.20), the other gets *"Not enough money"*, and
   balance still equals the ledger sum.
6. **Proof query:** `EXEC dbo.CheckWalletIntegrity;` lists every wallet with `OK` or `MISMATCH`.

## Large core table and key queries

`CourtBookings` holds about 127,000 rows (`database/perf-court-bookings-seed.sql`, synthetic and clearly labelled).
`database/perf-court-bookings-key-queries.sql` runs each key query with its index and forced without it:

| Query (procedure) | Index | Logical reads, indexed | Full scan |
|---|---|---|---|
| Court schedule for a day (`GetCourtSchedule`) | `IX_CB_Court_Time` | 3 | 2,141 |
| Player's history (`MyCourtBookings`) | `IX_CB_User` | 3 | 2,141 |
| Club revenue last month (dashboard) | `IX_CB_Court_Time` | 99 | 2,141 |
| Bookings per day (admin analytics) | `IX_CB_Start` (migration 35) | 41 | 2,141 |
| Double-booking guard (`BookCourt`) | `UX_CB_Slot` (filtered, unique) | 3 | n/a |

Measured on the test copy. Run the script in SSMS with **Include Actual Execution Plan** (Ctrl+M) to show
*Index Seek* vs *Clustered Index Scan*.
