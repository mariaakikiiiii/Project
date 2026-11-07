// End-to-end checks for migration 29 features through the real API on a DISPOSABLE *_Tests database.
//   $env:NODE_EXTRA_CA_CERTS="$env:TEMP\gameon-dev.pem"; $env:GAMEON_API="https://localhost:7044"; $env:GAMEON_TEST_DB="GameOn_Tests"; node tests\club-suite-flow.mjs
import { execFileSync } from "node:child_process";
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
  async raw(path, method = "GET", body, headers = {}) {
    if (method !== "GET" && !this.csrf) this.csrf = (await (await this.raw("/api/csrf")).json()).token;
    const h = { Cookie: this.cookie(), ...headers }; if (method !== "GET") h["X-CSRF-TOKEN"] = this.csrf;
    const go = () => fetch(BASE + path, { method, headers: h, body });
    let r = await go();
    if (r.status === 429 && !path.startsWith("/api/auth")) { await new Promise((ok) => setTimeout(ok, 61000)); r = await go(); }
    for (const c of r.headers.getSetCookie?.() || []) { const [kv] = c.split(";"); const i = kv.indexOf("="); this.cookies.set(kv.slice(0, i), kv.slice(i + 1)); }
    return r;
  }
  async json(path, method, body) { const r = await this.raw(path, method, body === undefined ? undefined : JSON.stringify(body), body === undefined ? {} : { "Content-Type": "application/json" }); const t = await r.text(); return { status: r.status, body: t ? JSON.parse(t) : null }; }
}
const lookups = await (await fetch(BASE + "/api/lookups")).json();
const padel = lookups.sports.find((s) => s.slug === "padel").sportId;
async function register(name) {
  const c = new Client(); c.email = `${name}.${tag}@gameon.invalid`;
  const r = await c.json("/api/auth/register", "POST", { email: c.email, displayName: `${name} ${tag}`, password: "correct-horse-battery", gender: "PreferNotToSay", dateOfBirth: "2000-01-02", sportIds: [padel] });
  if (r.status !== 200) throw new Error(`register ${name}: ${r.status} ${JSON.stringify(r.body)}`);
  c.csrf = null; c.id = (await c.json("/api/auth/me")).body.userId; return c;
}
const op = await register("sop"), owner = await register("sowner"), p1 = await register("sp1"), p2 = await register("sp2");
sql(`INSERT dbo.PaymentOperators(UserId) VALUES(${op.id})`);
const clubId = (await op.json("/api/operator/clubs", "POST", { venueId, name: `Suite Club ${tag}`, ownerEmail: owner.email })).body.clubId;
const courtId = (await owner.json(`/api/clubs/${clubId}/courts`, "POST", { name: "Court 1", subtypeId: padel, slotMinutes: 60, openHour: 8, closeHour: 23, basePrice: 20, peakPrice: 30, peakStartHour: 18, peakEndHour: 22 })).body.courtId;
// Fund p1's wallet through the real top-up flow.
const top = (await p1.json("/api/me/wallet/top-ups", "POST", { idempotencyKey: crypto.randomUUID(), amount: 100 })).body;
await p1.json(`/api/me/wallet/top-ups/${top.topUpId}/reference`, "POST", { reference: `ST-${tag}` });
await op.json(`/api/operator/wallet/top-ups/${top.topUpId}`, "POST", { decision: "VERIFY", note: "On statement" });
const bal = async (c) => Number((await c.json("/api/me/wallet")).body.summary.balance);
check("Wallet funded with $100", (await bal(p1)) === 100);

const day = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Beirut" }).format(new Date(Date.now() + 2 * 864e5));
const slots = (await p1.json(`/api/clubs/${clubId}/schedule?date=${day}`)).body.slots.filter((s) => s.slotStatus === "Free");
// Pay a court from the wallet
const k = crypto.randomUUID();
const b1 = await p1.json(`/api/courts/${courtId}/bookings`, "POST", { startsAtUtc: slots[1].startsAtUtc + "Z", idempotencyKey: k, payFromWallet: true });
await p1.json(`/api/courts/${courtId}/bookings`, "POST", { startsAtUtc: slots[1].startsAtUtc + "Z", idempotencyKey: k, payFromWallet: true });
check("Court paid from wallet once (double tap)", b1.status === 200 && b1.body.paidFromWallet === true && (await bal(p1)) === 80, JSON.stringify(b1.body));
check("Cancel returns the money to the wallet", (await p1.json(`/api/court-bookings/${b1.body.bookingId}`, "DELETE")).status === 200 && (await bal(p1)) === 100);
check("Empty wallet: clear 402, nothing booked", (await p2.json(`/api/courts/${courtId}/bookings`, "POST", { startsAtUtc: slots[2].startsAtUtc + "Z", idempotencyKey: crypto.randomUUID(), payFromWallet: true })).status === 402);

