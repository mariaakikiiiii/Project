# Engineering decisions and lab evidence

## Model and constraints

Users → Games (host), Sports → Games and Venues → Games are many-to-one. Users ↔ Games has two separate relations: confirmed Participations and queued Waitlists. Both enforce unique (GameId, UserId). GameActivityLogs is an append-only historical event table with foreign keys to the game and actor. All foreign keys use SQL Server's default NO ACTION: deleting referenced history, venues, hosts or games is restricted. Prefer a separately designed archival/deactivation workflow over deleting history.

The schema is in third normal form: sport/venue attributes are not copied into games, membership is separate from user/game attributes, and player count is calculated from memberships. A user can attend different games; there is no requirement to prevent overlapping bookings. Venue scheduling conflicts are also outside this scope. Hosts automatically enroll and can withdraw their participation; their host identity remains. Hosting-only games remain visible in My Games. Past games are read-only for membership changes. Capacity includes the host. Upgrade 7 permits host editing with a revision check and occupancy/sponsorship validation; changes notify the crew.

The database executor cannot write directly to tables. All allowed membership procedures lock the Games row with UPDLOCK, HOLDLOCK before reading counts or changing membership. Therefore transactions for one game execute serially, while other games proceed independently. Two requests for one remaining spot result in one participation and one waitlist entry. The same lock protects cancellation and promotion. A transaction failure rolls back the membership and audit event together. Do not add a second writer that bypasses this locking protocol. Cross-table exclusion and capacity are procedural invariants, not CHECK constraints; administrative direct writes must respect them. Identity-based FIFO is deterministic because queue allocation is serialized for that game. Gaps do not affect order. Retries of JoinGame and cancellation are idempotent; CreateGame is not, so do not automatically retry creation after an ambiguous network failure.

TRY/CATCH rolls back whenever XACT_STATE is nonzero, then rethrows preserving the SQL error. Procedures are intended as top-level application transactions. If a caller wraps them in an outer transaction, a failure rolls back that outer transaction too. SQL Server can still choose a deadlock victim in broader multi-game workloads; the API returns 503 for deadlocks/timeouts. Retry idempotent operations with bounded jitter. Never hide constraint violations or run count/select and insert on separate connections.

## Large-table performance

03-seed.sql inserts 200,000 synthetic activity rows with a set-based six-way tally cross join. It preserves existing data and rerunning tops up the fixture instead of doubling it. These events are performance fixtures, not a reconstruction of actual membership history. One game/actor intentionally has many events, exercising a high-volume entity; add realistic multi-game distributions before extrapolating production performance.

Two important queries are recent events for a game and recent events for a user. The indexes start with the equality filter, then the date range and deterministic pagination key. INCLUDE columns cover the narrow list projection without a clustered-key lookup. Avoid SELECT * for the event feed: fetching Details for every row would increase IO. The sequential clustered bigint identity makes inserts efficient; each secondary index has a write/storage cost. Do not add indexes for every possible filter without workload evidence.

06-performance.sql provides reproducible queries with STATISTICS IO and TIME. In SSMS enable the actual plan and inspect:

1. Seek predicates on GameId or ActorUserId plus the OccurredAt range; compare seek predicates with residual filters.
2. Actual versus estimated row counts. Large discrepancies suggest stale statistics or skew; seed refreshes statistics explicitly. Production auto-statistics must remain enabled.
3. Logical reads, CPU and elapsed time before/after a change, using identical parameters and representative warm-cache runs. Do not clear shared production caches for a lab benchmark.
4. Unexpected sorts, spills, scans of the whole table, and repeated key lookups. A scan can be appropriate for broad aggregates; a seek is not automatically faster.
5. Missing-index suggestions are hypotheses, not instructions. Consider overlapping indexes and write overhead.

