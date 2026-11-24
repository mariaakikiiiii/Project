import React, { useEffect, useState } from "react";
import { api } from "../api";
import { money } from "./community";
import { durationLabel } from "./Courts";
import LocationPicker from "./LocationPicker";

// Venue owners list their club: name, location, courts (sport + a price per duration). GameOn keeps 10% of each booking.
const DURATIONS = [30, 60, 90, 120, 150, 180];
const hours = Array.from({ length: 25 }, (_, h) => h);
const hourLabel = (h) => (h === 24 ? "Midnight" : `${String(h).padStart(2, "0")}:00`);
const newCourt = (n, subtypeId = "") => ({ key: crypto.randomUUID(), courtId: null, name: `Court ${n}`, subtypeId, prices: [{ minutes: 60, price: "" }, { minutes: 90, price: "" }] });

function emptyForm(sport) {
  return { clubId: null, name: "", area: "", address: "", phone: "", location: null, openHour: 8, closeHour: 23, courts: [newCourt(1, sport)], acceptFee: false };
}
function formFromVenue(v, courts, prices) {
  return {
    clubId: v.clubId, name: v.name, area: v.area, address: v.address, phone: v.phone || "", acceptFee: true,
    location: v.latitude != null ? { name: v.name, latitude: Number(v.latitude), longitude: Number(v.longitude) } : null,
    openHour: v.openHour, closeHour: v.closeHour,
    courts: courts.filter((c) => c.clubId === v.clubId).map((c) => ({
      key: String(c.courtId), courtId: c.courtId, name: c.name, subtypeId: String(c.subtypeId),
      prices: prices.filter((p) => p.courtId === c.courtId).map((p) => ({ minutes: p.minutes, price: String(p.price) })),
    })),
  };
}

