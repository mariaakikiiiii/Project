// End-to-end checks for the admin panel (migration 31) on a DISPOSABLE *_Tests database.
//   $env:NODE_EXTRA_CA_CERTS="$env:TEMP\gameon-dev.pem"; $env:GAMEON_API="https://localhost:7044"; $env:GAMEON_TEST_DB="GameOn_Tests"; node tests\admin-flow.mjs
import { execFileSync } from "node:child_process";
const BASE = process.env.GAMEON_API || "https://localhost:7043", DB = process.env.GAMEON_TEST_DB;
if (!DB || !/_Tests$/.test(DB)) { console.error("Set GAMEON_TEST_DB to a database ending in _Tests."); process.exit(2); }
const sql = (q) => execFileSync("sqlcmd", ["-S", "localhost", "-E", "-C", "-b", "-d", DB, "-h", "-1", "-W", "-Q", "SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; " + q], { encoding: "utf8" }).trim();
const results = []; const check = (n, ok, extra = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"}  ${n}${ok ? "" : "  " + extra}`); };
const tag = Date.now().toString(36);
sql(`INSERT dbo.Venues(Name,Area,Address,ListingStatus) VALUES(N'zz-test-marker-${tag}',N'Testville',N'Marker','Unverified')`);
const marker = await (await fetch(`${BASE}/api/venues/search?q=zz-test-marker-${tag}`)).json().catch(() => []);
if (!Array.isArray(marker) || marker.length !== 1) { console.error(`STOP: ${BASE} is not connected to ${DB}. Nothing was created.`); process.exit(3); }

class Client {
  constructor() { this.cookies = new Map(); this.csrf = null; }
  async json(path, method = "GET", body) {
    if (method !== "GET" && !this.csrf) this.csrf = (await this.json("/api/csrf")).body.token;
    const h = { Cookie: [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; ") };
    if (body !== undefined) h["Content-Type"] = "application/json";
    if (method !== "GET") h["X-CSRF-TOKEN"] = this.csrf;
    const r = await fetch(BASE + path, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const c of r.headers.getSetCookie?.() || []) { const [kv] = c.split(";"); const i = kv.indexOf("="); this.cookies.set(kv.slice(0, i), kv.slice(i + 1)); }
    const t = await r.text(); return { status: r.status, body: t ? JSON.parse(t) : null };
  }
}
const lookups = await (await fetch(BASE + "/api/lookups")).json();
const sport = lookups.sports.find((s) => s.categorySlug === "sports").sportId;
const reg = (c, name) => c.json("/api/auth/register", "POST", { email: `${name}.${tag}@gameon.invalid`, displayName: `${name} ${tag}`, password: "correct-horse-battery", gender: "PreferNotToSay", dateOfBirth: "2000-01-02", sportIds: [sport] });
async function register(name) { const c = new Client(); const r = await reg(c, name); if (r.status !== 200) throw new Error(`${name}: ${r.status} ${JSON.stringify(r.body)}`); c.csrf = null; c.id = (await c.json("/api/auth/me")).body.userId; c.email = `${name}.${tag}@gameon.invalid`; return c; }
const admin = await register("adm"), user = await register("usr");
sql(`INSERT dbo.Admins(UserId) VALUES(${admin.id})`);

check("Non-admin is refused", (await user.json("/api/admin/overview")).status === 403);
check("Admin sees the overview", (await admin.json("/api/admin/overview")).status === 200);
check("/auth/me tells the app who is admin", (await admin.json("/api/auth/me")).body.isAdmin === true && (await user.json("/api/auth/me")).body.isAdmin === false);
check("Admin finds the user by email", (await admin.json(`/api/admin/users?q=usr.${tag}`)).body.some((u) => u.userId === user.id));

// Suspend: signed out everywhere, cannot sign in, clear message; restore works.
check("Admin suspends the user", (await admin.json(`/api/admin/users/${user.id}/status`, "POST", { status: "Suspended", reason: "Spam" })).body?.accountStatus === "Suspended");
check("Suspended user's open session is ended", (await user.json("/api/me/profile")).status === 401);
const login = await new Client().json("/api/auth/login", "POST", { email: user.email, password: "correct-horse-battery" });
check("Suspended user cannot sign in and sees why", login.status === 403 && /suspended/i.test(login.body.error), JSON.stringify(login.body));
check("Wrong password still says only 'Invalid credentials'", (await new Client().json("/api/auth/login", "POST", { email: user.email, password: "wrong-password-x" })).status === 401);
await admin.json(`/api/admin/users/${user.id}/status`, "POST", { status: "Active", reason: "ok" });
const back = new Client();
check("Restored user signs in again", (await back.json("/api/auth/login", "POST", { email: user.email, password: "correct-horse-battery" })).status === 200 && (await back.json("/api/me/profile")).status === 200);
check("Admin cannot suspend themselves", (await admin.json(`/api/admin/users/${admin.id}/status`, "POST", { status: "Suspended", reason: "test" })).status === 400);

// Session stamp: a forged cookie for the same user id from an older account row is rejected.
sql(`UPDATE dbo.Users SET SessionStamp=NEWID() WHERE UserId=${user.id}`);
check("Session from a different account row is rejected (stamp)", (await back.json("/api/me/profile")).status === 401);

// Roles
check("Admin makes the user an operator", (await admin.json(`/api/admin/users/${user.id}/role`, "POST", { role: "Operator", grant: true })).status === 200 && sql(`SELECT COUNT(*) FROM dbo.PaymentOperators WHERE UserId=${user.id}`) === "1");
await admin.json(`/api/admin/users/${user.id}/role`, "POST", { role: "Operator", grant: false });

// Settings change the live app
await admin.json("/api/admin/settings/Announcement", "PUT", { value: "Big padel night Friday!" });
check("Announcement appears for everyone", (await (await fetch(BASE + "/api/config")).json()).announcement === "Big padel night Friday!");
await admin.json("/api/admin/settings/SignupsOpen", "PUT", { value: "false" });
check("Closed sign-ups block registration", (await reg(new Client(), "late")).status === 503);
await admin.json("/api/admin/settings/SignupsOpen", "PUT", { value: "true" });
await admin.json("/api/admin/settings/ProMonthlyPrice", "PUT", { value: "7.50" });
const relog = new Client(); await relog.json("/api/auth/login", "POST", { email: user.email, password: "correct-horse-battery" }); relog.csrf = null;
check("New Pro price shown to players", (await relog.json("/api/me/rewards")).body.pro.price === 7.5);
check("Bad Pro price refused", (await admin.json("/api/admin/settings/ProMonthlyPrice", "PUT", { value: "999" })).status === 400);
await admin.json("/api/admin/settings/ProMonthlyPrice", "PUT", { value: "5.00" });
await admin.json("/api/admin/settings/Announcement", "PUT", { value: "" });
check("Non-admin cannot change settings", (await relog.json("/api/admin/settings/Announcement", "PUT", { value: "x" })).status === 403);

// Delete: personal data erased, cannot sign in
check("Admin deletes the user", (await admin.json(`/api/admin/users/${user.id}/delete`, "POST", { reason: "Asked to be deleted" })).body?.accountStatus === "Deleted");
check("Deleted user cannot sign in", (await new Client().json("/api/auth/login", "POST", { email: user.email, password: "correct-horse-battery" })).status === 401);
check("Deleted user's name and email erased", sql(`SELECT DisplayName+'|'+Email FROM dbo.Users WHERE UserId=${user.id}`) === `Deleted user|deleted-${user.id}@gameon.invalid`);
check("Audit log records the actions", (await admin.json("/api/admin/audit")).body.filter((a) => a.targetUserId === user.id).length >= 4);

const failed = results.filter((x) => !x).length;
console.log(`\n${results.length - failed}/${results.length} admin checks passed (real API + ${DB}).`);
process.exit(failed ? 1 : 0);
