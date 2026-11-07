# GameOn: Project Defense Guide

Everything here matches the real code and database. If the examiner opens Visual Studio or SSMS, what they see agrees with what you say.

---

## 1. One-minute pitch

**GameOn** is a sports community platform for Lebanon. Players find a game with free spots (padel, football, basketball, karting…), reserve a place, book a court at a club, join classes, chat, and earn points. Clubs get a management side: schedule, prices, staff, memberships, and a revenue dashboard. Admins moderate users and settings.

**The problem it solves:** pickup games fail because people don't show up, and court booking in Lebanon is done by phone. GameOn adds a **$1 refundable commitment deposit**, online court booking, and verified venue information.

---

## 2. Tech stack (the real one)

```
 Browser ── React 19 + Vite (frontend/)
    │  HTTPS, JSON, same origin (Vite proxies /api and /hubs)
    ▼
 ASP.NET Core 8 minimal API (backend/)  ── SignalR hub /hubs/live (live chat)
    │  ADO.NET (Microsoft.Data.SqlClient), stored procedures only
    ▼
 SQL Server ── database "GameOn" (GameOn.mdf + GameOn_log.ldf)
```

| Layer | Technology | Why |
|---|---|---|
| Frontend | React 19, Vite, plain CSS (dark/light theme), Leaflet + Google Maps embed, QR codes | Fast single-page app that works on phones |
| Backend | C# ASP.NET Core 8 minimal APIs | Typed, fast, built-in authentication, CSRF protection, rate limiting, SignalR |
| Data access | **ADO.NET, no ORM**. Every call is a stored procedure with typed `SqlParameter`s | Full control of SQL, transactions and locks; no SQL injection |
| Database | SQL Server 2022, managed in SSMS | ACID transactions, row locks, constraints, filtered unique indexes |
| Real-time | SignalR (WebSockets) | Live chat between players, hosts and clubs |

**Size:** 71 tables, 140 stored procedures, 10 triggers, 16 migrations (versions 7 → 31).

> If asked "Why not Node/Express?": .NET gives typed parameters, a built-in password hasher, antiforgery and SignalR in one framework, and ADO.NET works naturally with stored procedures and SQL Server locks.

---

## 3. How the backend talks to the database

1. **Connection string** is stored in Visual Studio **User Secrets** (`ConnectionStrings:GameOn`), never in Git. It uses a dedicated login **`gameon_api`**, not `sa`, with `Encrypt=True`.
2. **Least privilege:** `gameon_api` belongs to the role `gameon_executor`, which may only **EXECUTE stored procedures**. It can't read or change tables directly.
3. **Every request:** endpoint → validate input → `Database.Call("dbo.ProcName", parameters…)` (`backend/Database.cs`) → `SqlCommand` with `CommandType.StoredProcedure` → rows returned as JSON.
4. **Business rules live in SQL:** locking, money and permission checks happen inside procedures, so the browser can't bypass them.

Example (real code, `backend/Program.cs`):
```csharp
await db.Call("dbo.CancelParticipation", ct,
    P("@GameId", SqlDbType.Int, id),
    P("@UserId", SqlDbType.Int, UserId(user)));
```

---

## 4. Database design

### 4.1 Files on disk
| File | Role |
|---|---|
| `GameOn.mdf` | Primary data file: tables, indexes, procedures |
| `GameOn_log.ldf` | Transaction log: every change is written here first, which makes **COMMIT / ROLLBACK** and recovery possible |
| `.ndf` | Optional secondary data file (not used; for spreading data across disks) |

### 4.2 Main tables
| Area | Tables |
|---|---|
| Accounts | `Users` (hashed password, gender/DOB kept private, `AccountStatus`, `SessionStamp`), `UserSportPreferences` (1–3 sports), `Admins`, `PaymentOperators` |
| Games | `GamesAndEvents` (capacity, visibility, join mode), `Participations` (who has a place), `Waitlists`, `GameJoinRequests` (host approval) |
| Venues & clubs | `Venues` (source + check date, Demo/Unverified/Verified), `Clubs`, `ClubStaff` (Owner/Manager/Reception/Coach), `Courts` (hours, peak price), `CourtBookings`, `CourtBlocks`, `Classes` |
| Money | `DepositBookings` ($1 deposit), `WalletAccounts` + `WalletLedger`, `WalletTopUps`, `WalletWithdrawals`, `ClubLedger`, `Payments` |
| Trust | `EventAttendance`, `EventCompletions`, `DepositDisputes` |
| Community | `Friendships`, `Conversations`, `Messages`, `PlayerGroups`, `Shots` (photos) |
| Rewards | `LoyaltyLedger`, `Rewards`, `RewardRedemptions`, `Memberships` (Pro) |
| Audit | `AdminAudit`, `StaffActivity`, `GameActivityLogs` (200,000+ rows for analytics testing) |

