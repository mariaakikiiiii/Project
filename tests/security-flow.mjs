// API-level security checks against a RUNNING API on a DISPOSABLE *_Tests database.
//   $env:GAMEON_API="https://localhost:7044"; $env:GAMEON_TEST_DB="GameOn_Tests"; node tests\security-flow.mjs
import { execFileSync } from "node:child_process";
const BASE = process.env.GAMEON_API || "https://localhost:7043", DB = process.env.GAMEON_TEST_DB;
if (!DB || !/_Tests$/.test(DB)) { console.error("Set GAMEON_TEST_DB to a database ending in _Tests."); process.exit(2); }
const sql = (q) => execFileSync("sqlcmd", ["-S", "localhost", "-E", "-C", "-b", "-I", "-d", DB, "-h", "-1", "-W", "-Q", "SET NOCOUNT ON; " + q], { encoding: "utf8" }).trim();
const results = []; const check = (id, name, ok, extra = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"}  ${id}  ${name}  ${extra}`); };
class Client { constructor() { this.k = new Map(); }
  async json(path, method = "GET", body, { csrf = true } = {}) {
    if (method !== "GET" && csrf && !this.csrf) this.csrf = (await this.json("/api/csrf")).body.token;
    const h = { Cookie: [...this.k].map(([a, b]) => `${a}=${b}`).join("; ") }; if (body) h["Content-Type"] = "application/json"; if (method !== "GET" && csrf) h["X-CSRF-TOKEN"] = this.csrf;
    const r = await fetch(BASE + path, { method, headers: h, body: body && JSON.stringify(body) });
    for (const c of r.headers.getSetCookie()) { const [kv] = c.split(";"); const i = kv.indexOf("="); this.k.set(kv.slice(0, i), kv.slice(i + 1)); }
    const t = await r.text(); let b = null; try { b = t ? JSON.parse(t) : null; } catch { b = t; } return { status: r.status, body: b, headers: r.headers }; } }
const usersBefore = sql("SELECT COUNT(*) FROM dbo.Users");
const payload = "' OR 1=1; DROP TABLE dbo.Users; --";
const inj = await new Client().json("/api/venues/search?q=" + encodeURIComponent(payload));
check("A01", "SQL injection payload in venue search is treated as text", inj.status === 200 && Array.isArray(inj.body) && inj.body.length === 0 && sql("SELECT COUNT(*) FROM dbo.Users") === usersBefore && sql("SELECT IIF(OBJECT_ID('dbo.Users') IS NULL,'gone','exists')") === "exists",
  `HTTP ${inj.status}, ${Array.isArray(inj.body) ? inj.body.length : "?"} venues, dbo.Users exists`);
const login = await new Client().json("/api/auth/login", "POST", { email: "' OR '1'='1", password: "' OR '1'='1" });
check("A02", "Injection payload as email/password cannot sign in", login.status === 400 || login.status === 401, `HTTP ${login.status}`);
const anon = await new Client().json("/api/me/friends");
check("A03", "Private endpoint without a session", anon.status === 401, `HTTP ${anon.status}`);
const tag = Date.now().toString(36), email = `sec.${tag}@gameon.invalid`, pw = "correct-horse-battery";
const u = new Client();
const reg = await u.json("/api/auth/register", "POST", { email, displayName: `Sec ${tag}`, password: pw, gender: "PreferNotToSay", dateOfBirth: "2000-01-02", sportIds: [1] });
const hash = sql(`SELECT PasswordHash FROM dbo.Users WHERE Email=N'${email}'`);
check("A04", "New password stored as Argon2id with salt inside the hash", reg.status === 200 && /^\$argon2id\$v=19\$m=19456,t=2,p=1\$[A-Za-z0-9+/]{22}\$[A-Za-z0-9+/]{43}$/.test(hash) && !hash.includes(pw), hash.slice(0, 32) + "...");
const noCsrf = await u.json("/api/me/friends", "POST", { action: "Request", email: "x@gameon.invalid" }, { csrf: false });
check("A05", "State-changing request without CSRF token", noCsrf.status === 400, `HTTP ${noCsrf.status}`);
u.csrf = null;
const adm = await u.json("/api/admin/analytics");
check("A06", "Normal player calls the admin analytics API", adm.status === 403, `HTTP ${adm.status}`);
const cookie = (await new Client().json("/api/auth/login", "POST", { email, password: pw })).headers.get("set-cookie") || "";
check("A07", "Session cookie is HttpOnly, Secure and SameSite=Strict", /httponly/i.test(cookie) && /secure/i.test(cookie) && /samesite=strict/i.test(cookie), cookie.split(";").slice(1).map((x) => x.trim()).join("; "));
const wrong = await new Client().json("/api/auth/login", "POST", { email, password: pw + "x" });
check("A08", "Wrong password is refused", wrong.status === 401, `HTTP ${wrong.status}`);
console.log(`${results.filter(Boolean).length}/${results.length} security checks passed (real API + ${DB}).`);
process.exit(results.every(Boolean) ? 0 : 1);
