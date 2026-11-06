import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { money, localTime, localDate } from "./community";

// Club back-office panels (migration 29). Each panel loads its own data; permissions are enforced in SQL.
function useLoad(path, v) {
  const [data, setData] = useState(null), [error, setError] = useState("");
  useEffect(() => { setError(""); api(path).then(setData).catch((e) => setError(e.message)); }, [path, v]);
  return [data, error];
}
const Err = ({ e }) => (e ? <p className="alert" role="alert">{e}</p> : null);

export function Requests({ club, courts, rank, onChange }) {
  const [v, setV] = useState(0), [list, error] = useLoad(`/clubs/${club.clubId}/pending`, v), [err, setErr] = useState("");
  async function decide(b, approve) { setErr(""); try { await api(`/court-bookings/${b.bookingId}/decision`, "POST", { approve }); setV((x) => x + 1); onChange?.(); } catch (e) { setErr(e.message); } }
  async function toggle(c) { setErr(""); try { await api(`/courts/${c.courtId}/approval`, "PUT", { requiresApproval: !c.requiresApproval }); onChange?.(); } catch (e) { setErr(e.message); } }
  return (
    <section className="stack">
      <Err e={error || err} />
      {!list ? <p className="muted">Loading…</p> : list.length === 0 ? <p className="muted">No booking requests waiting.</p> :
        <ul className="ledger">{list.map((b) => <li key={b.bookingId}><span><strong>{b.player} · {b.court}</strong><small>{localDate(b.localStart)} {localTime(b.localStart)} · {money(b.price)}{b.paidFromWallet ? " paid in-app" : " at the club"} · {b.previousBookings} past bookings here</small></span>
          <span className="button-row"><button className="primary" onClick={() => decide(b, true)}>Approve</button><button className="text-link" onClick={() => decide(b, false)}>Decline</button></span></li>)}</ul>}
      {rank >= 3 && courts?.length > 0 && <div className="panel stack"><h3>Which courts need your approval?</h3><p className="muted small">Off: players book instantly. On: each booking waits for staff to approve. Wallet payments are refunded if you decline.</p>
        {courts.map((c) => <label className="checkbox" key={c.courtId}><input type="checkbox" checked={!!c.requiresApproval} onChange={() => toggle(c)} />{c.name}</label>)}</div>}
    </section>
  );
}

export function CheckIn({ club }) {
  const [code, setCode] = useState(""), [result, setResult] = useState(null), [error, setError] = useState(""), [scanning, setScanning] = useState(false);
  const video = useRef(), stream = useRef();
  async function check(c) { setError(""); setResult(null); try { setResult(await api(`/clubs/${club.clubId}/check-in`, "POST", { code: c.trim().toUpperCase() })); setCode(""); } catch (e) { setError(e.message); } }
  async function scan() {
    // Uses the browser's built-in QR reader where available (Chrome/Edge/Android); otherwise type the code.
    if (!("BarcodeDetector" in window)) { setError("This browser can't scan. Type the 12-character code under the member's QR."); return; }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
      setScanning(true); video.current.srcObject = stream.current; await video.current.play();
      const det = new window.BarcodeDetector({ formats: ["qr_code"] });
      const loop = async () => {
        if (!stream.current) return;
        const found = await det.detect(video.current).catch(() => []);
        if (found[0]?.rawValue) { stop(); check(found[0].rawValue); } else requestAnimationFrame(loop);
      };
      loop();
    } catch { setError("Camera not available. Type the code instead."); stop(); }
  }
  function stop() { stream.current?.getTracks().forEach((t) => t.stop()); stream.current = null; setScanning(false); }
  useEffect(() => stop, []);
  return (
    <section className="stack">
      <div className="picker-row"><input aria-label="Member code" maxLength={12} value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="12-character code" /><button className="primary" disabled={code.length !== 12} onClick={() => check(code)}>Check in</button></div>
      <button className="secondary" onClick={scanning ? stop : scan}>{scanning ? "Stop camera" : "Scan QR with camera"}</button>
      <video ref={video} className={scanning ? "scanner" : "sr-only"} muted playsInline aria-hidden={!scanning} />
      {result && <div className="panel success-card"><h3>✓ {result.displayName}</h3><p>{result.membership} · valid until {new Date(result.endsAt + "Z").toLocaleDateString()} · visit #{result.visits}</p></div>}
      <Err e={error} />
    </section>
  );
}