### 4.3 Integrity rules, enforced by the database
- **Primary keys** on every table; **foreign keys** between users, games, venues and bookings.
- **CHECK constraints**: capacity 2–100, deposit exactly $1.00, fee = 5% of the share, wallet balance between 0 and 500, statuses only from allowed lists.
- **Filtered unique indexes** that make double actions impossible:
  - one booking per court slot (`UX_CB_Slot`);
  - one refund per reference (`UX_Deposit_RefundReference`);
  - each money event posted once (`UX_Ledger_*`).

---

## 5. The questions you'll most likely get

### Q: How do you prevent double booking? (concurrency)
Two layers:
1. **Lock:** the booking procedure locks the court (or game) row with `WITH (UPDLOCK, HOLDLOCK)` inside a transaction. A second person trying at the same instant waits, then sees the slot is taken.
2. **Backstop:** a filtered unique index allows only one active booking per court and start time.

**Tested:** two players booked the same slot at the same moment, and exactly one succeeded while the other got "Someone just booked this slot."

Real pattern (`dbo.BookCourt`):
```sql
BEGIN TRANSACTION;
SELECT @Club = ClubId, ... FROM dbo.Courts WITH (UPDLOCK, HOLDLOCK) WHERE CourtId = @CourtId;
IF EXISTS (SELECT 1 FROM dbo.CourtBookings
           WHERE CourtId = @CourtId AND Status IN ('Pending','Confirmed','Completed','NoShow')
             AND StartsAt < @End AND EndsAt > @StartsAtUtc)
    THROW 50004, 'Someone just booked this slot. Pick another time.', 1;
INSERT dbo.CourtBookings (...) VALUES (...);
COMMIT;
```

### Q: What if a user double-clicks "Pay"? (duplicate requests)
Every payment action sends an **idempotency key** (a GUID). The table has `UNIQUE(UserId, IdempotencyKey)`, so a repeated request returns the first result instead of charging again.

### Q: How does the money work? (be accurate)
- **5% platform fee** on the game share, plus a separate **$1 commitment deposit** when joining a game.
  - Example: a $2 share costs $2 + $0.10 fee + $1 deposit = **$3.10**.
- **The $1 comes back** if the host cancels, or after the game when **both** the host and the player confirm attendance. Neither side can trigger the refund alone; a disagreement opens a dispute.
- **Whish:** GameOn does **not** have a Whish merchant API. Players send money to GameOn's Whish number and enter the transaction reference. A **payment operator** checks the real Whish statement before it counts. A typed reference alone is never treated as proof of payment.
- **Wallet:** after a verified top-up, joining a game costs $1 from the wallet and the place is confirmed **instantly**. Refunds go back to the wallet straight away.
- **Ledger:** every balance equals the sum of its ledger rows (append-only), and the tests check this.

### Q: How are passwords and sessions protected?
- Passwords are hashed with ASP.NET's `PasswordHasher` (PBKDF2, **210,000 iterations**, salted). Plain passwords are never stored.
- The login cookie `GameOn.Session` is **HttpOnly, Secure, SameSite=Strict** and expires after 8 hours.
- Every request re-checks the account in the database: suspended accounts and old cookies (via `SecurityVersion` and `SessionStamp`) are rejected.
- **CSRF:** every state-changing request needs the `X-CSRF-TOKEN` header.
- **Rate limits:** 10 sign-in attempts/min, 30 payment actions/min, 120 page reads/min per IP.
- A wrong password and an unknown email give the same answer, "Invalid credentials", so attackers can't discover which emails exist.

### Q: How do you stop SQL injection?
Only stored procedures with typed parameters (`SqlParameter` with `SqlDbType`). User text is never concatenated into SQL.

### Q: What about privacy?
- Gender and date of birth are only visible to the user themselves.
- Friends are added by exact email (no public user search).
- Hidden GPS data is stripped from uploaded photos.
- Deleting an account erases personal data while keeping anonymous booking and payment records.

### Q: Who can do what? (roles)
| Role | Can |
|---|---|
| Player | Join and host games, book courts, chat, wallet, rewards |
| Club staff | Owner, Manager, Reception or Coach, each with different permissions (checked in SQL by `dbo.ClubRoleRank`) |
| Payment operator | Verify Whish transfers, refunds, disputes, club payouts. Can never approve their own money |
| Admin | Suspend, restore and delete users, give roles, change app settings, moderate photos. Can't remove the last admin |

### Q: How do you change the database safely? (migrations)
Each change is a numbered migration (`database/22…31`) that:
- runs as **one transaction**, so it either fully applies or changes nothing;
- checks that the previous version exists;
- refuses to run twice;
- is recorded in `dbo.PlatformMigrations`.

### Q: How did you test it?
- **SQL test scripts** (`database/23, 26, 28, 30, 32`): about 150 checks, run on a disposable copy (`GameOn_Tests`), never on the real database.
- **End-to-end scripts** (`tests/*.mjs`) call the real API: about 125 checks, including the double-booking race, live chat delivery and photo security.
- **Unit checks** (`tests/GameOn.PaymentChecks`): 36 checks covering fee rounding, map validation and signup rules.

