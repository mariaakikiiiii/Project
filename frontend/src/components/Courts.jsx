import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { money, localTime, localDate, nextDays, openChat, ProBadge } from "./community";

// Player side: find a club, see live court availability, book a slot, join classes, find coaches.
export function SlotGrid({ slots, onPick, selected, staff = false }) {
  const courts = [...new Map(slots.map((s) => [s.courtId, s.court])).entries()];
  if (!slots.length) return <p className="muted">No courts open on this day.</p>;
  return (
    <div className="slot-grid">
      {courts.map(([id, name]) => (
        <div className="slot-row" key={id}>
          <h3>{name}</h3>
          <div className="slots" role="list">
            {slots.filter((s) => s.courtId === id).map((s) => {
              const key = `${s.courtId}|${s.startsAtUtc}`, sel = selected === key;
              const label = `${name} ${localTime(s.localStart)}: ${s.slotStatus === "Free" ? `free, ${money(s.listPrice)}` : s.slotStatus.toLowerCase()}`;
              const clickable = staff ? s.slotStatus !== "Past" : s.slotStatus === "Free" || s.slotStatus === "Mine";
              return (
                <button type="button" role="listitem" key={key} aria-label={label} aria-pressed={sel} disabled={!clickable}
                  className={`slot ${s.slotStatus.toLowerCase()} ${s.isPeak ? "peak" : ""} ${sel ? "selected" : ""}`} onClick={() => onPick(s, key)}>
                  <strong>{localTime(s.localStart)}</strong>
                  <small>{s.slotStatus === "Free" ? money(s.listPrice) : s.slotStatus === "Mine" ? "Yours" : staff && s.bookedBy ? s.bookedBy : staff && s.blockReason ? s.blockReason : s.slotStatus}</small>
                </button>
              );
            })}
          </div>
        </div>
      ))}
      <p className="slot-legend"><span className="slot free" /> Free <span className="slot booked" /> Booked <span className="slot blocked" /> Blocked <span className="slot free peak" /> Peak hour</p>
    </div>
  );
}

