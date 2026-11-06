// End-to-end checks for clubs, courts, approval/private games, chat (live via SignalR), loyalty.
// Runs against a RUNNING API on a DISPOSABLE *_Tests database (refuses otherwise).
//   $env:NODE_EXTRA_CA_CERTS="$env:TEMP\gameon-dev.pem"; $env:GAMEON_API="https://localhost:7044"; $env:GAMEON_TEST_DB="GameOn_Tests"; node tests\community-flow.mjs
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
const require = createRequire(new URL("../frontend/package.json", import.meta.url));
const { HubConnectionBuilder, LogLevel } = require("@microsoft/signalr");
const BASE = process.env.GAMEON_API || "https://localhost:7043", DB = process.env.GAMEON_TEST_DB;
if (!DB || !/_Tests$/.test(DB)) { console.error("Set GAMEON_TEST_DB to a database ending in _Tests."); process.exit(2); }
const sql = (q) => execFileSync("sqlcmd", ["-S", "localhost", "-E", "-C", "-b", "-d", DB, "-h", "-1", "-W", "-Q", "SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; " + q], { encoding: "utf8" }).trim();
const results = []; const check = (n, ok, extra = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"}  ${n}${ok ? "" : "  " + extra}`); };
const tag = Date.now().toString(36);
sql(`INSERT dbo.Venues(Name,Area,Address,ListingStatus) VALUES(N'zz-test-marker-${tag}',N'Testville',N'Marker','Unverified')`);
const marker = await (await fetch(`${BASE}/api/venues/search?q=zz-test-marker-${tag}`)).json().catch(() => []);
if (!Array.isArray(marker) || marker.length !== 1) { console.error(`STOP: ${BASE} is not connected to ${DB}. Nothing was created.`); process.exit(3); }
const venueId = marker[0].venueId;

class Client {
  constructor() { this.cookies = new Map(); this.csrf = null; }
  cookie() { return [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; "); }
  async req(path, method = "GET", body, extraHeaders = {}) {
    if (method !== "GET" && !this.csrf) this.csrf = (await (await this.req("/api/csrf")).json()).token;
    const headers = { Cookie: this.cookie(), ...extraHeaders };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (method !== "GET") headers["X-CSRF-TOKEN"] = this.csrf;
    const go = () => fetch(BASE + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    let r = await go();
    if (r.status === 429 && !path.startsWith("/api/auth")) { await new Promise((ok) => setTimeout(ok, 61000)); r = await go(); }
    for (const c of r.headers.getSetCookie?.() || []) { const [kv] = c.split(";"); const i = kv.indexOf("="); this.cookies.set(kv.slice(0, i), kv.slice(i + 1)); }
    return r;
  }
  async json(path, method, body) { const r = await this.req(path, method, body); const t = await r.text(); return { status: r.status, body: t ? JSON.parse(t) : null }; }
}
const lookups = await (await fetch(BASE + "/api/lookups")).json();
const padel = lookups.sports.find((s) => s.slug === "padel").sportId;
async function register(name) {
  const c = new Client(); c.email = `${name}.${tag}@gameon.invalid`;
  const r = await c.json("/api/auth/register", "POST", { email: c.email, displayName: `${name} ${tag}`, password: "correct-horse-battery", gender: "PreferNotToSay", dateOfBirth: "2000-01-02", sportIds: [padel] });
  if (r.status !== 200) throw new Error(`register ${name}: ${r.status} ${JSON.stringify(r.body)}`);
  c.csrf = null; c.id = (await c.json("/api/auth/me")).body.userId; return c;
}
const op = await register("cop"), owner = await register("cowner"), p1 = await register("cp1"), p2 = await register("cp2");
sql(`INSERT dbo.PaymentOperators(UserId) VALUES(${op.id})`);

// Club onboarding & court setup
check("Player cannot onboard a club", (await p1.json("/api/operator/clubs", "POST", { venueId, name: "Nope", ownerEmail: p1.email })).status === 403);
const club = await op.json("/api/operator/clubs", "POST", { venueId, name: `Flow Padel ${tag}`, ownerEmail: owner.email, isPartner: true, proDiscountPct: 15 });
check("Operator onboards club with owner", club.status === 200, JSON.stringify(club.body));
const clubId = club.body.clubId;
const court = await owner.json(`/api/clubs/${clubId}/courts`, "POST", { name: "Court A", subtypeId: padel, slotMinutes: 60, openHour: 8, closeHour: 23, basePrice: 24, peakPrice: 32, peakStartHour: 18, peakEndHour: 22 });
check("Owner adds a court", court.status === 200, JSON.stringify(court.body));
check("Club listed for padel", (await p1.json(`/api/clubs?subtypeId=${padel}&q=Flow`)).body.clubs.some((c) => c.clubId === clubId));
const day = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Beirut" }).format(new Date(Date.now() + 2 * 864e5));
const sched = await p1.json(`/api/clubs/${clubId}/schedule?date=${day}`);
const free = sched.body.slots.filter((s) => s.slotStatus === "Free");
check("Schedule shows free slots with peak pricing", free.length === 15 && free.some((s) => s.isPeak && s.listPrice === 32), `${free.length}`);

// Race: two players tap the same slot at the same moment
const slot = free[2], k1 = crypto.randomUUID();
const [b1, b2] = await Promise.all([
  p1.json(`/api/courts/${court.body.courtId}/bookings`, "POST", { startsAtUtc: slot.startsAtUtc + "Z", idempotencyKey: k1 }),
  p2.json(`/api/courts/${court.body.courtId}/bookings`, "POST", { startsAtUtc: slot.startsAtUtc + "Z", idempotencyKey: crypto.randomUUID() })]);
const statuses = [b1.status, b2.status].sort().join();
check("Concurrent booking of one slot: exactly one wins, other gets a clear 409", statuses === "200,409" && sql(`SELECT COUNT(*) FROM dbo.CourtBookings WHERE CourtId=${court.body.courtId} AND Status='Confirmed'`) === "1", `${statuses} ${JSON.stringify(b2.body)}`);
const winner = b1.status === 200 ? p1 : p2, winnerKey = b1.status === 200 ? k1 : null;
if (winnerKey) check("Retried booking returns the same booking", (await p1.json(`/api/courts/${court.body.courtId}/bookings`, "POST", { startsAtUtc: slot.startsAtUtc + "Z", idempotencyKey: k1 })).body.bookingId === b1.body.bookingId);
check("Booking earned 20 points", (await winner.json("/api/me/rewards")).body.summary.points === 20);
const blockSlot = free[5];
check("Player cannot block", (await p1.json(`/api/courts/${court.body.courtId}/block-toggle`, "POST", { startsAtUtc: blockSlot.startsAtUtc + "Z" })).status === 403);
check("Owner blocks a slot", (await owner.json(`/api/courts/${court.body.courtId}/block-toggle`, "POST", { startsAtUtc: blockSlot.startsAtUtc + "Z", reason: "Repairs" })).body?.status === "Blocked");
check("Blocked slot cannot be booked", (await p2.json(`/api/courts/${court.body.courtId}/bookings`, "POST", { startsAtUtc: blockSlot.startsAtUtc + "Z", idempotencyKey: crypto.randomUUID() })).status === 409);
check("Dashboard: owner yes, player no", (await owner.json(`/api/clubs/${clubId}/dashboard`)).status === 200 && (await p1.json(`/api/clubs/${clubId}/dashboard`)).status === 403);

// Approval & private games
const start = new Date(Date.now() + 3 * 864e5).toISOString();
const game = await owner.json("/api/games", "POST", { sportId: padel, venueId, startsAt: start, capacity: 4, costPerPlayer: 0, currency: "USD" });
check("Host creates game", game.status === 201, JSON.stringify(game.body));
const gid = game.body.gameId;
await owner.json(`/api/games/${gid}/access`, "PUT", { visibility: "Public", joinMode: "Approval" });
check("Player asks to join", (await p2.json(`/api/games/${gid}/join-requests`, "POST", { message: "Intermediate" })).body?.status === "Pending");
const acc = await owner.json(`/api/games/${gid}/access`);
check("Host sees request with message; spots shown", acc.body.requests.some((r) => r.userId === p2.id && r.message === "Intermediate") && acc.body.access.freeSpots === 3);
check("Host approves", (await owner.json(`/api/games/${gid}/join-requests/${p2.id}`, "POST", { approve: true })).body?.status === "Approved");
const priv = await owner.json(`/api/games/${gid}/access`, "PUT", { visibility: "Private", joinMode: "Approval" });
const code = priv.body.inviteCode;
check("Private game hidden from strangers (details 404, not in discovery)", (await p1.json(`/api/games/${gid}`)).status === 404 && !(await p1.json("/api/games")).body.some((g) => g.gameId === gid));
check("Invite link opens the private game", (await p1.json(`/api/games/${gid}?invite=${code}`)).status === 200 && (await p1.json(`/api/games/${gid}/join-requests`, "POST", { inviteCode: code })).body?.status === "Approved");

// Friends + live chat over SignalR
await p1.json("/api/me/friends", "POST", { action: "Request", email: p2.email });
check("Friend request accepted", (await p2.json("/api/me/friends", "POST", { action: "Accept", userId: p1.id })).body?.status === "Accepted");
const conv = (await p1.json("/api/chats", "POST", { kind: "Direct", userId: p2.id })).body.conversationId;
const csrf2 = (await (await p2.req("/api/csrf")).json()).token;
const hub = new HubConnectionBuilder().withUrl(`${BASE}/hubs/live`, { headers: { Cookie: p2.cookie(), "X-CSRF-TOKEN": csrf2, Origin: BASE } }).configureLogging(LogLevel.None).build();
let liveOk = false;
try {
  await hub.start();
  const got = new Promise((ok) => hub.on("message", (m) => { if (m.conversationId === conv && m.body === "Padel at 8?") ok(true); }));
  await p1.json(`/api/chats/${conv}/messages`, "POST", { body: "Padel at 8?", clientKey: crypto.randomUUID() });
  liveOk = await Promise.race([got, new Promise((ok) => setTimeout(() => ok(false), 5000))]);
} catch (e) { console.log("      hub error:", e.message); }
check("Message delivered live to the friend via SignalR (WebSocket)", liveOk, hub.connection?.transport?.constructor?.name || "");
await hub.stop();
const evil = await fetch(`${BASE}/hubs/live/negotiate?negotiateVersion=1`, { method: "POST", headers: { Cookie: p2.cookie(), "X-CSRF-TOKEN": csrf2, Origin: "https://evil.example" } });
check("Cross-site origin cannot open the live connection", evil.status === 403, String(evil.status));
check("Outsider cannot read the chat", (await owner.json(`/api/chats/${conv}/messages`)).status === 403);
const gconv = (await p2.json("/api/chats", "POST", { kind: "Game", gameId: gid })).body?.conversationId;
check("Approved player can use the game chat", typeof gconv === "number" || typeof gconv === "string");

const failed = results.filter((x) => !x).length;
console.log(`\n${results.length - failed}/${results.length} community checks passed (real API + ${DB}).`);
process.exit(failed ? 1 : 0);
