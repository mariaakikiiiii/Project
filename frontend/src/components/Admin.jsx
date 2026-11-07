import React, { useEffect, useState } from "react";
import { api } from "../api";
import { money } from "./community";

// GameOn admin panel. Every action is checked again on the server and written to the audit log.
function Overview({ data }) {
  const s = data.stats;
  const tiles = [["Active players", s.activeUsers], ["New this week", s.newUsers7d], ["Signed in this week", s.activeLast7d], ["Suspended", s.suspendedUsers],
    ["Upcoming games", s.upcomingGames], ["Upcoming court bookings", s.upcomingCourtBookings], ["Clubs", s.clubs],
    ["Money in player wallets", money(s.walletMoneyHeld)], ["Money held for clubs", money(s.clubMoneyHeld)],
    ["Top-ups to check", s.topUpsToCheck], ["Open disputes", s.openDisputes], ["Reported photos", s.reportedShots]];
  return <div className="kpis">{tiles.map(([l, v]) => <div className="kpi" key={l}><span>{l}</span><strong>{v}</strong></div>)}</div>;
}

function Users({ me }) {
  const [q, setQ] = useState(""), [status, setStatus] = useState(""), [list, setList] = useState(null), [v, setV] = useState(0), [msg, setMsg] = useState(""), [error, setError] = useState("");
  useEffect(() => { const t = setTimeout(() => api(`/admin/users?${new URLSearchParams({ ...(q.trim() ? { q: q.trim() } : {}), ...(status ? { status } : {}) })}`).then(setList).catch((e) => setError(e.message)), 250); return () => clearTimeout(t); }, [q, status, v]);
  async function run(fn, note) { setError(""); setMsg(""); try { await fn(); setMsg(note); setV((x) => x + 1); } catch (e) { setError(e.message); } }
  function suspend(u) { const reason = prompt(`Why are you suspending ${u.displayName}? (they are signed out everywhere immediately)`); if (reason) run(() => api(`/admin/users/${u.userId}/status`, "POST", { status: "Suspended", reason }), `${u.displayName} suspended.`); }
  function restore(u) { run(() => api(`/admin/users/${u.userId}/status`, "POST", { status: "Active", reason: "Restored by admin" }), `${u.displayName} restored.`); }
  function remove(u) {
    const reason = prompt(`Delete ${u.displayName}?\n\nTheir name, email, birth date, photos, friends and preferences are erased. Bookings and payments stay as anonymous records. This cannot be undone.\n\nType the reason:`);
    if (reason) run(() => api(`/admin/users/${u.userId}/delete`, "POST", { reason }), "Account deleted and personal data erased.");
  }
  const role = (u, r, grant) => run(() => api(`/admin/users/${u.userId}/role`, "POST", { role: r, grant }), `${r} role ${grant ? "given to" : "removed from"} ${u.displayName}.`);
  return (
    <section className="stack">
      <div className="filters-row"><input aria-label="Search users" placeholder="Search name, email or ID" value={q} maxLength={100} onChange={(e) => setQ(e.target.value)} />
        <select aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)}><option value="">All</option><option>Active</option><option>Suspended</option><option>Deleted</option></select></div>
      {msg && <p className="success" role="status">{msg}</p>}{error && <p className="alert" role="alert">{error}</p>}
      {!list ? <p className="muted">Loading…</p> : list.length === 0 ? <p className="muted">No users match.</p> : (
        <ul className="ledger admin-users">{list.map((u) => (
          <li key={u.userId}>
            <span><strong>{u.displayName} {u.isAdmin && <span className="pill">Admin</span>} {u.isOperator && <span className="pill">Operator</span>} {u.isPro && <span className="pro-badge">PRO</span>} {u.accountStatus !== "Active" && <span className="pill danger">{u.accountStatus}</span>}</strong>
              <small>#{u.userId} · {u.email} · joined {new Date(u.createdAt + "Z").toLocaleDateString()}{u.lastLoginAt ? ` · last seen ${new Date(u.lastLoginAt + "Z").toLocaleDateString()}` : ""}</small>
              <small>{u.gamesHosted} hosted · {u.gamesJoined} joined · wallet {money(u.walletBalance)}{u.reportsAgainst ? ` · ${u.reportsAgainst} photo reports` : ""}{u.clubs ? ` · ${u.clubs}` : ""}{u.statusReason ? ` · reason: ${u.statusReason}` : ""}</small></span>
            {u.accountStatus !== "Deleted" && u.userId !== me && (
              <span className="button-row">
                {u.accountStatus === "Active" ? <button className="secondary" onClick={() => suspend(u)}>Suspend</button> : <button className="primary" onClick={() => restore(u)}>Restore</button>}
                <button className="text-link" onClick={() => role(u, "Operator", !u.isOperator)}>{u.isOperator ? "Remove operator" : "Make operator"}</button>
                <button className="text-link" onClick={() => role(u, "Admin", !u.isAdmin)}>{u.isAdmin ? "Remove admin" : "Make admin"}</button>
                <button className="text-link danger-text" onClick={() => remove(u)}>Delete</button>
              </span>)}
            {u.userId === me && <span className="muted small">This is you</span>}
          </li>))}</ul>)}
    </section>
  );
}