function BookSheet({ slot, club, onClose, onBooked }) {
  const key = useRef(crypto.randomUUID());
  const [code, setCode] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const pro = Number(slot.proDiscountPct) > 0 ? Math.round(slot.listPrice * slot.proDiscountPct) / 100 : 0;
  async function book() {
    setBusy(true); setError("");
    try { const r = await api(`/courts/${slot.courtId}/bookings`, "POST", { startsAtUtc: slot.startsAtUtc + "Z", idempotencyKey: key.current, rewardCode: code.trim() || null }); onBooked(r); }
    catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  return (
    <div className="sheet" role="dialog" aria-modal="true" aria-labelledby="book-title">
      <div className="sheet-card">
        <button className="dialog-close" onClick={onClose} aria-label="Close">×</button>
        <span className="overline">{club.name}</span>
        <h2 id="book-title">{slot.court} · {localDate(slot.localStart)} {localTime(slot.localStart)}–{localTime(slot.localEnd)}</h2>
        <dl className="fee-breakdown">
          <div><dt>Court price{slot.isPeak ? " (peak hour)" : ""}</dt><dd>{money(slot.listPrice)}</dd></div>
          {pro > 0 && <div><dt>GameOn Pro partner discount ({slot.proDiscountPct}%)</dt><dd>−{money(pro)}</dd></div>}
          <div className="total"><dt>Pay at the club</dt><dd>{money(slot.listPrice - pro)}{code ? " (minus reward)" : ""}</dd></div>
        </dl>
        <label>Reward code (optional)<input value={code} maxLength={10} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="From Rewards" /></label>
        <p className="muted small">Your court is reserved instantly. You pay the club on arrival. Free cancellation up to 6 hours before. You earn 20 points (30 with Pro).</p>
        <button className="primary full" disabled={busy} onClick={book}>{busy ? "Booking…" : "Book this court"}</button>
        {error && <p className="alert" role="alert">{error}</p>}
      </div>
    </div>
  );
}

function ClubView({ club, user, onBack }) {
  const days = nextDays(14);
  const [day, setDay] = useState(days[0]), [data, setData] = useState(null), [version, setVersion] = useState(0), [pick, setPick] = useState(null), [notice, setNotice] = useState(""), [error, setError] = useState("");
  useEffect(() => { const c = new AbortController(); setData(null); api(`/clubs/${club.clubId}/schedule?date=${day}`, "GET", undefined, { signal: c.signal }).then(setData).catch((e) => { if (e.name !== "AbortError") setError(e.message); }); return () => c.abort(); }, [club.clubId, day, version]);
  async function classAction(c) {
    if (!user) { location.hash = "#/sign-in"; return; }
    try { const r = await api(`/classes/${c.classId}/registration`, "POST", { cancel: !!c.myStatus }); setNotice(r.status === "Waitlisted" ? "Class is full. You're on the waitlist." : r.status === "Cancelled" ? "Class registration cancelled." : "You're registered for the class!"); setVersion((v) => v + 1); }
    catch (e) { setError(e.message); }
  }
  async function cancel(s) {
    if (!confirm("Cancel this court booking?")) return;
    try { await api(`/court-bookings/${s.bookingId}`, "DELETE"); setNotice("Booking cancelled."); setVersion((v) => v + 1); } catch (e) { setError(e.message); }
  }
  async function message() {
    try { const r = await api("/chats", "POST", { kind: "Club", clubId: club.clubId }); openChat(r.conversationId); } catch (e) { setError(e.message); }
  }
  return (
    <section className="club-view">
      <button className="text-link back" onClick={onBack}>← All clubs</button>
      <div className="club-head">
        <div><span className="overline">{club.area}{club.isPartner ? " · PARTNER CLUB" : ""}</span><h1>{club.name}</h1><p className="muted">{club.address}{club.sports ? ` · ${club.sports}` : ""}</p></div>
        <div className="button-row">
          {club.contactPhoneNumber && <a className="secondary" href={`tel:${club.contactPhoneNumber}`}>Call</a>}
          {user && <button className="secondary" onClick={message}>Message the club</button>}
          {club.latitude != null && <a className="secondary" target="_blank" rel="noopener noreferrer" href={`https://www.google.com/maps/dir/?api=1&destination=${club.latitude},${club.longitude}`}>Directions ↗</a>}
        </div>
      </div>
      {club.isPartner && Number(club.proDiscountPct) > 0 && <p className="payment-note">GameOn Pro members save {club.proDiscountPct}% on every court here.</p>}
      <div className="day-chips" role="tablist" aria-label="Choose a day">
        {days.map((d) => <button key={d} role="tab" aria-selected={d === day} className={d === day ? "chip active" : "chip"} onClick={() => setDay(d)}>{localDate(d + "T00:00")}</button>)}
      </div>
      {notice && <p className="success" role="status">{notice}</p>}
      {error && <p className="alert" role="alert">{error}</p>}
      {!data ? <p className="muted" role="status">Loading availability…</p> : <>
        <SlotGrid slots={data.slots} onPick={(s, k) => { setNotice(""); setError(""); if (s.slotStatus === "Mine") cancel(s); else if (!user) location.hash = "#/sign-in"; else setPick(s); }} />
        {data.classes.length > 0 && <section className="panel"><h2>Classes this day</h2><ul className="ledger">{data.classes.map((c) => (
          <li key={c.classId}><span><strong>{c.title}</strong><small>{localTime(c.localStart)} · {c.durationMinutes} min{c.coach ? ` · Coach ${c.coach}` : ""} · {c.registered}/{c.capacity} booked · {money(c.price)}</small></span>
            <button className={c.myStatus ? "secondary" : "primary"} onClick={() => classAction(c)}>{c.myStatus === "Registered" ? "Cancel" : c.myStatus === "Waitlisted" ? "Leave waitlist" : c.registered >= c.capacity ? "Join waitlist" : "Join class"}</button></li>))}</ul></section>}
      </>}
      {pick && <BookSheet slot={pick} club={club} onClose={() => setPick(null)} onBooked={(r) => { setPick(null); setNotice(`Booked! Pay ${money(r.price)} at the club. +points added.`); setVersion((v) => v + 1); }} />}
    </section>
  );
}

function Coaches({ lookups }) {
  const [sport, setSport] = useState(""), [data, setData] = useState(null);
  useEffect(() => { api(`/coaches${sport ? `?subtypeId=${sport}` : ""}`).then(setData).catch(() => setData({ coaches: [] })); }, [sport]);
  return (
    <section className="stack">
      <label>Sport<select value={sport} onChange={(e) => setSport(e.target.value)}><option value="">All sports</option>{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select></label>
      {!data ? <p className="muted">Loading coaches…</p> : data.coaches.length === 0 ? <p className="muted">No coaches listed for this sport yet. Coaches can create a profile from Me → Coach profile.</p> :
        <div className="card-grid">{data.coaches.map((c) => (
          <article className="panel coach-card" key={c.userId}>
            <h3>{c.displayName} <ProBadge show={c.isPro} /></h3><p><strong>{c.headline}</strong></p>
            <p className="muted small">{[c.sports, c.area, c.clubs && `Coaches at ${c.clubs}`].filter(Boolean).join(" · ")}</p>
            {c.bio && <p className="small">{c.bio}</p>}
            <p>{c.hourlyRate != null ? `${money(c.hourlyRate)}/hour` : "Rate on request"}{c.upcomingClasses > 0 ? ` · ${c.upcomingClasses} upcoming classes` : ""}</p>
          </article>))}</div>}
    </section>
  );
}

function MyBookings() {
  const [data, setData] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/me/court-bookings").then(setData).catch((e) => setError(e.message)); }, [v]);
  if (error) return <p className="alert">{error}</p>;
  if (!data) return null;
  const upcoming = data.bookings.filter((b) => b.status === "Confirmed" && new Date(b.startsAt + "Z") > new Date());
  if (!upcoming.length && !data.classes.length) return null;
  return (
    <section className="panel">
      <h2>Your upcoming courts & classes</h2>
      <ul className="ledger">
        {upcoming.map((b) => <li key={b.bookingId}><span><strong>{b.club} · {b.court}</strong><small>{localDate(b.localStart)} {localTime(b.localStart)} · pay {money(b.price)} at the club{b.proDiscount ? " (Pro price)" : ""}</small></span>
          {b.canCancel ? <button className="secondary" onClick={async () => { if (confirm("Cancel this booking?")) { await api(`/court-bookings/${b.bookingId}`, "DELETE"); setV((x) => x + 1); } }}>Cancel</button> : <span className="pill warn">Within 6 h</span>}</li>)}
        {data.classes.map((c) => <li key={`c${c.classId}`}><span><strong>{c.title}</strong><small>{c.club} · {localDate(c.localStart)} {localTime(c.localStart)}</small></span><span className="pill">{c.status}</span></li>)}
      </ul>
    </section>
  );
}

export default function Courts({ lookups, user }) {
  const [tab, setTab] = useState("clubs"), [sport, setSport] = useState(""), [q, setQ] = useState(""), [data, setData] = useState(null), [club, setClub] = useState(null);
  useEffect(() => { const c = new AbortController(); const t = setTimeout(() => api(`/clubs?${new URLSearchParams({ ...(sport ? { subtypeId: sport } : {}), ...(q.trim() ? { q: q.trim() } : {}) })}`, "GET", undefined, { signal: c.signal }).then(setData).catch(() => {}), 250); return () => { clearTimeout(t); c.abort(); }; }, [sport, q]);
  if (club) return <ClubView club={club} user={user} onBack={() => setClub(null)} />;
  return (
    <section className="courts-page">
      <div className="section-heading"><div><span className="overline">BOOK A COURT · JOIN A CLASS · FIND A COACH</span><h1>Courts & clubs</h1></div></div>
      <div className="segmented" role="tablist"><button role="tab" aria-selected={tab === "clubs"} className={tab === "clubs" ? "active" : ""} onClick={() => setTab("clubs")}>Clubs & courts</button><button role="tab" aria-selected={tab === "coaches"} className={tab === "coaches" ? "active" : ""} onClick={() => setTab("coaches")}>Coaches</button></div>
      {tab === "coaches" ? <Coaches lookups={lookups} /> : <>
        {user && <MyBookings />}
        <div className="filters-row">
          <input aria-label="Search clubs or towns" placeholder="Search a club or town" value={q} maxLength={80} onChange={(e) => setQ(e.target.value)} />
          <select aria-label="Sport" value={sport} onChange={(e) => setSport(e.target.value)}><option value="">All sports</option>{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select>
        </div>
        {!data ? <p className="muted" role="status">Loading clubs…</p> : data.clubs.length === 0 ? (
          <div className="panel"><h2>No clubs with online booking here yet</h2><p className="muted">Clubs appear once they join GameOn and list their courts. Meanwhile, find venues to call in <a href="#/venues">Venues</a>.</p></div>
        ) : <div className="card-grid">{data.clubs.map((c) => (
          <button className="panel club-card" key={c.clubId} onClick={() => setClub(c)}>
            <span className="overline">{c.area}{c.isPartner ? " · PARTNER" : ""}</span><h3>{c.name}</h3>
            <p className="muted small">{c.sports || "Courts coming soon"} · {c.courtCount} court{c.courtCount === 1 ? "" : "s"}</p>
            <p><strong>{c.fromPrice != null ? `From ${money(c.fromPrice)}` : ""}</strong>{c.isPartner && Number(c.proDiscountPct) > 0 ? <span className="pro-badge">PRO −{c.proDiscountPct}%</span> : null}</p>
            <span className="text-link">See availability →</span>
          </button>))}</div>}
      </>}
    </section>
  );
}