export function Products({ club }) {
  const [v, setV] = useState(0), [list, error] = useLoad(`/clubs/${club.clubId}/products`, v), [f, setF] = useState(null), [err, setErr] = useState("");
  async function save(e) { e.preventDefault(); setErr(""); try { await api(`/clubs/${club.clubId}/products`, "POST", { ...f, price: Number(f.price), durationDays: Number(f.durationDays), credits: f.kind === "ClassPack" ? Number(f.credits) : null }); setF(null); setV((x) => x + 1); } catch (x) { setErr(x.message); } }
  return (
    <section className="stack">
      <Err e={error || err} />
      {list && <ul className="ledger">{list.map((p) => <li key={p.productId}><span><strong>{p.name}{p.isActive ? "" : " (not on sale)"}</strong><small>{p.kind === "Membership" ? `${p.durationDays}-day membership` : `${p.credits} classes in ${p.durationDays} days`}</small></span><span className="button-row"><strong>{money(p.price)}</strong><button className="text-link" onClick={() => setF({ ...p })}>Edit</button></span></li>)}</ul>}
      {!f ? <div className="button-row"><button className="primary" onClick={() => setF({ kind: "Membership", name: "Monthly membership", price: 30, durationDays: 30, isActive: true })}>+ Membership</button><button className="secondary" onClick={() => setF({ kind: "ClassPack", name: "10-class pack", price: 80, durationDays: 90, credits: 10, isActive: true })}>+ Class pack</button></div> : (
        <form className="panel form-grid" onSubmit={save}>
          <label className="form-wide">Name<input required maxLength={80} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
          <label>Price ($)<input type="number" min="1" max="500" step="0.5" value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} /></label>
          <label>Valid for (days)<input type="number" min="1" max="366" value={f.durationDays} onChange={(e) => setF({ ...f, durationDays: e.target.value })} /></label>
          {f.kind === "ClassPack" && <label>Classes included<input type="number" min="1" max="100" value={f.credits} onChange={(e) => setF({ ...f, credits: e.target.value })} /></label>}
          <label className="checkbox"><input type="checkbox" checked={f.isActive} onChange={(e) => setF({ ...f, isActive: e.target.checked })} />On sale</label>
          <div className="form-wide button-row"><button className="primary">Save</button><button type="button" className="secondary" onClick={() => setF(null)}>Cancel</button></div>
        </form>)}
      <p className="muted small">Players pay from their GameOn wallet. The money is added to your club balance and paid out by GameOn.</p>
    </section>
  );
}

export function Customers({ club }) {
  const [v, setV] = useState(0), [data, error] = useLoad(`/clubs/${club.clubId}/customers`, v), [q, setQ] = useState(""), [b, setB] = useState({ title: "", body: "" }), [msg, setMsg] = useState(""), [err, setErr] = useState("");
  async function send(e) { e.preventDefault(); setErr(""); setMsg(""); try { const r = await api(`/clubs/${club.clubId}/broadcasts`, "POST", b); setMsg(`Sent to ${r.recipients} customers.`); setB({ title: "", body: "" }); setV((x) => x + 1); } catch (x) { setErr(x.message); } }
  const list = (data?.customers || []).filter((c) => c.displayName.toLowerCase().includes(q.toLowerCase()));
  return (
    <section className="stack">
      <Err e={error || err} />
      <input aria-label="Search customers" placeholder="Search customers" value={q} onChange={(e) => setQ(e.target.value)} />
      {data && (list.length === 0 ? <p className="muted">No customers yet.</p> :
        <div className="table-wrap"><table className="data-table"><thead><tr><th>Player</th><th>Bookings</th><th>Cancelled</th><th>Classes</th><th>Spend</th><th>Membership</th><th>Last visit</th></tr></thead>
          <tbody>{list.map((c) => <tr key={c.userId}><td>{c.displayName}{c.isPro ? " · PRO" : ""}</td><td>{c.bookings}</td><td>{c.cancellations}</td><td>{c.classes}</td><td>{money(c.spend)}</td><td>{c.activeMembership || "—"}</td><td>{c.lastVisit ? new Date(c.lastVisit + "Z").toLocaleDateString() : "—"}</td></tr>)}</tbody></table></div>)}
      <form className="panel stack" onSubmit={send}>
        <h3>Message all customers</h3>
        <p className="muted small">Goes to the GameOn inbox of everyone who booked, trained or bought here in the last 6 months. One broadcast per day.</p>
        <label>Title<input required maxLength={120} value={b.title} onChange={(e) => setB({ ...b, title: e.target.value })} placeholder="Ramadan opening hours" /></label>
        <label>Message<textarea required minLength={10} maxLength={600} value={b.body} onChange={(e) => setB({ ...b, body: e.target.value })} /></label>
        <button className="primary">Send broadcast</button>{msg && <p className="success">{msg}</p>}
      </form>
      {data?.broadcasts?.length > 0 && <p className="muted small">Recent: {data.broadcasts.map((x) => `${x.title} (${x.recipients})`).join(" · ")}</p>}
    </section>
  );
}

