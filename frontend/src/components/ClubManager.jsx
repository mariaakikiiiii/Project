import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { SlotGrid } from "./Courts";
import { money, localTime, nextDays, localDate } from "./community";

// Club & coach side. Permissions are enforced in SQL; the UI only hides what a role can't use.
const ROLE_RANK = { Owner: 4, Operator: 4, Manager: 3, Reception: 2, Coach: 1 };

function Schedule({ club, rank }) {
  const days = nextDays(14);
  const [day, setDay] = useState(days[0]), [data, setData] = useState(null), [v, setV] = useState(0), [armed, setArmed] = useState(null), [guest, setGuest] = useState(""), [msg, setMsg] = useState(""), [error, setError] = useState("");
  useEffect(() => { setData(null); api(`/clubs/${club.clubId}/schedule?date=${day}`).then(setData).catch((e) => setError(e.message)); }, [club.clubId, day, v]);
  const key = useRef(crypto.randomUUID());
  // 2-tap toggle: first tap selects a slot, second tap on the same slot blocks/unblocks it.
  async function tap(s, k) {
    setError(""); setMsg("");
    if (s.slotStatus === "Booked" || s.slotStatus === "Mine") { setArmed(k); return; }
    if (armed !== k) { setArmed(k); return; }
    try { const r = await api(`/courts/${s.courtId}/block-toggle`, "POST", { startsAtUtc: s.startsAtUtc + "Z", reason: "Blocked by club" }); setMsg(`${s.court} ${localTime(s.localStart)}: ${r.status}`); setArmed(null); setV((x) => x + 1); }
    catch (e) { setError(e.message); }
  }
  const sel = data?.slots.find((s) => `${s.courtId}|${s.startsAtUtc}` === armed);
  async function bookGuest() {
    try { await api(`/courts/${sel.courtId}/bookings`, "POST", { startsAtUtc: sel.startsAtUtc + "Z", idempotencyKey: key.current, guestName: guest.trim() }); key.current = crypto.randomUUID(); setGuest(""); setArmed(null); setMsg("Walk-in booked."); setV((x) => x + 1); }
    catch (e) { setError(e.message); }
  }
  async function cancelBooking() {
    if (!confirm(`Cancel ${sel.bookedBy || "this"} booking? The player is notified.`)) return;
    try { await api(`/court-bookings/${sel.bookingId}`, "DELETE"); setArmed(null); setMsg("Booking cancelled; player notified."); setV((x) => x + 1); } catch (e) { setError(e.message); }
  }
  return (
    <section className="stack">
      <div className="day-chips">{days.map((d) => <button key={d} className={d === day ? "chip active" : "chip"} onClick={() => { setDay(d); setArmed(null); }}>{localDate(d + "T00:00")}</button>)}</div>
      <p className="muted small">Tap a free slot twice to block it (maintenance, private event). Tap a blocked slot twice to reopen it. Tap a booking to see options.</p>
      {msg && <p className="success" role="status">{msg}</p>}{error && <p className="alert" role="alert">{error}</p>}
      {!data ? <p className="muted">Loading…</p> : <SlotGrid slots={data.slots} staff selected={armed} onPick={tap} />}
      {sel && sel.slotStatus === "Free" && rank >= 2 && (
        <div className="panel stack"><h3>{sel.court} · {localTime(sel.localStart)}</h3><p className="muted small">Tap the slot again to block it, or book it for a walk-in guest.</p>
          <div className="picker-row"><input placeholder="Guest name" maxLength={80} value={guest} onChange={(e) => setGuest(e.target.value)} /><button className="primary" disabled={!guest.trim()} onClick={bookGuest}>Book walk-in</button></div></div>)}
      {sel && (sel.slotStatus === "Booked" || sel.slotStatus === "Mine") && (
        <div className="panel stack"><h3>{sel.court} · {localTime(sel.localStart)} · {sel.bookedBy}</h3><button className="secondary" onClick={cancelBooking}>Cancel this booking</button></div>)}
    </section>
  );
}