// Approval flow
check("Owner turns on booking approval", (await owner.json(`/api/courts/${courtId}/approval`, "PUT", { requiresApproval: true })).body?.requiresApproval === true);
const req = await p1.json(`/api/courts/${courtId}/bookings`, "POST", { startsAtUtc: slots[3].startsAtUtc + "Z", idempotencyKey: crypto.randomUUID(), payFromWallet: true });
check("Booking becomes a request (Pending)", req.body?.status === "Pending", JSON.stringify(req.body));
const pend = (await owner.json(`/api/clubs/${clubId}/pending`)).body;
check("Club sees the request", Array.isArray(pend) && pend.some((x) => x.bookingId === req.body.bookingId));
check("Player cannot approve", (await p2.json(`/api/court-bookings/${req.body.bookingId}/decision`, "POST", { approve: true })).status === 403);
check("Decline refunds the wallet", (await owner.json(`/api/court-bookings/${req.body.bookingId}/decision`, "POST", { approve: false })).body?.status === "Declined" && (await bal(p1)) === 100);

// Memberships with QR check-in, class packs
const mem = (await owner.json(`/api/clubs/${clubId}/products`, "POST", { kind: "Membership", name: "Gym month", price: 25, durationDays: 30 })).body.productId;
const pack = (await owner.json(`/api/clubs/${clubId}/products`, "POST", { kind: "ClassPack", name: "3 classes", price: 21, durationDays: 60, credits: 3 })).body.productId;
const bought = await p1.json(`/api/products/${mem}/buy`, "POST", { idempotencyKey: crypto.randomUUID() });
check("Membership bought from wallet", bought.status === 200 && (await bal(p1)) === 75, JSON.stringify(bought.body));
const passes = (await p1.json("/api/me/passes")).body.passes;
const code = passes.find((p) => p.kind === "Membership").accessCode;
check("Pass has a 12-character QR code", /^[A-F0-9]{12}$/.test(code));
check("Player cannot check people in", (await p2.json(`/api/clubs/${clubId}/check-in`, "POST", { code })).status === 403);
const ci = await owner.json(`/api/clubs/${clubId}/check-in`, "POST", { code });
check("Staff check-in shows the member", ci.status === 200 && ci.body.displayName.startsWith("sp1") && ci.body.visits === 1, JSON.stringify(ci.body));
check("Visit appears in the player's history", (await p1.json("/api/me/passes")).body.visits.length === 1);
await p1.json(`/api/products/${pack}/buy`, "POST", { idempotencyKey: crypto.randomUUID() });
const first = new Date(Date.now() + 3 * 864e5); first.setUTCMinutes(0, 0, 0);
await owner.json(`/api/clubs/${clubId}/classes`, "POST", { title: "Drills", subtypeId: padel, firstStartsAtUtc: first.toISOString(), durationMinutes: 60, capacity: 6, price: 7, weeks: 1 });
const classId = Number(sql(`SELECT MAX(ClassId) FROM dbo.Classes WHERE ClubId=${clubId}`));
const packId = (await p1.json("/api/me/passes")).body.passes.find((p) => p.kind === "ClassPack").purchaseId;
const reg = await p1.json(`/api/classes/${classId}/pack-registration`, "POST", { purchaseId: packId });
check("Class booked with a pack credit", reg.body?.status === "Registered" && reg.body.creditsLeft === 2, JSON.stringify(reg.body));
check("Class roster visible to staff only", (await owner.json(`/api/classes/${classId}/roster`)).body.length === 1 && (await p2.json(`/api/classes/${classId}/roster`)).status === 403);

// CRM, inventory, back office, payout
const crm = (await owner.json(`/api/clubs/${clubId}/customers`)).body;
check("CRM lists the customer with spend", crm.customers.some((c) => c.userId === p1.id && Number(c.spend) === 46), JSON.stringify(crm.customers));
check("Broadcast reaches customers", (await owner.json(`/api/clubs/${clubId}/broadcasts`, "POST", { title: "New lights", body: "Court 1 now has LED lights for night games." })).body?.recipients === 1);
const item = (await owner.json(`/api/clubs/${clubId}/inventory`, "POST", { name: "Balls", unit: "tube", reorderLevel: 2 })).body.itemId;
check("Stock cannot go negative", (await owner.json(`/api/inventory/${item}/adjust`, "POST", { delta: -1, reason: "Sale" })).status === 409);
const office = (await owner.json(`/api/clubs/${clubId}/back-office`)).body;
check("Club balance = in-app sales ($25 + $21)", Number(office.balance.balance) === 46, JSON.stringify(office.balance));
check("Player cannot see back office", (await p1.json(`/api/clubs/${clubId}/back-office`)).status === 403);
check("Operator records payout", (await op.json(`/api/operator/clubs/${clubId}/payouts`, "POST", { amount: 46, reference: `PO-${tag}` })).status === 200 && Number((await owner.json(`/api/clubs/${clubId}/back-office`)).body.balance.balance) === 0);