### Q: What would you do next for production?
- A Whish merchant API for automatic payment confirmation and refunds.
- Arabic and French with a right-to-left layout.
- A mobile app (React Native, reusing the same API) with push notifications.
- Hosting in the cloud with a managed database.
- Legal advice on holding customer money: the wallet is likely e-money under Banque du Liban rules.

### Q: What are the honest limitations?
- No Whish merchant API, so payments are verified manually by an operator.
- The full Google map with clickable venue listings needs a paid Google key.
- The venue directory is a starter list with sources, not every court in Lebanon.
- Court payments can also be made at the club.

---

## 6. Live demo in SSMS (5 minutes)

1. Open **SSMS** → Server name `localhost` → **Windows Authentication** → tick **Trust server certificate** → **Connect**.
2. **Object Explorer** → **Databases** → **GameOn** → **Tables**: show `Users`, `GamesAndEvents`, `CourtBookings`, `WalletLedger`.
3. **Programmability → Stored Procedures**: open `dbo.BookCourt` and point at `UPDLOCK, HOLDLOCK`.
4. Click **New Query** and run the queries below. Each has been tested on the GameOn database.

**Upcoming games and free spots**
```sql
USE GameOn;
SELECT TOP 10 g.GameId, g.Sport, g.Venue, g.Area, g.StartsAt,
       g.PlayerCount, g.Capacity, g.Capacity - g.PlayerCount AS FreeSpots
FROM dbo.GameSummary g
WHERE g.GameStatus = 'Open' AND g.StartsAt > SYSUTCDATETIME()
ORDER BY g.StartsAt;
```

**Players in a game (JOIN)**
```sql
SELECT g.EventId AS GameId, s.Name AS Sport, u.DisplayName, p.JoinedAt, p.DepositStatus
FROM dbo.Participations p
JOIN dbo.Users u          ON u.UserId = p.UserId
JOIN dbo.GamesAndEvents g ON g.EventId = p.GameId
JOIN dbo.Subtypes s       ON s.SubtypeId = g.SubtypeId
ORDER BY g.EventId, p.JoinedAt;
```

**Platform fee revenue (aggregation)**
```sql
SELECT COUNT(*) AS Payments, SUM(Amount) AS GameShares, SUM(ServiceFee) AS PlatformFees
FROM dbo.Payments
WHERE Status IN ('VerifiedManual', 'PendingCash');
```

**Deposits by status**
```sql
SELECT DepositStatus, COUNT(*) AS Deposits, SUM(DepositAmount) AS Amount
FROM dbo.DepositBookings
GROUP BY DepositStatus;
```

**Proof the money adds up (balance = ledger)**
```sql
SELECT a.UserId, a.Balance,
       (SELECT COALESCE(SUM(l.Amount), 0) FROM dbo.WalletLedger l WHERE l.UserId = a.UserId) AS LedgerSum
FROM dbo.WalletAccounts a;
```

**Roles**
```sql
SELECT u.UserId, u.Email, u.AccountStatus,
       CASE WHEN a.UserId IS NOT NULL THEN 'Admin' ELSE '' END AS AdminRole,
       CASE WHEN o.UserId IS NOT NULL THEN 'Operator' ELSE '' END AS OperatorRole
FROM dbo.Users u
LEFT JOIN dbo.Admins a           ON a.UserId = u.UserId
LEFT JOIN dbo.PaymentOperators o ON o.UserId = u.UserId
WHERE u.PasswordHash <> 'DISABLED_FIXTURE';
```

**Schema version history**
```sql
SELECT Version, AppliedAt FROM dbo.PlatformMigrations ORDER BY Version;
```

---

## 7. Live demo in the app (5 minutes)

1. Visual Studio: **GameOn.Api** → **F5**. PowerShell in `frontend`: `npm run dev`. Open http://localhost:5173/.
2. **Signed out:** only Discover, Courts and Venues appear. Signup requires gender, birth date and 1–3 sports.
3. **Venues:** choose a sport and search "Jounieh"; the Google map follows the search.
4. **Game page:** "3/4 players · 1 free spot", the fee breakdown ($3.10 example), and the trust panel.
5. **Me → Admin panel:** user list, suspend and restore, the announcement banner going live.
6. **Club manager:** tap a slot twice to block it; the dashboard shows revenue and net profit.

---

## 8. Project folders

```
GameOn.sln
backend/            ASP.NET Core API
  Program.cs          startup, authentication, CSRF, rate limits, game endpoints
  Database.cs         ADO.NET stored-procedure caller
  CommunityEndpoints.cs, ClubSuiteEndpoints.cs, AdminEndpoints.cs, AttendanceEndpoints.cs
  Payments/           deposits, wallet, Whish boundary
frontend/src/       React app (main.jsx + components/)
database/           schema, numbered migrations, SQL test scripts
scripts/            migration generator (readable templates → safe migration files)
tests/              end-to-end and unit tests
docs/               setup guides (UPDATE-22/25/27/29, ADMIN, this guide)
```
