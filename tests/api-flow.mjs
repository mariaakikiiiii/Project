// End-to-end API test against a RUNNING API connected to a DISPOSABLE *_Tests database.
// Real HTTP + real SQL Server. No money moves: Whish transfers/refunds are manual references only.
// Usage (PowerShell):
//   $env:NODE_EXTRA_CA_CERTS="$env:TEMP\gameon-dev.pem"; $env:GAMEON_TEST_DB="GameOn_Tests"
//   node tests/api-flow.mjs
import { execFileSync } from "node:child_process";
const BASE = process.env.GAMEON_API || "https://localhost:7043";
const DB = process.env.GAMEON_TEST_DB;
if (!DB || !/_Tests$/.test(DB)) { console.error("Set GAMEON_TEST_DB to a database ending in _Tests."); process.exit(2); }
const sql = (q) => execFileSync("sqlcmd", ["-S", "localhost", "-E", "-C", "-b", "-d", DB, "-h", "-1", "-W", "-Q", "SET NOCOUNT ON; " + q], { encoding: "utf8" }).trim();
const results = []; const check = (name, ok, extra = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : "  " + extra}`); };

class Client {
  constructor() { this.cookies = new Map(); this.csrf = null; }
  async req(path, method = "GET", body, { csrf = true } = {}) {
    if (csrf && method !== "GET" && !this.csrf) this.csrf = (await (await this.req("/api/csrf")).json()).token;
    const headers = { Cookie: [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; ") };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-CSRF-TOKEN"] = this.csrf;
    const r = await fetch(BASE + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const c of r.headers.getSetCookie?.() || []) { const [kv] = c.split(";"); const i = kv.indexOf("="); this.cookies.set(kv.slice(0, i), kv.slice(i + 1)); }
    return r;
  }
  async json(path, method, body, opt) { const r = await this.req(path, method, body, opt); const t = await r.text(); return { status: r.status, body: t ? JSON.parse(t) : null }; }
}
const tag = Date.now().toString(36);
const sports = (await (await fetch(BASE + "/api/lookups")).json()).sports.filter((s) => s.categorySlug === "sports").map((s) => s.sportId);
async function register(name) {
  const c = new Client();
  const r = await c.json("/api/auth/register", "POST", { email: `${name}.${tag}@gameon.invalid`, displayName: `${name} ${tag}`, password: "correct-horse-battery", gender: "PreferNotToSay", dateOfBirth: "2000-01-02", sportIds: [sports[0], sports[2]] });
  if (r.status !== 200) throw new Error(`register ${name}: ${r.status} ${JSON.stringify(r.body)}`);
  c.csrf = null; c.id = (await c.json("/api/auth/me")).body.userId; return c;
}

// --- Signup validation and auth boundaries
const anon = new Client();
check("Signup without gender/DOB rejected", (await anon.json("/api/auth/register", "POST", { email: `x.${tag}@gameon.invalid`, displayName: "X", password: "correct-horse-battery", sportIds: [sports[0]] })).status === 400);
check("Signup with 4 sports rejected", (await anon.json("/api/auth/register", "POST", { email: `y.${tag}@gameon.invalid`, displayName: "Y", password: "correct-horse-battery", gender: "Female", dateOfBirth: "2000-01-01", sportIds: sports.slice(0, 4) })).status === 400);
check("Signup with future DOB rejected", (await anon.json("/api/auth/register", "POST", { email: `z.${tag}@gameon.invalid`, displayName: "Z", password: "correct-horse-battery", gender: "Female", dateOfBirth: "2099-01-01", sportIds: [sports[0]] })).status === 400);
check("Guest cannot read private profile", (await anon.json("/api/me/profile")).status === 401);
check("Guest cannot open payments/deposits", (await anon.json("/api/me/deposits")).status === 401);
const host = await register("host"), p1 = await register("p1"), p2 = await register("p2"), op = await register("operator");
sql(`INSERT dbo.PaymentOperators(UserId) VALUES(${op.id});`);
check("Missing CSRF token rejected", (await p1.json("/api/games/1/participation", "DELETE", undefined, { csrf: false })).status === 400);
check("Login with wrong password rejected", (await new Client().json("/api/auth/login", "POST", { email: `p1.${tag}@gameon.invalid`, password: "wrong-password-123" })).status === 401);

// --- Venue directory: operator verifies a real listing's contact; players cannot
const venues = (await op.json("/api/operator/venues")).body;
const hariri = venues.find((v) => v.name.startsWith("Hariri Sports Complex"));
check("Researched venues present in directory", Boolean(hariri), "run database/24-lebanon-venue-directory.sql on the test DB");
const edit = { name: hariri.name, area: hariri.area, address: hariri.address, phone: hariri.contactPhoneNumber, subtypeIds: JSON.parse(hariri.subtypeIdsJson), contactVerified: true,
  listingStatus: hariri.listingStatus, sourceName: hariri.sourceName, sourceUrl: hariri.sourceUrl, sourceCheckedOn: String(hariri.sourceCheckedOn).slice(0, 10), reservationMode: "ContactVenue", note: "API test: contact verified on test database" };
check("Player cannot edit venues", (await p1.json(`/api/operator/venues/${hariri.venueId}/directory`, "PUT", edit)).status === 403);
check("Verified listing without source rejected", (await op.json(`/api/operator/venues/${hariri.venueId}/directory`, "PUT", { ...edit, sourceUrl: null })).status === 400);
check("Operator correction saved", (await op.json(`/api/operator/venues/${hariri.venueId}/directory`, "PUT", edit)).status === 200);
check("Search finds venue by town + sport", (await anon.json(`/api/venues/search?q=Saida&subtypeId=${sports[0]}`)).body.some((v) => v.venueId === hariri.venueId));

// --- Host creates a game: capacity 2 = host + one player
const start = new Date(Date.now() + 3 * 864e5).toISOString();
const created = await host.json("/api/games", "POST", { sportId: sports[0], venueId: hariri.venueId, startsAt: start, capacity: 2, costPerPlayer: 2, currency: "USD", description: "API test" });
check("Host creates game", created.status === 201, JSON.stringify(created.body));
const gameId = created.body.gameId;
check("Unauthenticated join rejected", (await anon.json(`/api/games/${gameId}/join`, "POST", {})).status === 401);
const game = (await p1.json(`/api/games/${gameId}`)).body;
check("Roster does not expose gender/DOB", !JSON.stringify(game.roster).match(/gender|dateOfBirth/i));
const quote = (await p1.json(`/api/games/${gameId}/deposit-quote?method=WhishManual`)).body;
console.log("      quote:", JSON.stringify(quote));
check("Quote: $2 share + $0.10 fee + $1 deposit = $3.10 due now", Number(quote.dueNow ?? quote.totalAmount) === 3.1, JSON.stringify(quote));

// --- Deposit checkout idempotency and race for the last seat
async function deposit(c, key) { return c.json(`/api/games/${gameId}/deposit-checkout`, "POST", { idempotencyKey: key, revision: game.game.revision, method: "WhishManual" }); }
const k1 = crypto.randomUUID();
const [a, b] = await Promise.all([deposit(p1, k1), deposit(p1, k1)]);
check("Duplicate checkout request returns one deposit", a.status === 200 && b.status === 200 && a.body.depositId === b.body.depositId, `${a.status} ${b.status}`);
const d2 = await deposit(p2, crypto.randomUUID());
check("Second player can start checkout while seat open", d2.status === 200, JSON.stringify(d2.body));
await p1.json(`/api/deposits/${a.body.depositId}/transfer`, "POST", { reference: `WT-${tag}-1` });
await p2.json(`/api/deposits/${d2.body.depositId}/transfer`, "POST", { reference: `WT-${tag}-2` });
check("Player cannot verify own transfer", (await p1.json(`/api/deposits/${a.body.depositId}/review`, "POST", { decision: "VERIFY", note: "self check" })).status === 403);
check("Forfeit decision disabled", (await op.json(`/api/deposits/${a.body.depositId}/review`, "POST", { decision: "FORFEIT", note: "no-show" })).status === 400);
const [v1, v2] = await Promise.all([
  op.json(`/api/deposits/${a.body.depositId}/review`, "POST", { decision: "VERIFY", note: "Matched Whish statement" }),
  op.json(`/api/deposits/${d2.body.depositId}/review`, "POST", { decision: "VERIFY", note: "Matched Whish statement" }),
]);
const statuses = sql(`SELECT DepositStatus FROM dbo.DepositBookings WHERE GameId=${gameId} ORDER BY DepositStatus`).split(/\s+/);
const seats = Number(sql(`SELECT COUNT(*) FROM dbo.Participations WHERE GameId=${gameId}`));
check("Concurrent verifications: exactly one seat granted, loser queued for refund", seats === 2 && statuses.join() === "PAID_HELD,REFUND_PENDING", `${v1.status}/${v2.status} seats=${seats} ${statuses}`);

// --- Trust info, host cancellation refunds, dispute
const trust = (await p1.json(`/api/games/${gameId}/trust`)).body.trust;
check("Trust panel reports verified contact and listing", trust.contactVerified === true && trust.listingStatus === "Verified");
check("Non-host cannot cancel", (await p1.json(`/api/games/${gameId}/cancel`, "POST")).status === 403);
check("Host cannot leave own game", (await host.json(`/api/games/${gameId}/participation`, "DELETE")).status === 400);
check("Host cancels game", (await host.json(`/api/games/${gameId}/cancel`, "POST")).status === 200);
check("Host cancellation queues every deposit for refund", sql(`SELECT COUNT(*) FROM dbo.DepositBookings WHERE GameId=${gameId} AND DepositStatus<>'REFUND_PENDING'`) === "0");
const refund = await op.json(`/api/deposits/${a.body.depositId}/review`, "POST", { decision: "REFUND", note: "Refund sent in Whish", refundReference: `RF-${tag}-1` });
check("Operator records refund with settlement reference", refund.status === 200 && refund.body.depositStatus === "REFUNDED", JSON.stringify(refund.body));
check("Refund reference cannot be reused", (await op.json(`/api/deposits/${d2.body.depositId}/review`, "POST", { decision: "REFUND", note: "reuse", refundReference: `RF-${tag}-1` })).status === 409);
const dispute = await p1.json(`/api/games/${gameId}/disputes`, "POST", { reason: "RefundNotReceived", details: "The refund has not arrived in my Whish wallet." });
check("Player opens refund dispute", dispute.status === 200, JSON.stringify(dispute.body));
const open = (await op.json("/api/disputes")).body.disputes.find((x) => x.gameId === gameId);
check("Operator sees open dispute", Boolean(open));
check("Operator resolves dispute", (await op.json(`/api/disputes/${open.disputeId}/resolve`, "POST", { outcome: "RefundOwed", note: "Refund bounced; resend" })).status === 200);
check("Host hold blocks hosting", (await op.json(`/api/operator/hosts/${host.id}/hold`, "POST", { hold: true, reason: "API test hold" })).status === 200
  && (await host.json("/api/games", "POST", { sportId: sports[0], venueId: hariri.venueId, startsAt: start, capacity: 4, costPerPlayer: 0, currency: "USD" })).status === 403);
check("Logout ends session", (await p1.json("/api/auth/logout", "POST")).status === 204 && (await p1.json("/api/me/profile")).status === 401);

const failed = results.filter((x) => !x).length;
console.log(`\n${results.length - failed}/${results.length} API checks passed (real API + ${DB}).`);
process.exit(failed ? 1 : 0);
