import React, { useEffect, useState } from "react";
import { api } from "../api";

let lookupCache;
function useSports() {
  const [sports, setSports] = useState(lookupCache || []);
  useEffect(() => { if (!lookupCache) api("/lookups").then((l) => { lookupCache = l.sports; setSports(l.sports); }).catch(() => {}); }, []);
  return sports;
}

// Shared add/correct form for authorized operators. Every save is audited server-side with the operator and note.
export default function VenueEditor({ venue, refresh, onCancel }) {
  const sports = useSports(), adding = !venue;
  const [v, setV] = useState(() => ({
    name: venue?.name || "", area: venue?.area || "", address: venue?.address || "", phone: venue?.contactPhoneNumber || "",
    contactVerified: Boolean(venue?.isVerified), latitude: venue?.latitude ?? "", longitude: venue?.longitude ?? "",
    listingStatus: venue?.listingStatus || "Unverified", sourceName: venue?.sourceName || "", sourceUrl: venue?.sourceUrl || "",
    sourceCheckedOn: venue?.sourceCheckedOn ? String(venue.sourceCheckedOn).slice(0, 10) : "", websiteUrl: venue?.websiteUrl || "",
    reservationMode: venue?.reservationMode || "Unknown", note: "",
    subtypeIds: venue?.subtypeIdsJson ? JSON.parse(venue.subtypeIdsJson) : [],
  }));
  const [busy, setBusy] = useState(false), [error, setError] = useState(""), [saved, setSaved] = useState("");
  const set = (k) => (e) => setV({ ...v, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.value });
  const nul = (x) => (x === "" ? null : x);
  async function save(e) {
    e.preventDefault(); setBusy(true); setError(""); setSaved("");
    const body = { ...v, phone: nul(v.phone), sourceName: nul(v.sourceName), sourceUrl: nul(v.sourceUrl), sourceCheckedOn: nul(v.sourceCheckedOn),
      websiteUrl: nul(v.websiteUrl), note: nul(v.note), latitude: v.latitude === "" ? null : Number(v.latitude), longitude: v.longitude === "" ? null : Number(v.longitude) };
    try {
      if (adding) await api("/operator/venues", "POST", body); else await api(`/operator/venues/${venue.venueId}/directory`, "PUT", body);
      setSaved("Saved and audited."); refresh?.();
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <form className="panel form-grid" onSubmit={save}>
      <h3 className="form-wide">{adding ? "Add a real venue" : `${venue.name} · ${venue.area}`}</h3>
      <label>Venue name<input required maxLength={120} value={v.name} onChange={set("name")} /></label>
      <label>Town / area<input required maxLength={80} value={v.area} onChange={set("area")} /></label>
      <label className="form-wide">Address<input required maxLength={250} value={v.address} onChange={set("address")} /></label>
      <label>Venue phone (optional)<input type="tel" pattern="\+[0-9]{7,15}" maxLength={16} placeholder="+9613…" value={v.phone} onChange={set("phone")} /></label>
      <label className="checkbox"><input type="checkbox" checked={v.contactVerified} onChange={set("contactVerified")} />I phoned this number and reached the venue</label>
      <label>Latitude (optional)<input type="number" step="0.0000001" min="33" max="34.8" value={v.latitude} onChange={set("latitude")} /></label>
      <label>Longitude (optional)<input type="number" step="0.0000001" min="35" max="36.7" value={v.longitude} onChange={set("longitude")} /></label>
      <label>Listing status<select value={v.listingStatus} onChange={set("listingStatus")}><option value="Unverified">Unverified</option><option value="Verified">Verified (official source checked)</option>{!adding && <option value="Demo">Demo (not real)</option>}</select></label>
      <label>How to reserve<select value={v.reservationMode} onChange={set("reservationMode")}><option value="Unknown">Unknown</option><option value="ContactVenue">Contact the venue</option><option value="OnlineBooking">Venue's own online booking</option><option value="WalkIn">Walk-in</option></select></label>
      <label>Source name<input maxLength={120} value={v.sourceName} onChange={set("sourceName")} placeholder="Official website, Instagram…" /></label>
      <label>Source link<input type="url" pattern="https://.*" maxLength={400} value={v.sourceUrl} onChange={set("sourceUrl")} /></label>
      <label>Date you checked the source<input type="date" value={v.sourceCheckedOn} onChange={set("sourceCheckedOn")} /></label>
      <label>Venue website<input type="url" pattern="https://.*" maxLength={400} value={v.websiteUrl} onChange={set("websiteUrl")} /></label>
      <fieldset className="form-wide"><legend>Sports offered (only what the source confirms)</legend><div className="preference-sports">
        {sports.map((s) => <label className="checkbox" key={s.sportId}><input type="checkbox" checked={v.subtypeIds.includes(s.sportId)} onChange={(e) => setV({ ...v, subtypeIds: e.target.checked ? [...v.subtypeIds, s.sportId] : v.subtypeIds.filter((id) => id !== s.sportId) })} />{s.name}</label>)}
      </div></fieldset>
      <label className="form-wide">{adding ? "Note (optional)" : "What you checked and where (required)"}<textarea required={!adding} minLength={adding ? 0 : 4} maxLength={400} value={v.note} onChange={set("note")} /></label>
      <div className="form-wide button-row"><button className="primary" disabled={busy || !v.subtypeIds.length}>{busy ? "Saving…" : adding ? "Add venue" : "Save correction"}</button>{onCancel && <button type="button" className="secondary" onClick={onCancel}>Cancel</button>}</div>
      {saved && <p className="success form-wide" role="status">{saved}</p>}
      {error && <p className="alert form-wide" role="alert">{error}</p>}
    </form>
  );
}
