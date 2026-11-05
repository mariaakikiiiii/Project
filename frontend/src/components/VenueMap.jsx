import React, { useEffect, useRef, useState } from "react";
let mapsPromise;
function loadMaps(key) {
  if (window.google?.maps?.importLibrary) return Promise.resolve(window.google.maps);
  if (!mapsPromise) mapsPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(key)}&v=weekly&loading=async&callback=__gameonMapsReady`;
    script.async = true;
    const timeout = setTimeout(() => { delete window.__gameonMapsReady; reject(new Error("Google Maps took too long to load. Check the connection and key restrictions.")); }, 15000);
    window.__gameonMapsReady = () => { clearTimeout(timeout); delete window.__gameonMapsReady; resolve(window.google.maps); };
    script.onerror = () => { clearTimeout(timeout); delete window.__gameonMapsReady; mapsPromise = null; reject(new Error("Google Maps could not load. You can still open the venue search in Google Maps.")); };
    document.head.appendChild(script);
  });
  return mapsPromise;
}
function venueTerm(type) {
  return ({ Basketball: "basketball court rental", "Football (Soccer)": "football pitch rental", Padel: "padel courts", Tennis: "tennis courts", Volleyball: "volleyball courts", Badminton: "badminton courts", "Table Tennis (Ping Pong)": "table tennis clubs", Squash: "squash courts", Swimming: "swimming pools", Paintball: "paintball fields", "Laser Tag": "laser tag arenas", "iCombat / Tactical Laser Tag": "tactical laser tag", "Escape Rooms": "escape rooms", "Go-Karting": "go kart tracks", Bowling: "bowling alleys", "Archery Tag": "archery tag", Airsoft: "airsoft fields" })[type] || "sports and activity venues";
}
export function googleVenueSearch(type, area = "") {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${venueTerm(type)} ${area} Lebanon`)}`;
}
export default function VenueMap({ config = {}, type, onSelect, value }) {
  const canvas = useRef(), map = useRef(), markers = useRef([]), alive = useRef(false);
  const selection = useRef(onSelect);
  selection.current = onSelect;
  const [area, setArea] = useState(""), [places, setPlaces] = useState([]), [ready, setReady] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState("");
  useEffect(() => {
    if (!config.mapsBrowserApiKey) return;
    alive.current = true;
    let listener;
    loadMaps(config.mapsBrowserApiKey).then(async maps => {
      const { Map } = await maps.importLibrary("maps");
      if (!alive.current) return;
      map.current = new Map(canvas.current, { center: { lat: 33.89, lng: 35.50 }, zoom: 9, mapId: config.mapsMapId || "DEMO_MAP_ID", streetViewControl: false, mapTypeControl: false,
        restriction: { latLngBounds: { north: 34.8, south: 33, east: 36.7, west: 35 }, strictBounds: false } });
      listener = map.current.addListener("click", async event => {
        if (!selection.current) return;
        const { AdvancedMarkerElement } = await maps.importLibrary("marker");
        if (!alive.current) return;
        markers.current.forEach(m => { m.map = null; });
        markers.current = [new AdvancedMarkerElement({ map: map.current, position: event.latLng })];
        selection.current({ name: "", latitude: event.latLng.lat(), longitude: event.latLng.lng(), placeId: null });
      });
      setReady(true);
    }).catch(e => { if (alive.current) setError(e.message); });
    return () => { alive.current = false; listener?.remove(); markers.current.forEach(m => { m.map = null; }); };
  }, [config.mapsBrowserApiKey, config.mapsMapId]);
  useEffect(() => { setPlaces([]); }, [type]);
  async function search() {
    setBusy(true); setError("");
    try {
      const maps = await loadMaps(config.mapsBrowserApiKey);
      const { Place } = await maps.importLibrary("places"), { AdvancedMarkerElement } = await maps.importLibrary("marker");
      const response = await Place.searchByText({ textQuery: `${venueTerm(type)} ${area} Lebanon`, fields: ["id", "displayName", "formattedAddress", "location", "addressComponents", "googleMapsURI"],
        locationRestriction: { north: 34.8, south: 33, east: 36.7, west: 35 }, region: "lb", maxResultCount: 20 });
      if (!alive.current) return;
      const results = (response.places || []).filter(p => p.addressComponents?.some(c => c.types.includes("country") && c.shortText === "LB"));
      setPlaces(results); markers.current.forEach(m => { m.map = null; });
      markers.current = results.map(p => { const marker = new AdvancedMarkerElement({ map: map.current, position: p.location, title: p.displayName });
        marker.addListener("click", () => { if (selection.current) choose(p); }); return marker; });
      if (results[0]) map.current.setCenter(results[0].location);
      if (!results.length) setError("No matching Google listings were found in this search. Try a nearby town or choose a pin.");
    } catch { if (alive.current) setError("Venue search is unavailable. Check Places API access or use the Google Maps link."); }
    finally { if (alive.current) setBusy(false); }
  }
  function choose(place) {
    selection.current?.({ name: place.displayName, latitude: place.location.lat(), longitude: place.location.lng(), placeId: place.id });
    map.current.setCenter(place.location); map.current.setZoom(15);
  }
  return <section className="venue-finder" aria-label="Find venues in Lebanon">
    <div className="venue-search-row">
      <label>Town or neighborhood<input value={area} maxLength={80} placeholder="Beirut, Tripoli, Saida…" onChange={e => setArea(e.target.value)}/></label>
      {config.mapsBrowserApiKey && <button type="button" className="secondary" disabled={!ready || busy} onClick={search}>{busy ? "Searching…" : "Search venues"}</button>}
      <a className="secondary" href={googleVenueSearch(type, area)} target="_blank" rel="noopener noreferrer">Open Google Maps ↗</a>
    </div>
    <p className="muted">Find {type || "sports and activity venues"} across Lebanon. Call the venue to confirm court rental and availability; a GameOn place does not reserve the venue. Google search shows up to 20 matching listings per search.</p>
    {!config.mapsBrowserApiKey ? <p className="payment-note">Google Maps opens in a new tab. In-app search and pin selection need the site owner’s Google Maps configuration.</p> : <>
      <div className="interactive-map" ref={canvas} aria-label="Google Map of Lebanon"/>
      {onSelect && <p className="muted">Select a search result, or click the map to choose your own meeting point. The country is verified when you publish.</p>}
      <ul className="venue-results">{places.map(p => <li key={p.id}><div><strong>{p.displayName}</strong><small>{p.formattedAddress}</small></div>{onSelect ? <button type="button" className="secondary" onClick={() => choose(p)}>Choose</button> : <a className="text-link" href={p.googleMapsURI} target="_blank" rel="noopener noreferrer">View on Maps ↗</a>}</li>)}</ul>
      {value && <label>Selected location name<input required maxLength={120} value={value.name} onChange={e => onSelect({ ...value, name: e.target.value })}/><small className="muted">Pin: {value.latitude.toFixed(5)}, {value.longitude.toFixed(5)}</small></label>}
    </>}
    {error && <p className="alert" role="alert">{error}</p>}
  </section>;
}
