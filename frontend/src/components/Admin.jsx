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

// Business analytics for admins: income, demand and who books. Age/gender groups with fewer than
// minGroup players are hidden by the database so no individual can be singled out.
function HBars({ rows, label, value, fmt = (x) => x, hidden }) {
  const max = Math.max(1, ...rows.map((r) => Number(r[value]) || 0));
  return <ul className="hbars">{rows.map((r) => <li key={r[label]}><span>{r[label]}</span>
    {r[value] == null ? <em className="muted small">{hidden}</em> : <><i style={{ width: `${(Number(r[value]) / max) * 100}%` }} /><b>{fmt(r[value])}</b></>}</li>)}</ul>;
}
function Analytics() {
  const [months, setMonths] = useState(12), [a, setA] = useState(null), [error, setError] = useState("");
  useEffect(() => { setA(null); api(`/admin/analytics?months=${months}`).then(setA).catch((e) => setError(e.message)); }, [months]);
  if (error) return <p className="alert">{error}</p>;
  if (!a) return <p className="muted">Loading analytics…</p>;
  const m = a.monthly, h = a.health, sum = (k) => m.reduce((t, r) => t + Number(r[k] || 0), 0);
  const income = m.map((r) => ({ month: r.month, income: Number(r.platformFees) + Number(r.proSales), bookings: r.courtBookings + r.gameJoins }));
  const maxI = Math.max(1, ...income.map((r) => r.income)), maxB = Math.max(1, ...income.map((r) => r.bookings));
  const pct = (x, y) => (y ? `${Math.round((100 * x) / y)}%` : "–");
  const hidden = `fewer than ${a.minGroup} players`;
  return (
    <div className="stack analytics">
      <div className="picker-row"><label>Period <select value={months} onChange={(e) => setMonths(+e.target.value)}>{[3, 6, 12, 24].map((n) => <option key={n} value={n}>Last {n} months</option>)}</select></label></div>
      <div className="kpis">
        <div className="kpi"><span>GameOn income</span><strong>{money(sum("platformFees") + sum("proSales"))}</strong><small className="muted">fees {money(sum("platformFees"))} · Pro {money(sum("proSales"))}</small></div>
        <div className="kpi"><span>Value booked at clubs</span><strong>{money(sum("courtValue"))}</strong><small className="muted">clubs' revenue, not GameOn's</small></div>
        <div className="kpi"><span>Bookings</span><strong>{(sum("courtBookings") + sum("gameJoins")).toLocaleString()}</strong><small className="muted">{sum("courtBookings").toLocaleString()} courts · {sum("gameJoins").toLocaleString()} game joins</small></div>
        <div className="kpi"><span>Active players</span><strong>{h.activePlayers.toLocaleString()}</strong><small className="muted">{pct(h.repeatPlayers, h.activePlayers)} came back 2+ times</small></div>
        <div className="kpi"><span>Court cancellations</span><strong>{pct(h.courtCancelled, h.courtBookingsAll)}</strong><small className="muted">{h.noShows.toLocaleString()} no-shows</small></div>
        <div className="kpi"><span>Disputes</span><strong>{h.disputesOpened}</strong><small className="muted">{h.disputesOpenNow} still open</small></div>
      </div>
      <section className="panel"><h3>GameOn income by month</h3>
        <div className="bars" role="img" aria-label="Income by month">{income.map((r) => <div className="bar" key={r.month} title={`${r.month}: ${money(r.income)}`} style={{ height: `${(r.income / maxI) * 100}%` }} />)}</div>
        <div className="bar-labels">{income.map((r) => <span key={r.month}>{r.month.slice(5)}</span>)}</div></section>
      <section className="panel"><h3>Bookings by month</h3>
        <div className="bars" role="img" aria-label="Bookings by month">{income.map((r) => <div className="bar" key={r.month} title={`${r.month}: ${r.bookings}`} style={{ height: `${(r.bookings / maxB) * 100}%` }} />)}</div>
        <div className="bar-labels">{income.map((r) => <span key={r.month}>{r.month.slice(5)}</span>)}</div></section>
      <div className="analytics-grid">
        <section className="panel"><h3>Bookings by age</h3><HBars rows={a.byAge} label="group" value="bookings" fmt={(x) => x.toLocaleString()} hidden={hidden} /></section>
        <section className="panel"><h3>Bookings by gender</h3><HBars rows={a.byGender} label="group" value="bookings" fmt={(x) => x.toLocaleString()} hidden={hidden} /></section>
        <section className="panel"><h3>Bookings by sport</h3><HBars rows={a.bySport.map((r) => ({ ...r, total: r.courtBookings + r.gameJoins }))} label="sport" value="total" fmt={(x) => x.toLocaleString()} /></section>
        <section className="panel"><h3>Busiest hours (Beirut)</h3><HBars rows={a.byHour.map((r) => ({ ...r, hour: `${String(r.hour).padStart(2, "0")}:00` }))} label="hour" value="bookings" fmt={(x) => x.toLocaleString()} /></section>
      </div>
      <section className="panel"><h3>Top clubs by value booked</h3>
        {a.topClubs.length === 0 ? <p className="muted">No court bookings in this period.</p> :
          <ul className="ledger">{a.topClubs.map((c) => <li key={c.club}><span><strong>{c.club}</strong><small>{c.bookings.toLocaleString()} bookings · {pct(c.noShows, c.bookings)} no-shows</small></span><b>{money(c.courtValue)}</b></li>)}</ul>}</section>
      <p className="muted small">Use it to adjust: raise peak prices in the busiest hours, follow up clubs with many no-shows, and target sports and age groups that are growing. Age and gender come from profiles; groups under {a.minGroup} players stay hidden for privacy.</p>
    </div>
  );
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
  const tabs = [["overview", "Overview"], ["analytics", "Analytics"], ["users", "Users"], ["settings", "App settings"], ["moderation", "Photo reports"], ["audit", "Audit log"]];
  return (
    <section className="stack admin-page">
      <div className="section-heading"><div><span className="overline">GAMEON ADMIN</span><h1>Admin panel</h1></div></div>
      <div className="segmented tabs-scroll" role="tablist">{tabs.map(([k, l]) => <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? "active" : ""} onClick={() => setTab(k)}>{l}</button>)}</div>
      {tab === "overview" && <><Overview data={data} /><p className="muted small">Payments, top-ups and disputes are handled under Me → Wallet and Me → Payments (operator role). Clubs are onboarded by operators.</p></>}
      {tab === "analytics" && <Analytics />}
      {tab === "users" && <Users me={user.userId} />}
      {tab === "settings" && <Settings settings={data.settings} onSaved={() => setV((x) => x + 1)} />}
      {tab === "moderation" && <Moderation />}
      {tab === "audit" && <Audit />}
    </section>
  );
}
