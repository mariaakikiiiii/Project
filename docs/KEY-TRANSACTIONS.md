# GameOn: three transactions in depth (GIN401)

Since migration 39, GameOn no longer handles player money in the app: there is no wallet, no $1 deposit and
no Whish transfers. Players pay at the club, GameOn records its commission (`CourtBookings.PlatformFee`), and the
only money ledger left is each club's balance (`Clubs.Balance` + `ClubLedger`).

Each transaction below is **one stored procedure = one transaction**, with `SET XACT_ABORT ON`,
`BEGIN TRY … BEGIN TRANSACTION … COMMIT` and `BEGIN CATCH IF XACT_STATE()<>0 ROLLBACK; THROW; END CATCH`.
If **any** step fails, every change listed is undone together and the app receives the error.

---

## 1. `dbo.BookCourt`: a player books a court slot

| # | Step | Table(s) changed |
|---|------|------------------|
| 1 | Lock the court row `WITH (UPDLOCK, HOLDLOCK)`: bookings for one court are serialized | (lock) `Courts` |
| 2 | Same request key already used? Return the first booking (no duplicate) | (read) `CourtBookings` |
| 3 | Checks: future, within 60 days, on the slot grid, a duration the court offers, not blocked, slot free, at most 6 upcoming | (read) `CourtPrices`, `CourtBlocks`, `CourtBookings` |
| 4 | Price: base or peak, Premium discount, reward code marked **Used** | `RewardRedemptions` |
| 5 | Insert the booking with GameOn's commission (`PlatformFee` = club's `CommissionPct` of the price) | `CourtBookings` |
| 6 | Loyalty points, activity log, notifications to club staff | `LoyaltyAccounts`, `LoyaltyLedger`, `UserActivityLogs`, `Notifications` |

**If a step fails** (slot taken, invalid duration, reward expired…): the booking, the reward-code use and the
points are all rolled back.

**Two users, same slot, same moment:** the court lock makes the second wait; it then finds the slot taken
(*"Part of this time was just booked"*). The filtered unique index `UX_CB_Slot (CourtId, StartsAt) WHERE Status IN
(active)` is a second safety net.

## 2. `dbo.AdminDeleteUser`: delete and anonymise an account

| # | Step | Table(s) changed |
|---|------|------------------|
| 1 | Checks: caller is admin, not themself, target not admin, target owns no club | (read) |
| 2 | Cancel their upcoming hosted games (`CancelGame` for each) | `GamesAndEvents`, `GameActivityLogs`, `Notifications` |
| 3 | Leave upcoming games and waitlists | `Waitlists`, `Participations` |
| 4 | Cancel upcoming court bookings; refuse if any remain | `CourtBookings` |
| 5 | Cancel upcoming classes and give pack credits back (`ReturnClassCredit`) | `ClassRegistrations`, `ClubPurchases` |
| 6 | Erase personal data: sports, area, friends, groups, staff roles, operator role, photo captions, message texts | `UserSportPreferences`, `UserPreferences`, `Friendships`, `PlayerGroupMembers`, `ClubStaff`, `PaymentOperators`, `Shots`, `Messages` |
| 7 | Anonymise the user row (name, email, password disabled, status `Deleted`) | `Users` |
| 8 | Audit entry | `AdminAudit` |

**If a step fails** (for example a paid booking that must be cancelled first): **nothing** is deleted. The account
is never left half-anonymised. Bookings and history rows stay, attached to "Deleted user".

## 3. `dbo.RecordClubPayout` → `dbo.ClubLedgerPost`: paying a club its balance

| # | Step | Table(s) changed |
|---|------|------------------|
| 1 | Checks: operator, amount > 0, reference given | (read) |
| 2 | Same (Kind, reference) already posted? Do nothing (never pay twice) | (read) `ClubLedger` |
| 3 | Read the club balance `WITH (UPDLOCK, HOLDLOCK)`; refuse if it would go below 0 | (lock) `Clubs` |
| 4 | `Balance = Balance − amount` | `Clubs` |
| 5 | Ledger row with `BalanceAfter` | `ClubLedger` |

**Balance = sum of ledger rows:** club balances change only inside `ClubLedgerPost` (the app's login may only
EXECUTE procedures). The balance update and its ledger row are written in the same transaction, under a row lock, so
two payouts at the same moment run one after the other and the second sees the new balance.
`CHECK (Balance >= 0)` and `CHECK (BalanceAfter >= 0)` back this up.

---

## Large core table and key queries

`CourtBookings` holds about 127,000 rows (`database/perf-court-bookings-seed.sql`, synthetic, clearly labelled).
`database/perf-court-bookings-key-queries.sql` runs each key query with its index and forced without it:

| Query | Index | Logical reads, indexed | Full scan |
|---|---|---|---|
| Court schedule for a day | `IX_CB_Court_Time` | 3 | 2,141 |
| Player's history | `IX_CB_User` | 3 | 2,141 |
| Club revenue last month | `IX_CB_Court_Time` | 99 | 2,141 |
| Bookings per day (admin analytics) | `IX_CB_Start` (migration 35) | 41 | 2,141 |
| Double-booking guard (`BookCourt`) | `UX_CB_Slot` (filtered, unique) | 3 | n/a |

Run it in SSMS with **Include Actual Execution Plan** (Ctrl+M) to show *Index Seek* vs *Clustered Index Scan*.
