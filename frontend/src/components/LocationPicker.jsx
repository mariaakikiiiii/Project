import React, { useEffect, useRef, useState } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { api } from "../api";

// Pick ANY real place in Lebanon: search, paste a Google Maps link, or tap the map.
// Uses OpenStreetMap tiles (no key needed). The server re-checks every pin is inside Lebanon before saving.
const LEBANON = L.latLngBounds([33.0, 35.0], [34.8, 36.7]);
const pinIcon = L.divIcon({ className: "go-pin", html: "<span></span>", iconSize: [28, 28], iconAnchor: [14, 28] });
export const directionsUrl = (lat, lng) => `https://www.google.com/maps/dir/?api=1&destination=${lat},${lng}`;

export function MiniMap({ latitude, longitude, label }) {
  const el = useRef();
  useEffect(() => {
    if (latitude == null || longitude == null) return;
    const map = L.map(el.current, { zoomControl: false, attributionControl: true, dragging: false, scrollWheelZoom: false, doubleClickZoom: false, touchZoom: false, keyboard: false })
      .setView([latitude, longitude], 15);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "© OpenStreetMap" }).addTo(map);
    L.marker([latitude, longitude], { icon: pinIcon, title: label, keyboard: false }).addTo(map);
    return () => map.remove();
  }, [latitude, longitude, label]);
  return <div className="mini-map" ref={el} role="img" aria-label={`Map showing ${label}`} />;
}

export default function LocationPicker({ value, onChange }) {
  const el = useRef(), map = useRef(), marker = useRef(), latest = useRef(value);
  latest.current = value;
  const [query, setQuery] = useState(""), [results, setResults] = useState([]), [link, setLink] = useState("");
  const [busy, setBusy] = useState(""), [error, setError] = useState("");

  function place(lat, lng, name, zoom = 16) {
    const v = { name: name ?? latest.current?.name ?? "", latitude: lat, longitude: lng, placeId: null };
    onChange(v);
    if (!marker.current) {
      marker.current = L.marker([lat, lng], { icon: pinIcon, draggable: true, autoPan: true }).addTo(map.current);
      marker.current.on("dragend", () => { const p = marker.current.getLatLng(); onChange({ ...latest.current, latitude: p.lat, longitude: p.lng }); });
    } else marker.current.setLatLng([lat, lng]);
    map.current.setView([lat, lng], Math.max(map.current.getZoom(), zoom));
  }

  useEffect(() => {
    map.current = L.map(el.current, { maxBounds: LEBANON.pad(0.2), minZoom: 8 }).setView([33.89, 35.6], 9);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "© <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a> contributors" }).addTo(map.current);
    map.current.on("click", (e) => { if (LEBANON.contains(e.latlng)) place(e.latlng.lat, e.latlng.lng); else setError("Choose a place inside Lebanon."); });
    if (latest.current?.latitude != null) place(latest.current.latitude, latest.current.longitude, latest.current.name);
    setTimeout(() => map.current?.invalidateSize(), 50);
    return () => { map.current.remove(); map.current = null; marker.current = null; };
  }, []);

  async function search(e) {
    e?.preventDefault(); if (query.trim().length < 2) return;
    setBusy("search"); setError(""); setResults([]);
    try { const r = await api(`/places/search?q=${encodeURIComponent(query.trim())}`); setResults(r); if (!r.length) setError("No places found. Try a town name, or tap the map."); }
    catch (err) { setError(err.message); } finally { setBusy(""); }
  }
  async function fromLink(e) {
    e?.preventDefault(); if (!link.trim()) return;
    setBusy("link"); setError("");
    try { const r = await api("/places/from-link", "POST", { url: link.trim() }); place(r.latitude, r.longitude, r.name === "Pinned location" ? latest.current?.name || "" : r.name, 17); setLink(""); }
    catch (err) { setError(err.message); } finally { setBusy(""); }
  }

  return (
    <div className="location-picker">
      <div className="picker-tools">
        <div className="picker-row" role="search">
          <label className="sr-only" htmlFor="place-q">Search a place in Lebanon</label>
          <input id="place-q" value={query} maxLength={100} placeholder="Search a place: Jounieh stadium, Zouk, AUB…" onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); search(); } }} />
          <button type="button" className="secondary" onClick={search} disabled={busy === "search"}>{busy === "search" ? "Searching…" : "Search"}</button>
        </div>
        <div className="picker-row">
          <label className="sr-only" htmlFor="place-link">Paste a Google Maps link</label>
          <input id="place-link" value={link} maxLength={2000} placeholder="…or paste a Google Maps link" onChange={(e) => setLink(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); fromLink(); } }} />
          <button type="button" className="secondary" onClick={fromLink} disabled={busy === "link"}>{busy === "link" ? "Reading…" : "Use link"}</button>
        </div>
      </div>
      {results.length > 0 && (
        <ul className="place-results" aria-label="Places found">
          {results.map((r, i) => (
            <li key={i}><button type="button" onClick={() => { place(r.latitude, r.longitude, r.name); setResults([]); }}>
              <strong>{r.name}</strong><small>{r.address}</small></button></li>
          ))}
        </ul>
      )}
      <div className="picker-map" ref={el} aria-label="Map of Lebanon. Tap to drop a pin; drag the pin to adjust." />
      <p className="muted small">Tap the map to drop a pin, then drag it to the exact spot. GameOn checks that the pin is inside Lebanon.</p>
      {error && <p className="alert" role="alert">{error}</p>}
      {value?.latitude != null && (
        <div className="picked">
          <label>Name of this place (players will see it)
            <input required maxLength={120} value={value.name} placeholder="e.g. Zouk Mosbeh public court" onChange={(e) => onChange({ ...value, name: e.target.value })} />
          </label>
          <a className="text-link" href={directionsUrl(value.latitude, value.longitude)} target="_blank" rel="noopener noreferrer">Check this pin in Google Maps ↗</a>
        </div>
      )}
    </div>
  );
}