Predicates use >= @From and < @Until, not CAST(OccurredAt AS date), preserving index range access. Keyset pagination uses both time and ActivityId rather than increasingly expensive OFFSET pages. Pass the last row's time and id together. OPTION(RECOMPILE) lets optional discovery filters/cursors specialize to their current values at a compilation cost; for high query rates compare cached specialized procedures and Query Store evidence. Discovery returns at most 100 upcoming games, and the activity feed at most 50 rows. My Games is unpaginated for this lab; add bounded keyset pagination for production histories. No performance numbers or execution-plan outcomes are claimed until measured on SQL Server.

## Security boundaries

Application passwords use ASP.NET Core Identity's salted, versioned PBKDF2 password hasher, not SQL HASHBYTES or reversible encryption. Login uses a signed, encrypted HttpOnly Secure SameSite=Strict authentication cookie. Unsafe API requests require an antiforgery token, including login, preventing login CSRF. After signing in/out the browser refreshes the token because its identity binding changes. The browser never receives a password hash or database credentials. No JWTs or passwords are stored in localStorage.

All ADO.NET calls set CommandType.StoredProcedure, explicitly name SqlDbType and string sizes, and use SQL parameters. Procedure names are fixed server code; there is no dynamic SQL. Validation complements parameters; it does not replace them. Authenticated claim UserId, never a client-supplied identity, controls join, leave, host and My Games. Public roster contains display names only. Audit history is reserved for DBA analysis; the runtime role has no grant to it.

The dedicated gameon_api SQL principal has EXECUTE on only the enumerated procedures, no table access or broad role membership. Ownership chaining allows the procedures' static dbo SQL to work without direct table grants. This is a trusted-server model: possession of the backend database connection permits invoking procedures for arbitrary user ids, so protect that credential. The browser must never connect directly to SQL Server. Migrations and data seeding use a separate privileged DBA identity, never the API identity.

Use a secret manager, environment injection or .NET user-secrets for ConnectionStrings:GameOn. Prefer integrated authentication where supported. With SQL authentication require Encrypt=True;TrustServerCertificate=False and a server certificate trusted by the client with a matching hostname. Never commit a connection string containing a password. Development HTTPS also requires trusted certificates; no TLS verification is disabled in the Vite proxy. Persist ASP.NET Data Protection keys securely when deploying multiple instances or restarting production, otherwise cookies may invalidate. The built-in IP rate limiter is per-process; production needs a shared limiter and trusted forwarded-header configuration behind a reverse proxy. Upgrade 7 adds single-use password recovery, a leased encrypted email outbox and session revocation. Email verification, MFA, account lockout, full observability and production retention policies remain future work.

## Concurrency lab (two independent SQL sessions)

Use a disposable database. Create a capacity-2 game with its host enrolled and two additional users A and B. Record the game and user ids. In session 1 execute (replace placeholders):

```sql
BEGIN TRANSACTION;
SELECT GameId FROM dbo.Games WITH (UPDLOCK,HOLDLOCK) WHERE GameId = <game>;
EXEC dbo.JoinGame @GameId=<game>, @UserId=<A>;
WAITFOR DELAY '00:00:08';
COMMIT;
```

During that delay in session 2 execute:

```sql
EXEC dbo.JoinGame @GameId=<game>, @UserId=<B>;
```

Session 2 must block until commit, then return Waitlisted. Assert count = 2, A is joined, B is queued, no user exists in both relations. Cancel A; B must be promoted atomically. Reverse the starting session order and repeat on a new game. Repeat with two simultaneous cancellations and joins on a full game with multiple queued users; assert no overbooking and FIFO promotion. 05-tests.sql separately checks sequential invariants and rolls back its fixtures. A passing sequential script alone does not prove concurrency.

## Platform upgrade

See [UPGRADE.md](UPGRADE.md) for additive migration, preference ranking, host-only editing/cancellation, sponsorship rules, notification polling, Maps Embed and password-email activation. See [payments-contract.md](payments-contract.md) for the pending provider integration boundary. No online funds are moved by the current app.
