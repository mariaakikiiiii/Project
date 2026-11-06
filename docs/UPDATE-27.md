# Update 27: clubs & courts, coaches, approval & private games, chat, Play & Earn, GameOn Pro

Builds on migrations 22 (deposits) and 25 (wallet). Nothing existing is removed: open/free spots, waitlists, $1 deposits, wallet, disputes and the venue directory all keep working.

## Install

1. Stop the API and Vite. Back up GameOn in SSMS.
2. SSMS → **File → Open → File… → `database\27-clubs-community.sql`** → SQLCMD Mode off → **F5** → `Migration 27 completed successfully`. (Needs 25 first.)
3. `frontend` folder: `npm ci` (adds the SignalR client), then `npm run dev`. Start the API with **F5**.
4. Optional on a `_Tests` copy only: `database\28-clubs-community-tests.sql` (47 checks).

## Architecture (in this project's stack)

The request mentioned Node/Next.js/Prisma/Socket.io. GameOn runs on **ASP.NET Core + ADO.NET + SQL Server + React (Vite)**, so the same design is built with the native equivalents:

| Requested | Implemented as |
|---|---|
| Prisma schema | `database/27-clubs-community.sql` (guarded, one transaction) generated from `scripts/migration-bodies/27-clubs-community.sql.txt` |
| Next.js API routes | `backend/CommunityEndpoints.cs` (minimal API, CSRF, rate limits) |
| Socket.io / Firebase | **SignalR** hub `/hubs/live` (WebSockets, with fallbacks). Messages are stored in SQL first, then pushed to each member's private group. The client never chooses what it listens to |
| Next.js components | `frontend/src/components/Courts.jsx`, `ClubManager.jsx`, `Chat.jsx`, `Rewards.jsx`, `GameAccess.jsx`, `AccountHub.jsx` |

All rules that protect money, places and privacy are enforced in SQL procedures (row locks, unique indexes, role checks), so they can't be bypassed from the browser.

### New tables
`Clubs`, `ClubStaff` (Owner/Manager/Reception/Coach), `Courts` (hours, slot length, standard/peak price and hours), `CourtBookings` (unique per court+start), `CourtBlocks`, `ClubExpenses`, `CoachProfiles`, `CoachSports`, `Classes` (+ weekly series), `ClassRegistrations` (with waitlist), `GameJoinRequests`, `Friendships`, `Conversations` (Direct/Game/Club), `Messages`, `ConversationReads`, `LoyaltyAccounts`, `LoyaltyLedger`, `Rewards`, `RewardRedemptions`, `Memberships`. `GamesAndEvents` gains `Visibility`, `JoinMode`, `InviteCode`.

## What each person can do

**Players**, via the **Courts** tab:
- Search clubs by town and sport, then choose a day to see each court's slots: green = free, yellow = peak, striped = blocked.
- Tap a free slot to book it instantly; you pay at the club, and free cancellation is allowed until 6 h before. Reward codes and the Pro discount apply automatically.
- Join classes, or their waitlist.
- Browse coaches.
- Message the club from its page.

**Games:**
- Every game shows "3/4 players · 1 free spot".
- The host chooses **Public · anyone joins**, **Public · I approve** or **Private · invite only**.
- Approval is enforced by database triggers on every way of taking a place or joining a waitlist. Players already in keep their places when rules change.
- Private games never appear in Discover. They open only for the host, players, requesters, accepted friends, or someone with the invite link.
- Each game has a group chat for its host and players.

**Chat:**
- Add friends by exact email; there's no public people search, for privacy.
- Chats come in three kinds: direct (friends only), game group chats, and club threads (player ↔ owner, manager or reception).
- Messages arrive live. If WebSockets are blocked, the app refreshes every 20 s.
- Re-sent messages aren't duplicated, and sending is limited to 20 messages a minute.

**Clubs** (Me → Club manager):

| Area | Who | What |
|---|---|---|
| Schedule | Reception+ | Tap a free slot **twice** to block it, and twice again to reopen it. Book walk-in guests. Cancel a booking (the player is notified). |
| Courts & prices | Manager+ | Opening hours, slot length (30/60/90/120 min), standard and peak price with peak hours, open/closed. |
| Classes | Manager+, or a coach for their own classes | One-off or weekly for up to 26 weeks, at the same Beirut time across summer-time changes. Optionally reserves a court, and refuses if a player booking overlaps. |
| Dashboard | Manager+ | Revenue (courts + classes that took place), expenses, **net profit**, occupancy %, daily revenue chart, busiest hours. |
| Staff & expenses | Owner | Add or remove managers, reception and coaches by GameOn email; record expenses. |

How clubs join: a GameOn operator links a club to its directory venue and names the owner, who must already have a GameOn account. Self-signup by clubs isn't offered, so nobody can claim a club they don't run.

## Play & Earn and GameOn Pro

**Points:**

| Action | Points | Notes |
|---|---|---|
| Court booking | +20 (+30 with Pro) | Reversed exactly if cancelled |
| Class | +15 | Earned once per class, even if you cancel and re-register |
| Game played | +50 | Only when host **and** player both confirm attendance (database trigger) |

- **Rewards:** 10% off a court for 200 points, 25% off for 450. Each gives a one-time code, valid 90 days. A cancelled booking returns the code. Club-specific rewards can be added in the `Rewards` table.
- **GameOn Pro:** $5 for 30 days (`Payments:ProMonthlyPrice`), paid from the wallet with no auto-renewal. Renewals extend the end date.
  - You get a partner-club discount set per club (0–50%), 50% more booking points, a **PRO** badge and 100 bonus points.
  - The badge marks a paying member, not an identity check.
- Every points balance always equals the sum of its ledger, and the tests check this.

## Honest limits and decisions for you

- **Court payments happen at the club.** The dashboard shows what players owe for bookings and classes that took place. It doesn't collect court money, and GameOn takes no commission. Paying courts from the wallet would add money flows that need club payouts and the same licensing caution as the wallet.
- **Club late cancellations and no-shows:** a player can cancel up to 6 h before. Inside 6 h they must call the club. The booking status supports `NoShow`, but there's no penalty: that's a business decision for each club.
- **Notifications** (inbox) still refresh on the existing timer. Only chat is pushed live. Pushing the inbox too is a small next step on the same hub.
- **Real-time at scale:** one API server is fine. With several servers, add a SignalR backplane (Azure SignalR Service or Redis).
- **Branding:** this follows the general idea of sports-club apps, but uses GameOn's own names, design and code. No Sportciety branding or assets are used.

## Tests (run here on a copy of your database)

- `28-clubs-community-tests.sql`: 47/47. Covers roles, slot grid, peak pricing, double booking, retries, blocks, cancellation and points reversal, Pro via wallet, partner discount, rewards, approval triggers, private games, chat privacy, recurring classes and their waitlist, and the dashboard permissions.
- `tests/community-flow.mjs`: 23/23 through the real API. Includes two players booking the same slot at the same moment (exactly one wins), live SignalR delivery and blocked cross-site connections.
- Earlier suites re-run: deposits 27, wallet 19, API 49, unit checks 36.