export function Inventory({ club, rank }) {
  const [v, setV] = useState(0), [list, error] = useLoad(`/clubs/${club.clubId}/inventory`, v), [f, setF] = useState(null), [err, setErr] = useState("");
  async function run(fn) { setErr(""); try { await fn(); setV((x) => x + 1); } catch (e) { setErr(e.message); } }
  return (
    <section className="stack">
      <Err e={error || err} />
      {list && (list.length === 0 ? <p className="muted">No items yet. Track balls, rackets for rent, drinks…</p> : <ul className="ledger">{list.map((i) => (
        <li key={i.itemId}><span><strong>{i.name}</strong><small>{i.quantity} {i.unit}{i.lowStock ? " · LOW: reorder" : ""}{i.unitPrice != null ? ` · ${money(i.unitPrice)} each` : ""}</small></span>
          <span className="button-row">{[["Restock", 10], ["Sale", -1], ["Use", -1]].map(([r, d]) => <button key={r} className="chip" onClick={() => run(() => api(`/inventory/${i.itemId}/adjust`, "POST", { delta: d, reason: r }))}>{r} {d > 0 ? `+${d}` : d}</button>)}</span></li>))}</ul>)}
      {rank >= 3 && (!f ? <button className="secondary" onClick={() => setF({ name: "", unit: "pcs", reorderLevel: 5, unitPrice: "" })}>+ Add item</button> : (
        <form className="panel form-grid" onSubmit={(e) => { e.preventDefault(); run(() => api(`/clubs/${club.clubId}/inventory`, "POST", { ...f, reorderLevel: Number(f.reorderLevel), unitPrice: f.unitPrice === "" ? null : Number(f.unitPrice) })).then(() => setF(null)); }}>
          <label>Item<input required maxLength={80} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
          <label>Unit<input maxLength={20} value={f.unit} onChange={(e) => setF({ ...f, unit: e.target.value })} /></label>
          <label>Reorder at<input type="number" min="0" value={f.reorderLevel} onChange={(e) => setF({ ...f, reorderLevel: e.target.value })} /></label>
          <label>Selling price ($)<input type="number" min="0" step="0.25" value={f.unitPrice} onChange={(e) => setF({ ...f, unitPrice: e.target.value })} /></label>
          <div className="form-wide button-row"><button className="primary">Save</button><button type="button" className="secondary" onClick={() => setF(null)}>Cancel</button></div>
        </form>))}
    </section>
  );
}

