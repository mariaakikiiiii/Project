# Update 29: features matched to Sportciety

Sources reviewed on 2026-11-06: Sportciety's App Store listing, its "Sportciety Management" App Store listing, and sportcietyapp.com. GameOn uses its own wording, design and code; nothing was copied from their apps or site.

## Install

1. Stop the API and Vite. Back up GameOn in SSMS.
2. SSMS → `database\29-club-suite.sql` → **F5** → `Migration 29 completed successfully` (needs 27).
3. `frontend`: `npm ci` (adds the QR-code library), then `npm run dev`. API: **F5**.
4. Optional on a `_Tests` copy: `database\30-club-suite-tests.sql` (40 checks).

Uploaded photos are saved in `backend\App_Data\shots` (ignored by Git). To store them elsewhere, set `Storage:ShotsPath` in User Secrets.

## Feature comparison

| Sportciety | GameOn |
|---|---|
| Court booking, classes, trainers, public games, friends & chat, Play & Earn, Pro badge and partner discounts, 2-tap court blocking, peak hours, recurring classes, dashboard with net profit, staff roles | Already built (update 27) |
| Pay bookings from an in-app wallet | **New**: pay a court from the GameOn wallet. Cancelling in time, or a club declining, refunds the wallet instantly. |
| Club approves bookings (Approve/Decline) | **New**: per-court "requires approval". The slot is held while pending; staff approve or decline in Club manager → Requests. |
| Gym memberships, QR entry, visit history | **New**: clubs sell memberships. Players get a QR code under Me → Memberships; staff scan it (camera) or type the code; visits are recorded. |
| Class packages and bundles | **New**: class packs (e.g. 10 classes in 90 days). "Use pack credit" when joining; cancelling gives the credit back. |
| Live class attendance | **New**: staff or the class coach mark present/absent. |
| Player groups, group chat, booking games with the group | **New**: groups of friends, a group chat, and "Invite one of my groups" on a game (members are pre-approved, even for private games). |
| CRM and broadcast messaging | **New**: customer list with bookings, cancellations, classes, spend, membership and last visit, plus one broadcast a day to recent customers. |
| Inventory | **New**: items, stock movements (restock, sale, use, damage), low-stock alerts. |
| Staff activity log, payroll and commission | **New**: an audit log of staff actions, monthly payroll with automatic coach commission (recorded as an expense, so net profit is accurate). |
| "Shots" community highlights | **New**: photo sharing with likes, report, and delete. Photos are checked to be real images (max 3 MB) and hidden location data is removed. Three reports hide a photo automatically. |
| Clubs get paid | **New**: in-app money is held as the club's balance. GameOn operators pay it out and record the reference (Wallet page → Operator: club payouts). |

## Not done, and why

- **Online card / Suyool / Whish payment buttons.** These need merchant contracts and APIs from those providers. The wallet still uses operator-checked Whish top-ups.
- **Arabic, French and Spanish.** This is a large translation job, and Arabic also needs a right-to-left layout. It's planned as its own update.
- **Video in Shots.** Video needs storage, transcoding and moderation, so only photos are supported for now.
- **Sports news feed.** It needs a licensed news source.
- **Phone push notifications** need a native app or web-push setup. The in-app inbox and live chat work today.

## Money rules (unchanged principles)

- Every wallet and club balance equals its ledger. The tests check this after every run.
- A payment, refund or payout is recorded only once, and payout references can't be reused.
- Players pay only for what's confirmed: declined requests and cancellations made in time are refunded to the wallet straight away.
- Holding money for players and clubs is regulated activity. Get legal advice in Lebanon before going live.

## Tests run on a copy of the database

- `30-club-suite-tests.sql`: 40/40.
- `tests/club-suite-flow.mjs`: 33/33 through the real API, including the photo checks (location data removed, fake image refused, oversized refused).
- Earlier suites re-run after this change: SQL 27 + 19 + 47, API 49 + 23.