function Settings({ settings, onSaved }) {
  const get = (k) => settings.find((s) => s.settingKey === k)?.settingValue ?? "";
  const [f, setF] = useState({ Announcement: get("Announcement"), SupportEmail: get("SupportEmail"), ProMonthlyPrice: get("ProMonthlyPrice"), SignupsOpen: get("SignupsOpen") !== "false", ShotsEnabled: get("ShotsEnabled") !== "false" });
  const [msg, setMsg] = useState(""), [error, setError] = useState("");
  async function save(key, value) { setMsg(""); setError(""); try { await api(`/admin/settings/${key}`, "PUT", { value: String(value) }); setMsg("Saved. Players see it within 30 seconds."); onSaved(); } catch (e) { setError(e.message); } }
  return (
    <section className="stack">
      {msg && <p className="success" role="status">{msg}</p>}{error && <p className="alert" role="alert">{error}</p>}
      <div className="panel stack"><h3>Announcement banner</h3><p className="muted small">Shown at the top of every page. Leave empty to hide it.</p>
        <div className="picker-row"><input maxLength={400} value={f.Announcement} onChange={(e) => setF({ ...f, Announcement: e.target.value })} placeholder="e.g. New padel club in Kaslik: 20% off this week!" /><button className="primary" onClick={() => save("Announcement", f.Announcement)}>Save</button></div></div>
      <div className="panel stack"><h3>Switches</h3>
        <label className="checkbox"><input type="checkbox" checked={f.SignupsOpen} onChange={(e) => { setF({ ...f, SignupsOpen: e.target.checked }); save("SignupsOpen", e.target.checked); }} />New sign-ups open</label>
        <label className="checkbox"><input type="checkbox" checked={f.ShotsEnabled} onChange={(e) => { setF({ ...f, ShotsEnabled: e.target.checked }); save("ShotsEnabled", e.target.checked); }} />Players can share Shots (photos)</label></div>
      <div className="panel stack"><h3>GameOn Pro price (USD per 30 days)</h3>
        <div className="picker-row"><input type="number" min="1" max="100" step="0.5" value={f.ProMonthlyPrice} onChange={(e) => setF({ ...f, ProMonthlyPrice: e.target.value })} /><button className="primary" onClick={() => save("ProMonthlyPrice", Number(f.ProMonthlyPrice).toFixed(2))}>Save</button></div>
        <p className="muted small">Applies to new purchases and renewals. Existing memberships keep their end date.</p></div>
      <div className="panel stack"><h3>Support email</h3><p className="muted small">Shown to suspended players and in the footer.</p>
        <div className="picker-row"><input type="email" maxLength={200} value={f.SupportEmail} onChange={(e) => setF({ ...f, SupportEmail: e.target.value })} placeholder="support@yourdomain.com" /><button className="primary" onClick={() => save("SupportEmail", f.SupportEmail)}>Save</button></div></div>
    </section>
  );
}

function Moderation() {
  const [list, setList] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/admin/shots").then(setList).catch((e) => setError(e.message)); }, [v]);
  async function set(s, hide) { try { await api(`/admin/shots/${s.shotId}`, "POST", { hide }); setV((x) => x + 1); } catch (e) { setError(e.message); } }
  if (error) return <p className="alert">{error}</p>;
  if (!list) return <p className="muted">Loading…</p>;
  if (!list.length) return <p className="muted">No reported photos.</p>;
  return <div className="shots-grid">{list.map((s) => (
    <figure key={s.shotId} className="panel shot"><img src={`/api/shots/${s.shotId}/media`} alt="" onError={(e) => { e.currentTarget.style.display = "none"; }} />
      <figcaption><strong>{s.displayName}</strong> <span className="pill danger">{s.reports} reports{s.hidden ? " · hidden" : ""}</span><p className="small">{s.reasons}</p>
        <div className="button-row">{s.hidden ? <button className="secondary" onClick={() => set(s, false)}>Restore (clear reports)</button> : <button className="primary" onClick={() => set(s, true)}>Hide</button>}</div></figcaption></figure>))}</div>;
}

function Audit() {
  const [list, setList] = useState(null);
  useEffect(() => { api("/admin/audit").then(setList).catch(() => setList([])); }, []);
  if (!list) return <p className="muted">Loading…</p>;
  return <ul className="ledger">{list.map((a) => <li key={a.auditId}><span><strong>{a.adminName}: {a.action}{a.targetName ? ` · ${a.targetName}` : ""}</strong><small>{a.detail}</small></span><small>{new Date(a.at + "Z").toLocaleString()}</small></li>)}</ul>;
}

export default function Admin({ user }) {
  const [tab, setTab] = useState("overview"), [data, setData] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/admin/overview").then(setData).catch((e) => setError(e.message)); }, [v]);
  if (error) return <section className="panel"><h1>Admin</h1><p className="alert">{error}</p></section>;
  if (!data) return <p className="muted">Loading…</p>;
  const tabs = [["overview", "Overview"], ["users", "Users"], ["settings", "App settings"], ["moderation", "Photo reports"], ["audit", "Audit log"]];
  return (
    <section className="stack admin-page">
      <div className="section-heading"><div><span className="overline">GAMEON ADMIN</span><h1>Admin panel</h1></div></div>
      <div className="segmented tabs-scroll" role="tablist">{tabs.map(([k, l]) => <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? "active" : ""} onClick={() => setTab(k)}>{l}</button>)}</div>
      {tab === "overview" && <><Overview data={data} /><p className="muted small">Payments, top-ups and disputes are handled under Me → Wallet and Me → Payments (operator role). Clubs are onboarded by operators.</p></>}
      {tab === "users" && <Users me={user.userId} />}
      {tab === "settings" && <Settings settings={data.settings} onSaved={() => setV((x) => x + 1)} />}
      {tab === "moderation" && <Moderation />}
      {tab === "audit" && <Audit />}
    </section>
  );
}