function CourtEditor({ court, index, sports, onChange, onRemove, canRemove }) {
  const set = (patch) => onChange({ ...court, ...patch });
  const setPrice = (i, patch) => set({ prices: court.prices.map((p, j) => (j === i ? { ...p, ...patch } : p)) });
  const unused = DURATIONS.filter((d) => !court.prices.some((p) => p.minutes === d));
  return (
    <fieldset className="panel court-editor">
      <legend>Court {index + 1}</legend>
      <div className="form-grid">
        <label>Court name<input required maxLength={80} value={court.name} onChange={(e) => set({ name: e.target.value })} placeholder="Court 1, Center court…" /></label>
        <label>Sport<select required value={court.subtypeId} onChange={(e) => set({ subtypeId: e.target.value })}>
          <option value="">Choose a sport…</option>{sports.map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select></label>
      </div>
      <div className="price-rows">
        <span className="price-head">Price per booking</span>
        {court.prices.map((p, i) => (
          <div className="price-row" key={p.minutes}>
            <select aria-label="Duration" value={p.minutes} onChange={(e) => setPrice(i, { minutes: Number(e.target.value) })}>
              {DURATIONS.filter((d) => d === p.minutes || unused.includes(d)).map((d) => <option key={d} value={d}>{durationLabel(d)}</option>)}
            </select>
            <span className="price-input"><span aria-hidden="true">$</span><input aria-label={`Price for ${durationLabel(p.minutes)}`} required type="number" min="0" max="10000" step="0.5" inputMode="decimal"
              value={p.price} onChange={(e) => setPrice(i, { price: e.target.value })} placeholder="0" /></span>
            <button type="button" className="text-link" disabled={court.prices.length === 1} onClick={() => set({ prices: court.prices.filter((_, j) => j !== i) })} aria-label={`Remove the ${durationLabel(p.minutes)} price`}>Remove</button>
          </div>))}
        {unused.length > 0 && <button type="button" className="secondary small" onClick={() => set({ prices: [...court.prices, { minutes: unused[0], price: "" }].sort((a, b) => a.minutes - b.minutes) })}>+ Add a duration</button>}
      </div>
      {canRemove && <button type="button" className="text-link danger-link" onClick={onRemove}>Remove this court</button>}
    </fieldset>
  );
}

function VenueForm({ initial, sports, config, onSaved, onCancel }) {
  const [f, setF] = useState(initial), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const pct = config?.venueCommissionPct ?? 10, isNew = !f.clubId;
  const set = (patch) => setF((x) => ({ ...x, ...patch }));
  async function save(e) {
    e.preventDefault(); setError("");
    if (isNew && !f.acceptFee) return setError(`Please accept the ${pct}% GameOn fee to list your venue.`);
    setBusy(true);
    try {
      const r = await api("/me/venues", "POST", {
        clubId: f.clubId, name: f.name.trim(), area: f.area.trim(), address: f.address.trim(), phone: f.phone.trim() || null,
        latitude: f.location?.latitude ?? null, longitude: f.location?.longitude ?? null, openHour: Number(f.openHour), closeHour: Number(f.closeHour), acceptFee: f.acceptFee,
        courts: f.courts.map((c) => ({ courtId: c.courtId, name: c.name.trim(), subtypeId: Number(c.subtypeId), prices: c.prices.map((p) => ({ minutes: p.minutes, price: Number(p.price) })) })),
      });
      onSaved(r.clubId, isNew);
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <form className="stack venue-form" onSubmit={save}>
      <div className="offer fee-notice" role="note">
        <span>✦ HOW IT WORKS</span>
        <h3>GameOn keeps {pct}% of every successful booking</h3>
        <p>Players book your courts in the app and pay you at the venue. For each booking that takes place, {pct}% of the court price is owed to GameOn. You can see the running total on this page.</p>
        {isNew && <label className="checkbox"><input type="checkbox" checked={f.acceptFee} onChange={(e) => set({ acceptFee: e.target.checked })} />I agree that {pct}% of every successful booking is sent to GameOn.</label>}
      </div>
      <section className="panel form-grid">
        <h2 className="form-wide">Your venue</h2>
        <label className="form-wide">Venue or club name<input required maxLength={120} value={f.name} onChange={(e) => set({ name: e.target.value })} placeholder="e.g. Cedars Padel Club" /></label>
        <label>Town / area<input required maxLength={80} value={f.area} onChange={(e) => set({ area: e.target.value })} placeholder="e.g. Jounieh" /></label>
        <label>Phone (optional)<input maxLength={16} value={f.phone} onChange={(e) => set({ phone: e.target.value.replace(/[^\d+]/g, "") })} placeholder="+96171123456" /></label>
        <label className="form-wide">Address<input required maxLength={250} value={f.address} onChange={(e) => set({ address: e.target.value })} placeholder="Street, building, landmark" /></label>
        <label>Opens<select value={f.openHour} onChange={(e) => set({ openHour: Number(e.target.value) })}>{hours.slice(0, 24).map((h) => <option key={h} value={h}>{hourLabel(h)}</option>)}</select></label>
        <label>Closes<select value={f.closeHour} onChange={(e) => set({ closeHour: Number(e.target.value) })}>{hours.slice(1).map((h) => <option key={h} value={h} disabled={h <= f.openHour}>{hourLabel(h)}</option>)}</select></label>
        <details className="form-wide" open={!!f.location}>
          <summary>Pin it on the map {f.location ? "✓" : "(recommended)"}</summary>
          <LocationPicker value={f.location ? { ...f.location, name: f.location.name || f.name } : null} onChange={(loc) => set({ location: loc })} />
        </details>
      </section>
      <div className="section-heading"><h2>Courts</h2><span className="pill">{f.courts.length}</span></div>
      {f.courts.map((c, i) => (
        <CourtEditor key={c.key} court={c} index={i} sports={sports} canRemove={f.courts.length > 1}
          onChange={(next) => set({ courts: f.courts.map((x) => (x.key === c.key ? next : x)) })}
          onRemove={() => set({ courts: f.courts.filter((x) => x.key !== c.key) })} />))}
      {f.courts.length < 20 && <button type="button" className="secondary" onClick={() => set({ courts: [...f.courts, newCourt(f.courts.length + 1, f.courts[f.courts.length - 1]?.subtypeId || "")] })}>+ Add a court</button>}
      {error && <p className="alert" role="alert">{error}</p>}
      <div className="button-row">
        <button className="primary" disabled={busy}>{busy ? "Saving…" : isNew ? "List my venue" : "Save changes"}</button>
        {onCancel && <button type="button" className="secondary" onClick={onCancel}>Cancel</button>}
      </div>
    </form>
  );
}

export default function ListVenue({ lookups, config, navigate, notify }) {
  const sports = lookups.sports.filter((s) => s.categorySlug === "sports");
  const [data, setData] = useState(null), [v, setV] = useState(0), [editing, setEditing] = useState(null), [error, setError] = useState("");
  useEffect(() => { api("/me/venues").then((d) => { setData(d); if (!d.venues.length) setEditing("new"); }).catch((e) => setError(e.message)); }, [v]);
  const pct = config?.venueCommissionPct ?? 10;
  if (error) return <p className="alert" role="alert">{error}</p>;
  if (!data) return <p className="muted" role="status">Loading…</p>;
  const saved = (clubId, isNew) => { notify(isNew ? "Your venue is listed! Players can book it in Courts." : "Venue updated."); setEditing(null); setV((x) => x + 1); };
  return (
    <section className="list-venue-page">
      <div className="section-heading"><div><span className="overline">FOR VENUE & CLUB OWNERS</span><h1>List your venue</h1></div>
        {data.venues.length > 0 && !editing && <button className="primary small" onClick={() => setEditing("new")}>+ List another venue</button>}</div>
      <p className="lead">Put your courts on GameOn: players see live availability, choose a duration and book in a few taps.</p>
      {editing ? (
        <VenueForm key={editing === "new" ? "new" : editing.clubId} sports={sports} config={config}
          initial={editing === "new" ? emptyForm("") : formFromVenue(editing, data.courts, data.prices)}
          onSaved={saved} onCancel={data.venues.length ? () => setEditing(null) : null} />
      ) : (
        <div className="stack">{data.venues.map((venue) => {
          const courts = data.courts.filter((c) => c.clubId === venue.clubId);
          return (
            <article className="panel my-venue" key={venue.clubId}>
              <div className="section-heading"><div><span className="overline">{venue.area}</span><h2>{venue.name}</h2><p className="muted small">{venue.address} · {String(venue.openHour).padStart(2, "0")}:00–{venue.closeHour === 24 ? "24:00" : `${String(venue.closeHour).padStart(2, "0")}:00`}</p></div>
                <div className="button-row"><button className="secondary" onClick={() => setEditing(venue)}>Edit venue & courts</button><button className="text-link" onClick={() => navigate("club")}>Bookings →</button></div></div>
              <div className="kpis">
                <div className="kpi"><span>Upcoming bookings</span><strong>{venue.upcomingBookings}</strong></div>
                <div className="kpi"><span>Bookings played</span><strong>{venue.playedBookings}</strong><small>Revenue {money(venue.revenue)}</small></div>
                <div className="kpi"><span>Owed to GameOn ({venue.commissionPct}%)</span><strong>{money(venue.commissionOwed)}</strong><small>{venue.isSelfListed ? "From bookings that took place" : "Partner club terms"}</small></div>
              </div>
              <ul className="ledger">{courts.map((c) => (
                <li key={c.courtId}><span><strong>{c.name}</strong><small>{c.sport}</small></span>
                  <span className="price-chips">{data.prices.filter((p) => p.courtId === c.courtId).map((p) => <span className="pill" key={p.minutes}>{durationLabel(p.minutes)} · {money(p.price)}</span>)}
                    {!data.prices.some((p) => p.courtId === c.courtId) && <span className="pill">{c.slotMinutes} min · {money(c.basePrice)}</span>}</span></li>))}</ul>
            </article>);
        })}
          <p className="muted small">GameOn keeps {pct}% of every successful booking at venues you list yourself.</p>
        </div>
      )}
    </section>
  );
}