function CourtsEditor({ club, lookups, courts, refresh }) {
  const blank = { name: "", subtypeId: lookups.sports.find((s) => s.categorySlug === "sports")?.sportId, slotMinutes: 60, openHour: 8, closeHour: 23, basePrice: 20, peakPrice: 30, peakStartHour: 18, peakEndHour: 22, isActive: true };
  const [edit, setEdit] = useState(null), [error, setError] = useState("");
  async function save(e) {
    e.preventDefault(); setError("");
    const f = { ...edit, subtypeId: Number(edit.subtypeId), slotMinutes: Number(edit.slotMinutes), openHour: Number(edit.openHour), closeHour: Number(edit.closeHour), basePrice: Number(edit.basePrice), peakPrice: Number(edit.peakPrice), peakStartHour: Number(edit.peakStartHour), peakEndHour: Number(edit.peakEndHour) };
    try { await api(`/clubs/${club.clubId}/courts`, "POST", f); setEdit(null); refresh(); } catch (err) { setError(err.message); }
  }
  const set = (k) => (e) => setEdit({ ...edit, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.value });
  return (
    <section className="stack">
      <ul className="ledger">{courts.map((c) => <li key={c.courtId}><span><strong>{c.name}</strong><small>{lookups.sports.find((s) => s.sportId === c.subtypeId)?.name} · {c.openHour}:00–{c.closeHour}:00 · {c.slotMinutes} min · {money(c.basePrice)} / peak {money(c.peakPrice)} ({c.peakStartHour}–{c.peakEndHour}h){c.isActive ? "" : " · closed"}</small></span><button className="secondary" onClick={() => setEdit({ ...c, courtId: c.courtId })}>Edit</button></li>)}</ul>
      {!edit ? <button className="primary" onClick={() => setEdit(blank)}>+ Add a court</button> : (
        <form className="panel form-grid" onSubmit={save}>
          <label>Court name<input required maxLength={80} value={edit.name} onChange={set("name")} /></label>
          <label>Sport<select value={edit.subtypeId} onChange={set("subtypeId")}>{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select></label>
          <label>Slot length<select value={edit.slotMinutes} onChange={set("slotMinutes")}>{[30, 60, 90, 120].map((m) => <option key={m} value={m}>{m} min</option>)}</select></label>
          <label>Opens (hour)<input type="number" min="0" max="23" value={edit.openHour} onChange={set("openHour")} /></label>
          <label>Closes (hour)<input type="number" min="1" max="24" value={edit.closeHour} onChange={set("closeHour")} /></label>
          <label>Standard price ($)<input type="number" min="0" step="0.5" value={edit.basePrice} onChange={set("basePrice")} /></label>
          <label>Peak price ($)<input type="number" min="0" step="0.5" value={edit.peakPrice} onChange={set("peakPrice")} /></label>
          <label>Peak from (hour)<input type="number" min="0" max="24" value={edit.peakStartHour} onChange={set("peakStartHour")} /></label>
          <label>Peak until (hour)<input type="number" min="0" max="24" value={edit.peakEndHour} onChange={set("peakEndHour")} /></label>
          <label className="checkbox"><input type="checkbox" checked={edit.isActive} onChange={set("isActive")} />Open for booking</label>
          <div className="form-wide button-row"><button className="primary">Save court</button><button type="button" className="secondary" onClick={() => setEdit(null)}>Cancel</button></div>
          {error && <p className="alert form-wide" role="alert">{error}</p>}
        </form>)}
    </section>
  );
}

function ClassesEditor({ club, lookups, courts, staff }) {
  const [f, setF] = useState({ title: "", subtypeId: courts[0]?.subtypeId || lookups.sports[0]?.sportId, courtId: "", coachUserId: "", first: "", durationMinutes: 60, capacity: 8, price: 10, weeks: 4 });
  const [msg, setMsg] = useState(""), [error, setError] = useState("");
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  async function save(e) {
    e.preventDefault(); setMsg(""); setError("");
    try {
      // The time entered is Beirut local time; the browser converts it to UTC.
      const r = await api(`/clubs/${club.clubId}/classes`, "POST", { title: f.title, subtypeId: Number(f.subtypeId), courtId: f.courtId ? Number(f.courtId) : null, coachUserId: f.coachUserId ? Number(f.coachUserId) : null,
        firstStartsAtUtc: new Date(f.first).toISOString(), durationMinutes: Number(f.durationMinutes), capacity: Number(f.capacity), price: Number(f.price), weeks: Number(f.weeks) });
      setMsg(`${r.created} weekly session(s) scheduled${f.courtId ? " and the court blocked for each" : ""}.`);
    } catch (err) { setError(err.message); }
  }
  return (
    <form className="panel form-grid" onSubmit={save}>
      <h3 className="form-wide">Schedule a class (one-off or weekly)</h3>
      <label className="form-wide">Title<input required maxLength={120} value={f.title} onChange={set("title")} placeholder="Padel for beginners" /></label>
      <label>Sport<select value={f.subtypeId} onChange={set("subtypeId")}>{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select></label>
      <label>Court (reserves it)<select value={f.courtId} onChange={set("courtId")}><option value="">No court</option>{courts.map((c) => <option key={c.courtId} value={c.courtId}>{c.name}</option>)}</select></label>
      <label>Coach<select value={f.coachUserId} onChange={set("coachUserId")}><option value="">None</option>{staff.map((s) => <option key={s.userId} value={s.userId}>{s.displayName} ({s.role})</option>)}</select></label>
      <label>First session<input type="datetime-local" required value={f.first} onChange={set("first")} /></label>
      <label>Duration (min)<input type="number" min="30" max="240" step="15" value={f.durationMinutes} onChange={set("durationMinutes")} /></label>
      <label>Capacity<input type="number" min="1" max="60" value={f.capacity} onChange={set("capacity")} /></label>
      <label>Price ($)<input type="number" min="0" step="0.5" value={f.price} onChange={set("price")} /></label>
      <label>Repeat weekly for<select value={f.weeks} onChange={set("weeks")}>{[1, 2, 4, 6, 8, 12, 26].map((w) => <option key={w} value={w}>{w === 1 ? "One session" : `${w} weeks`}</option>)}</select></label>
      <div className="form-wide"><button className="primary">Create</button></div>
      {msg && <p className="success form-wide" role="status">{msg}</p>}{error && <p className="alert form-wide" role="alert">{error}</p>}
    </form>
  );
}

function Dashboard({ data, club, refresh, rank }) {
  const s = data.summary, max = Math.max(1, ...data.daily.map((d) => Number(d.revenue)));
  const [exp, setExp] = useState({ amount: "", category: "Utilities", spentOn: new Date().toISOString().slice(0, 10), note: "" }), [staffEmail, setStaffEmail] = useState(""), [role, setRole] = useState("Reception"), [error, setError] = useState("");
  async function run(fn) { setError(""); try { await fn(); refresh(); } catch (e) { setError(e.message); } }
  return (
    <section className="stack">
      <div className="kpis">
        <div className="kpi"><span>Revenue ({s.days} days)</span><strong>{money(s.revenue)}</strong><small>Courts {money(s.courtRevenue)} · Classes {money(s.classRevenue)}</small></div>
        <div className="kpi"><span>Expenses</span><strong>{money(s.expenses)}</strong></div>
        <div className="kpi"><span>Net profit</span><strong className={Number(s.netProfit) >= 0 ? "pos" : "neg"}>{money(s.netProfit)}</strong></div>
        <div className="kpi"><span>Occupancy</span><strong>{s.occupancyPct}%</strong><small>{s.upcomingBookings} upcoming · {s.cancellations} cancelled</small></div>
      </div>
      <div className="panel"><h3>Daily court revenue</h3>
        {data.daily.length === 0 ? <p className="muted">No completed bookings in this period yet.</p> :
          <div className="bars" role="img" aria-label="Daily revenue chart">{data.daily.map((d) => <div key={d.day} className="bar" style={{ height: `${(Number(d.revenue) / max) * 100}%` }} title={`${String(d.day).slice(0, 10)}: ${money(d.revenue)} (${d.bookings})`} />)}</div>}
        <p className="muted small">Revenue = what players owe for courts and classes that already took place (paid at the club). GameOn takes no commission on court bookings.</p>
      </div>
      {data.byHour.length > 0 && <div className="panel"><h3>Busiest hours</h3><p className="small">{data.byHour.slice().sort((a, b) => b.bookings - a.bookings).slice(0, 4).map((h) => `${h.hour}:00 (${h.bookings})`).join(" · ")}</p><p className="muted small">Use these to set peak hours and prices in Courts.</p></div>}
      {rank >= 4 && <>
        <form className="panel form-grid" onSubmit={(e) => { e.preventDefault(); run(() => api(`/clubs/${club.clubId}/expenses`, "POST", { ...exp, amount: Number(exp.amount) })); }}>
          <h3 className="form-wide">Record an expense</h3>
          <label>Amount ($)<input type="number" min="0.01" step="0.01" required value={exp.amount} onChange={(e) => setExp({ ...exp, amount: e.target.value })} /></label>
          <label>Category<select value={exp.category} onChange={(e) => setExp({ ...exp, category: e.target.value })}>{["Rent", "Staff", "Utilities", "Maintenance", "Equipment", "Marketing", "Other"].map((c) => <option key={c}>{c}</option>)}</select></label>
          <label>Date<input type="date" required value={exp.spentOn} onChange={(e) => setExp({ ...exp, spentOn: e.target.value })} /></label>
          <label>Note<input maxLength={200} value={exp.note} onChange={(e) => setExp({ ...exp, note: e.target.value })} /></label>
          <div className="form-wide"><button className="secondary">Add expense</button></div>
        </form>
        <div className="panel stack"><h3>Staff</h3>
          <ul className="ledger">{data.staff.map((m) => <li key={m.userId}><span><strong>{m.displayName}</strong><small>{m.email}</small></span><span className="button-row"><span className="pill">{m.role}</span>{m.role !== "Owner" && <button className="text-link" onClick={() => run(() => api(`/clubs/${club.clubId}/staff`, "POST", { email: m.email, role: null }))}>Remove</button>}</span></li>)}</ul>
          <div className="picker-row"><input type="email" placeholder="Their GameOn email" value={staffEmail} onChange={(e) => setStaffEmail(e.target.value)} /><select value={role} onChange={(e) => setRole(e.target.value)}><option>Manager</option><option>Reception</option><option>Coach</option></select><button className="primary" onClick={() => run(() => api(`/clubs/${club.clubId}/staff`, "POST", { email: staffEmail, role }))}>Add</button></div>
          <p className="muted small">Manager: courts, classes, dashboard. Reception: schedule, blocks, walk-ins, chat. Coach: their own classes.</p>
        </div>
      </>}
      {error && <p className="alert" role="alert">{error}</p>}
    </section>
  );
}

export default function ClubManager({ lookups }) {
  const [mine, setMine] = useState(null), [club, setClub] = useState(null), [tab, setTab] = useState("schedule"), [dash, setDash] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/clubs").then((r) => { setMine(r.myClubs); if (r.myClubs.length === 1) setClub(r.myClubs[0]); }).catch((e) => setError(e.message)); }, []);
  const rank = ROLE_RANK[club?.clubRole] || 0;
  useEffect(() => { if (club && rank >= 3) api(`/clubs/${club.clubId}/dashboard`).then(setDash).catch((e) => setError(e.message)); }, [club, rank, v]);
  if (error) return <p className="alert" role="alert">{error}</p>;
  if (!mine) return <p className="muted">Loading…</p>;
  if (!mine.length) return <section className="panel"><h1>Club manager</h1><p>You are not on the staff of a club yet.</p><p className="muted">Clubs join GameOn through a GameOn operator, who links the club to its venue and names the owner. The owner then adds managers, reception and coaches by email.</p></section>;
  const tabs = [["schedule", "Schedule", 2], ["courts", "Courts & prices", 3], ["classes", "Classes", 1], ["dashboard", "Dashboard", 3]].filter((t) => rank >= t[2]);
  return (
    <section className="club-manager stack">
      <div className="section-heading"><div><span className="overline">CLUB MANAGER · {club?.clubRole?.toUpperCase()}</span><h1>{club?.name || "Choose a club"}</h1></div>
        {mine.length > 1 && <select aria-label="Club" value={club?.clubId || ""} onChange={(e) => setClub(mine.find((m) => m.clubId === Number(e.target.value)))}><option value="">Choose…</option>{mine.map((m) => <option key={m.clubId} value={m.clubId}>{m.name}</option>)}</select>}</div>
      {club && <>
        <div className="segmented tabs-4" role="tablist">{tabs.map(([k, l]) => <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? "active" : ""} onClick={() => setTab(k)}>{l}</button>)}</div>
        {tab === "schedule" && <Schedule club={club} rank={rank} />}
        {tab === "courts" && dash && <CourtsEditor club={club} lookups={lookups} courts={dash.courts} refresh={() => setV((x) => x + 1)} />}
        {tab === "classes" && <ClassesEditor club={club} lookups={lookups} courts={dash?.courts || []} staff={dash?.staff || []} />}
        {tab === "dashboard" && dash && <Dashboard data={dash} club={club} rank={rank} refresh={() => setV((x) => x + 1)} />}
      </>}
    </section>
  );
}
