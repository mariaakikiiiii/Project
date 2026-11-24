import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { money, localTime, localDate, nextDays, openChat, ProBadge } from "./community";
import { ClubProducts } from "./Passes";
import VenueDirectory from "./VenueDirectory";

// Player side: find a club, see live court availability, book a slot, join classes.
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

export const durationLabel = (m) => m < 60 ? `${m} min` : `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}min` : ""}`;

// Durations the player can book from this start: every slot it covers must be free (and before closing).
function freeDurations(slot, courtSlots, prices) {
  const step = (new Date(slot.localEnd) - new Date(slot.localStart)) / 60000;
  const i = courtSlots.findIndex((s) => s.startsAtUtc === slot.startsAtUtc);
  return prices.map((p) => {
    const need = Math.ceil(p.minutes / step), run = courtSlots.slice(i, i + need);
    return { ...p, available: run.length === need && run.every((s) => s.slotStatus === "Free") };
  });
}

function BookSheet({ slot, club, prices, courtSlots, isPro, onClose, onBooked }) {
  const key = useRef(crypto.randomUUID());
  const options = prices.length ? freeDurations(slot, courtSlots, prices) : [];
  const [minutes, setMinutes] = useState(() => options.find((o) => o.available)?.minutes ?? null);
  const [code, setCode] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const chosen = options.find((o) => o.minutes === minutes);
  const list = chosen ? Number(chosen.price) : Number(slot.listPrice);
  const length = chosen ? chosen.minutes : (new Date(slot.localEnd) - new Date(slot.localStart)) / 60000;
  const pro = Number(slot.proDiscountPct) > 0 ? Math.round(list * slot.proDiscountPct) / 100 : 0;
  const [h, m] = localTime(slot.localStart).split(":").map(Number), endMin = h * 60 + m + length;
  const end = `${String(Math.floor(endMin / 60) % 24).padStart(2, "0")}:${String(endMin % 60).padStart(2, "0")}`;
  async function book() {
    setBusy(true); setError("");
    try { const r = await api(`/courts/${slot.courtId}/bookings`, "POST", { startsAtUtc: slot.startsAtUtc + "Z", idempotencyKey: key.current, rewardCode: code.trim() || null, durationMinutes: chosen?.minutes ?? null }); onBooked(r); }
    catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  return (
    <div className="sheet" role="dialog" aria-modal="true" aria-labelledby="book-title">
      <div className="sheet-card">
        <button className="dialog-close" onClick={onClose} aria-label="Close">×</button>
        <span className="overline">{club.name}</span>
        <h2 id="book-title">{slot.court} · {localDate(slot.localStart)} {localTime(slot.localStart)}–{end}</h2>
        {options.length > 0 && <fieldset className="duration-picker"><legend>How long?</legend><div className="chips">
          {options.map((o) => <button type="button" key={o.minutes} className={o.minutes === minutes ? "chip active" : "chip"} disabled={!o.available} aria-pressed={o.minutes === minutes}
            onClick={() => setMinutes(o.minutes)} title={o.available ? "" : "Not free for that long"}>{durationLabel(o.minutes)} · {money(o.price)}</button>)}
        </div>{!options.some((o) => o.available) && <p className="alert">No duration fits from this start time. Pick another slot.</p>}</fieldset>}
        <dl className="fee-breakdown">
          <div><dt>Court price ({durationLabel(length)}){slot.isPeak && !chosen ? " (peak hour)" : ""}</dt><dd>{money(list)}</dd></div>
          {pro > 0 && <div><dt>Premium partner discount ({slot.proDiscountPct}%)</dt><dd>−{money(pro)}</dd></div>}
          <div className="total"><dt>Pay at the club</dt><dd>{money(list - pro)}{code ? " (minus reward)" : ""}</dd></div>
        </dl>
        {isPro && length >= 60 && <p className="success">Premium perk: a free water bottle comes with this booking.</p>}
        <label>Reward code (optional)<input value={code} maxLength={10} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="From Rewards" /></label>
        <p className="muted small">No payment in the app: pay the club in cash or by card when you arrive. Free cancellation up to 6 hours before. Some clubs confirm each booking first; you will be notified. You earn 20 points (30 with Premium).</p>
        <button className="primary full" disabled={busy || (options.length > 0 && !chosen)} onClick={book}>{busy ? "Booking…" : "Book this court"}</button>
        {error && <p className="alert" role="alert">{error}</p>}
      </div>
    </div>
  );
}

function ClubView({ club, user, onBack }) {
  const days = nextDays(14);
  const [day, setDay] = useState(days[0]), [data, setData] = useState(null), [version, setVersion] = useState(0), [pick, setPick] = useState(null), [notice, setNotice] = useState(""), [error, setError] = useState(""), [packs, setPacks] = useState([]), [isPro, setIsPro] = useState(false);
  useEffect(() => { if (user) api("/me/rewards").then((r) => setIsPro(!!r.summary.isPro)).catch(() => {}); }, [user]);
  useEffect(() => { if (user) api("/me/passes").then((r) => setPacks(r.passes.filter((p) => p.clubId === club.clubId && p.kind === "ClassPack" && p.isValid))).catch(() => {}); }, [user, club.clubId, version]);
  async function usePack(c) {
    try { const r = await api(`/classes/${c.classId}/pack-registration`, "POST", { purchaseId: packs[0].purchaseId }); setNotice(`Registered with your class pack (${r.creditsLeft} credits left).`); setVersion((v) => v + 1); } catch (e) { setError(e.message); }
  }
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
      {club.isPartner && Number(club.proDiscountPct) > 0 && <p className="payment-note">Premium members save {club.proDiscountPct}% on every court here. <a href="#/subscriptions">See Premium</a></p>}
      <div className="day-chips" role="tablist" aria-label="Choose a day">
        {days.map((d) => <button key={d} role="tab" aria-selected={d === day} className={d === day ? "chip active" : "chip"} onClick={() => setDay(d)}>{localDate(d + "T00:00")}</button>)}
      </div>
      {notice && <p className="success" role="status">{notice}</p>}
      {error && <p className="alert" role="alert">{error}</p>}
      {!data ? <p className="muted" role="status">Loading availability…</p> : <>
        <SlotGrid slots={data.slots} onPick={(s, k) => { setNotice(""); setError(""); if (s.slotStatus === "Mine") cancel(s); else if (!user) location.hash = "#/sign-in"; else setPick(s); }} />
        {data.classes.length > 0 && <section className="panel"><h2>Classes this day</h2><ul className="ledger">{data.classes.map((c) => (
          <li key={c.classId}><span><strong>{c.title}</strong><small>{localTime(c.localStart)} · {c.durationMinutes} min · {c.registered}/{c.capacity} booked · {money(c.price)}</small></span>
            <span className="button-row">{!c.myStatus && packs.length > 0 && c.registered < c.capacity && <button className="secondary" onClick={() => usePack(c)}>Use pack credit</button>}
            <button className={c.myStatus ? "secondary" : "primary"} onClick={() => classAction(c)}>{c.myStatus === "Registered" ? "Cancel" : c.myStatus === "Waitlisted" ? "Leave waitlist" : c.registered >= c.capacity ? "Join waitlist" : "Join class"}</button></span></li>))}</ul></section>}
      </>}
      <ClubProducts club={club} user={user} onBought={() => setVersion((v) => v + 1)} />
      {pick && data && <BookSheet slot={pick} club={club} isPro={Number(pick.proDiscountPct) > 0 || isPro}
        prices={(data.prices || []).filter((p) => p.courtId === pick.courtId)} courtSlots={data.slots.filter((s) => s.courtId === pick.courtId)}
        onClose={() => setPick(null)} onBooked={(r) => { setPick(null); setNotice(r.status === "Pending" ? "Request sent. The club will confirm it and you will get a notification." : `Booked! Pay ${money(r.price)} at the club.${r.freeWater ? " Your free Premium water bottle is included." : ""}`); setVersion((v) => v + 1); }} />}
    </section>
  );
}

function MyBookings() {
  const [data, setData] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/me/court-bookings").then(setData).catch((e) => setError(e.message)); }, [v]);
  if (error) return <p className="alert">{error}</p>;
  if (!data) return null;
  const upcoming = data.bookings.filter((b) => (b.status === "Confirmed" || b.status === "Pending") && new Date(b.startsAt + "Z") > new Date());
  if (!upcoming.length && !data.classes.length) return null;
  return (
    <section className="panel">
      <h2>Your upcoming courts & classes</h2>
      <ul className="ledger">
        {upcoming.map((b) => <li key={b.bookingId}><span><strong>{b.club} · {b.court}{b.status === "Pending" ? " · awaiting club" : ""}</strong><small>{localDate(b.localStart)} {localTime(b.localStart)} · {b.paidFromWallet ? `paid ${money(b.price)} in-app` : `pay ${money(b.price)} at the club`}{b.proDiscount ? " (Premium price)" : ""}</small></span>
          {b.canCancel ? <button className="secondary" onClick={async () => { if (confirm("Cancel this booking?")) { await api(`/court-bookings/${b.bookingId}`, "DELETE"); setV((x) => x + 1); } }}>Cancel</button> : <span className="pill warn">Within 6 h</span>}</li>)}
        {data.classes.map((c) => <li key={`c${c.classId}`}><span><strong>{c.title}</strong><small>{c.club} · {localDate(c.localStart)} {localTime(c.localStart)}</small></span><span className="pill">{c.status}</span></li>)}
      </ul>
    </section>
  );
}

// "Courts" menu: Find your court (GameOn clubs with live availability) or Find your venue (any venue in Lebanon, on the map).
export default function Courts({ lookups, user, config, mode = "court", navigate }) {
  return (
    <section className="courts-page">
      <div className="section-heading"><div><span className="overline">COURTS · CLUBS · VENUES</span><h1>Courts</h1></div></div>
      <div className="mode-switch" role="tablist" aria-label="What are you looking for?">
        <button role="tab" aria-selected={mode === "court"} className={mode === "court" ? "active" : ""} onClick={() => navigate("courts")}>
          <strong>Find your court</strong><small>Clubs on GameOn · live availability · book online</small></button>
        <button role="tab" aria-selected={mode === "venue"} className={mode === "venue" ? "active" : ""} onClick={() => navigate("venues")}>
          <strong>Find your venue</strong><small>Any venue in Lebanon · map · contact details</small></button>
      </div>
      {mode === "venue" ? <VenueDirectory lookups={lookups} config={config} user={user} embedded /> : <FindCourt lookups={lookups} user={user} />}
    </section>
  );
}

function FindCourt({ lookups, user }) {
  const [sport, setSport] = useState(""), [q, setQ] = useState(""), [data, setData] = useState(null), [club, setClub] = useState(null);
  useEffect(() => { const c = new AbortController(); const t = setTimeout(() => api(`/clubs?${new URLSearchParams({ ...(sport ? { subtypeId: sport } : {}), ...(q.trim() ? { q: q.trim() } : {}) })}`, "GET", undefined, { signal: c.signal }).then(setData).catch(() => {}), 250); return () => { clearTimeout(t); c.abort(); }; }, [sport, q]);
  if (club) return <ClubView club={club} user={user} onBack={() => setClub(null)} />;
  return (
    <>
      {<>
        {user && <MyBookings />}
        <div className="filters-row">
          <input aria-label="Search clubs or towns" placeholder="Search a club or town" value={q} maxLength={80} onChange={(e) => setQ(e.target.value)} />
          <select aria-label="Sport" value={sport} onChange={(e) => setSport(e.target.value)}><option value="">All sports</option>{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select>
        </div>
        {!data ? <p className="muted" role="status">Loading clubs…</p> : data.clubs.length === 0 ? (
          <div className="panel"><h2>No clubs with online booking here yet</h2><p className="muted">Clubs appear once they join GameOn and list their courts. Meanwhile, find venues to call in <a href="#/venues">Find your venue</a>.</p></div>
        ) : <div className="card-grid">{data.clubs.map((c) => (
          <button className="panel club-card" key={c.clubId} onClick={() => setClub(c)}>
            <span className="overline">{c.area}{c.isPartner ? " · PARTNER" : ""}</span><h3>{c.name}</h3>
            <p className="muted small">{c.sports || "Courts coming soon"} · {c.courtCount} court{c.courtCount === 1 ? "" : "s"}</p>
            <p><strong>{c.fromPrice != null ? `From ${money(c.fromPrice)}` : ""}</strong>{c.isPartner && Number(c.proDiscountPct) > 0 ? <span className="pro-badge">PRO −{c.proDiscountPct}%</span> : null}</p>
            <span className="text-link">See availability →</span>
          </button>))}</div>}
      </>}
    </>
  );
}