// Groups
await p1.json("/api/me/friends", "POST", { action: "Request", email: p2.email });
await p2.json("/api/me/friends", "POST", { action: "Accept", userId: p1.id });
const grp = await p1.json("/api/me/groups", "POST", { name: "Crew", memberIds: [p2.id] });
check("Group created with a group chat", grp.status === 200 && grp.body.conversationId > 0, JSON.stringify(grp.body));
check("Member can post in group chat", (await p2.json(`/api/chats/${grp.body.conversationId}/messages`, "POST", { body: "See you Tuesday", clientKey: crypto.randomUUID() })).status === 200);
check("Outsider cannot read group chat", (await owner.json(`/api/chats/${grp.body.conversationId}/messages`)).status === 403);

// Shots: real JPEG markers with an EXIF segment containing GPS text
const jpeg = Buffer.concat([Buffer.from([0xFF, 0xD8]),
  Buffer.from([0xFF, 0xE1, 0x00, 0x20]), Buffer.from("Exif\0\0GPSLatitude=33.98-hidden".padEnd(28, " ")),
  Buffer.from([0xFF, 0xE0, 0x00, 0x10]), Buffer.from("JFIF\0\x01\x01\0\0\x01\0\x01\0\0", "binary"),
  Buffer.from([0xFF, 0xDA, 0x00, 0x08]), Buffer.alloc(6, 1), Buffer.alloc(200, 0x55), Buffer.from([0xFF, 0xD9])]);
const form = new FormData(); form.append("photo", new Blob([jpeg], { type: "image/jpeg" }), "me.jpg"); form.append("caption", "Match point");
const up = await p1.raw("/api/shots", "POST", form);
const upBody = await up.json().catch(() => ({}));
check("Photo uploaded", up.status === 200 && upBody.shotId > 0, `${up.status} ${JSON.stringify(upBody)}`);
const media = await fetch(`${BASE}/api/shots/${upBody.shotId}/media`);
const stored = Buffer.from(await media.arrayBuffer());
check("Served as image/jpeg with sandbox CSP", media.headers.get("content-type") === "image/jpeg" && (media.headers.get("content-security-policy") || "").includes("sandbox"));
check("Hidden GPS/EXIF data removed from the stored photo", !stored.includes(Buffer.from("GPSLatitude")) && stored[0] === 0xFF && stored[1] === 0xD8, String(stored.length));
const fake = new FormData(); fake.append("photo", new Blob(["<html><script>alert(1)</script>".repeat(10)], { type: "image/jpeg" }), "x.jpg");
check("Non-image disguised as JPEG refused", (await p1.raw("/api/shots", "POST", fake)).status === 400);
const big = new FormData(); big.append("photo", new Blob([Buffer.concat([jpeg.subarray(0, 2), Buffer.alloc(3.2 * 1024 * 1024)])], { type: "image/jpeg" }), "big.jpg");
// The server may answer 413/400 or simply close the connection while the oversized body is still uploading: both mean refused.
let bigStatus; try { bigStatus = (await p1.raw("/api/shots", "POST", big)).status; } catch (e) { bigStatus = "closed:" + (e.cause?.code || e.message); }
check("Photos over 3 MB refused", bigStatus === 400 || bigStatus === 413 || String(bigStatus).startsWith("closed:"), String(bigStatus));
check("Like counts once", (await p2.json(`/api/shots/${upBody.shotId}/action`, "POST", { action: "Like" })).body?.likes === 1 && (await p2.json(`/api/shots/${upBody.shotId}/action`, "POST", { action: "Like" })).body?.likes === 1);
check("Others cannot delete it", (await p2.json(`/api/shots/${upBody.shotId}/action`, "POST", { action: "Delete" })).status === 403);
check("Feed shows the shot to guests", (await (await fetch(`${BASE}/api/shots`)).json()).some((s) => s.shotId === upBody.shotId));

const failed = results.filter((x) => !x).length;
console.log(`\n${results.length - failed}/${results.length} club suite checks passed (real API + ${DB}).`);
process.exit(failed ? 1 : 0);