export function BackOffice({ club }) {
  const [v, setV] = useState(0), [data, error] = useLoad(`/clubs/${club.clubId}/back-office`, v), [pay, setPay] = useState({ userId: "", month: new Date().toISOString().slice(0, 7), salary: "" }), [msg, setMsg] = useState(""), [err, setErr] = useState("");
  async function run(fn, note) { setErr(""); setMsg(""); try { const r = await fn(); setMsg(note(r)); setV((x) => x + 1); } catch (e) { setErr(e.message); } }
  if (!data) return <Err e={error} />;
  return (
    <section className="stack">
      <Err e={err} />{msg && <p className="success" role="status">{msg}</p>}
      <div className="kpis"><div className="kpi"><span>Held by GameOn for your club</span><strong>{money(data.balance.balance)}</strong><small>From in-app payments · {money(data.balance.paidOut)} paid out so far</small></div></div>
      <form className="panel form-grid" onSubmit={(e) => { e.preventDefault(); run(() => api(`/clubs/${club.clubId}/payroll`, "POST", { userId: Number(pay.userId), month: pay.month + "-01", salary: Number(pay.salary) }), (r) => `Payroll recorded: ${money(r.total)} (commission ${money(r.commission)}). Added to expenses.`); }}>
        <h3 className="form-wide">Payroll</h3>
        <label>Staff<select required value={pay.userId} onChange={(e) => setPay({ ...pay, userId: e.target.value })}><option value="">Choose…</option>{data.staff.filter((s) => s.role !== "Owner").map((s) => <option key={s.userId} value={s.userId}>{s.displayName} ({s.role})</option>)}</select></label>
        <label>Month<input type="month" required value={pay.month} onChange={(e) => setPay({ ...pay, month: e.target.value })} /></label>
        <label>Salary ($)<input type="number" min="0" step="0.01" required value={pay.salary} onChange={(e) => setPay({ ...pay, salary: e.target.value })} /></label>
        <div className="form-wide"><button className="primary">Record pay</button></div>
        <p className="muted small form-wide">Coach commission is added automatically from their classes that month.</p>
      </form>
      <div className="panel"><h3>Coach commission</h3><ul className="ledger">{data.staff.filter((s) => s.role === "Coach").map((s) => <li key={s.userId}><span>{s.displayName}</span>
        <span className="button-row"><input type="number" min="0" max="50" defaultValue={s.commissionPct} aria-label={`Commission for ${s.displayName}`} style={{ width: 80 }} onBlur={(e) => Number(e.target.value) !== s.commissionPct && run(() => api(`/clubs/${club.clubId}/staff/${s.userId}/commission`, "PUT", { commissionPct: Number(e.target.value) }), () => "Commission saved.")} />%</span></li>)}</ul>
        {!data.staff.some((s) => s.role === "Coach") && <p className="muted">Add coaches in Dashboard → Staff.</p>}</div>
      {data.payroll.length > 0 && <div className="panel"><h3>Pay history</h3><ul className="ledger">{data.payroll.map((p) => <li key={p.payId}><span>{p.displayName}<small>{String(p.periodMonth).slice(0, 7)}</small></span><span>{money(p.salary)} + {money(p.commission)}</span></li>)}</ul></div>}
      <div className="panel"><h3>Staff activity</h3><ul className="ledger">{data.activity.map((a) => <li key={a.activityId}><span><strong>{a.displayName}</strong><small>{a.action}{a.detail ? ` · ${a.detail}` : ""}</small></span><small>{new Date(a.at + "Z").toLocaleString()}</small></li>)}</ul></div>
      <div className="panel"><h3>Club balance history</h3><ul className="ledger">{data.ledger.map((l) => <li key={l.entryId}><span>{l.kind}{l.reference ? ` · ${l.reference}` : ""}<small>{new Date(l.createdAt + "Z").toLocaleString()}</small></span><span className={l.amount > 0 ? "amount plus" : "amount minus"}>{money(l.amount)}</span></li>)}</ul></div>
    </section>
  );
}

export function ClassRoster({ classId, onClose }) {
  const [v, setV] = useState(0), [list, error] = useLoad(`/classes/${classId}/roster`, v), [err, setErr] = useState("");
  async function mark(u, attended) { setErr(""); try { await api(`/classes/${classId}/attendance`, "POST", { userId: u.userId, attended }); setV((x) => x + 1); } catch (e) { setErr(e.message); } }
  return (
    <div className="panel stack"><div className="button-row"><h3>Attendance</h3><button className="text-link" onClick={onClose}>Close</button></div>
      <Err e={error || err} />
      {list && (list.length === 0 ? <p className="muted">Nobody registered yet.</p> : <ul className="ledger">{list.map((u) => <li key={u.userId}><span><strong>{u.displayName}</strong><small>{u.status}{u.paidWithPack ? " · class pack" : ""}</small></span>
        {u.status === "Registered" && <span className="button-row"><button className={u.attended === true ? "chip active" : "chip"} onClick={() => mark(u, true)}>Present</button><button className={u.attended === false ? "chip active" : "chip"} onClick={() => mark(u, false)}>Absent</button></span>}</li>)}</ul>)}
    </div>
  );
}
