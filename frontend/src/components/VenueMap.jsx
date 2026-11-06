import React, { useEffect, useRef, useState } from "react";
import {api} from "../api";
let mapsPromise;
function loadMaps(key) {
  if (window.google?.maps?.importLibrary) return Promise.resolve(window.google.maps);
  if (!mapsPromise) mapsPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(key)}&v=weekly&loading=async&callback=__gameonMapsReady`;
    script.async = true;
    const timeout = setTimeout(() => { delete window.__gameonMapsReady; reject(new Error("The map took too long to load. You can still search directory listings.")); }, 15000);
    window.__gameonMapsReady = () => { clearTimeout(timeout); delete window.__gameonMapsReady; resolve(window.google.maps); };
    script.onerror = () => { clearTimeout(timeout); delete window.__gameonMapsReady; mapsPromise = null; reject(new Error("The map could not load. You can still search directory listings.")); };
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
export default function VenueMap({ config = {}, type, subtypeId, onSelect, value }) {
  const canvas = useRef(), map = useRef(), markers = useRef([]), alive = useRef(false);
  const request = useRef(0);
  const [selectedPlace,setSelectedPlace] = useState(null),[notice,setNotice] = useState("");
  const selection = useRef(onSelect);
  selection.current = onSelect;
  const [area, setArea] = useState(""), [places, setPlaces] = useState([]), [ready, setReady] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState("");
  useEffect(() => {
    alive.current = true;
    let listener;
    if (config.mapsBrowserApiKey) loadMaps(config.mapsBrowserApiKey).then(async maps => {
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
    return () => { alive.current = false; request.current++; listener?.remove(); markers.current.forEach(m => { m.map = null; }); };
  }, [config.mapsBrowserApiKey, config.mapsMapId]);
  useEffect(() => {request.current++;setPlaces([]);setSelectedPlace(null);setBusy(false);markers.current.forEach(m=>{m.map=null;});markers.current=[];}, [type,subtypeId]);
  async function search() {
    const sequence=++request.current;setBusy(true);setError("");setNotice("");setSelectedPlace(null);
    const local=api(`/venues/search?${new URLSearchParams({q:area,...(subtypeId?{subtypeId:String(subtypeId)}:{})})}`).then(rows=>rows.map(v=>({
      id:`venue-${v.venueId}`,venueId:v.venueId,displayName:v.name,area:v.area,formattedAddress:v.address,
      location:v.latitude!=null&&v.longitude!=null?{lat:()=>Number(v.latitude),lng:()=>Number(v.longitude)}:null,
      googleMapsURI:`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent([v.name,/\(/.test(v.address||"")?null:v.address,v.area,"Lebanon"].filter(Boolean).join(", "))}`,
      contactPhoneNumber:v.contactPhoneNumber,isVerified:v.isVerified,isDemo:v.isDemo,hasActivityDetails:v.hasActivityDetails,source:"GameOn directory",listingStatus:v.listingStatus,activities:v.activities,reservationMode:v.reservationMode,websiteUrl:v.websiteUrl,sourceName:v.sourceName,sourceUrl:v.sourceUrl,sourceCheckedOn:v.sourceCheckedOn,note:v.directoryNote
    })));
    const google=config.mapsBrowserApiKey?(async()=>{
      const maps=await loadMaps(config.mapsBrowserApiKey),{Place}=await maps.importLibrary("places");
      const response=await Place.searchByText({textQuery:`${venueTerm(type)} ${area} Lebanon`,fields:["id","displayName","formattedAddress","location","addressComponents","googleMapsURI"],locationRestriction:{north:34.8,south:33,east:36.7,west:35},region:"lb",maxResultCount:20});
      return (response.places||[]).filter(p=>p.addressComponents?.some(c=>c.types.includes("country")&&c.shortText==="LB")).map(p=>({...p,id:p.id,displayName:p.displayName,formattedAddress:p.formattedAddress,location:p.location,googleMapsURI:p.googleMapsURI,source:"Google listing"}));
    })():Promise.resolve([]);
    const results=await Promise.allSettled([local,google]);
    if(!alive.current||sequence!==request.current)return;
    const found=results.flatMap(r=>r.status==="fulfilled"?r.value:[]);
    setPlaces(found);setBusy(false);
    if(results[0].status==="rejected")setNotice("GameOn directory is temporarily unavailable.");
    if(results[1].status==="rejected")setNotice("Live map listings are temporarily unavailable. Directory results are shown below.");
    if(!config.mapsBrowserApiKey&&results[0].status==="fulfilled")setNotice("Showing the GameOn directory. More locations appear as venues are added.");
    if(!found.length)setError(results[0].status==="rejected"&&(!config.mapsBrowserApiKey||results[1].status==="rejected")?"Venue search is temporarily unavailable. Please try again.":"No venues matched this search. Try a nearby town or another activity. No external page was opened.");
    markers.current.forEach(m=>{m.map=null;});markers.current=[];
    if(map.current&&found.length){
     try {
      const maps=await loadMaps(config.mapsBrowserApiKey),{AdvancedMarkerElement}=await maps.importLibrary("marker");
      if(!alive.current||sequence!==request.current)return;
      markers.current=found.filter(p=>p.location).map(p=>{const m=new AdvancedMarkerElement({map:map.current,position:p.location,title:p.displayName});m.addListener("click",()=>choose(p));return m;});
      const first=found.find(p=>p.location);if(first)map.current.setCenter(first.location);
     } catch { if(alive.current&&sequence===request.current)setNotice("Map markers could not load. You can still select a venue below."); }
    }
  }
  function choose(place) {
    setSelectedPlace(place);
    if(place.venueId) selection.current?.({venueId:place.venueId,name:place.displayName,area:place.area,address:place.formattedAddress});
    else if(selection.current&&config.mapsPickerAvailable) selection.current({name:place.displayName,latitude:place.location.lat(),longitude:place.location.lng(),placeId:place.id});
    if(place.location&&map.current){map.current.setCenter(place.location);map.current.setZoom(15);}
  }
  return <section className="venue-finder" aria-label="Find venues in Lebanon">
    <div className="venue-search-row"><label>Town or neighborhood<input value={area} maxLength={100} placeholder="Search Jounieh, Beirut, Tripoli…" onChange={e=>setArea(e.target.value)} onKeyDown={e=>{if(e.key==="Enter"){e.preventDefault();if(!busy)search();}}}/></label><button type="button" className="primary" disabled={busy} onClick={search}>{busy?"Searching…":"Search venues"}</button></div>
    <p className="muted">Find {type||"sports and activity venues"} inside GameOn. Call the operator to confirm rental availability; joining a game does not reserve the court.</p>
    {config.mapsBrowserApiKey&&<div className="interactive-map" ref={canvas} aria-label="Google Map of Lebanon"/>}
    {config.mapsPickerAvailable&&onSelect&&<p className="muted">Choose a listed venue, or click the map for your own meeting point.</p>}
    <div aria-live="polite" aria-busy={busy}>
      {notice&&<p className="payment-note">{notice}</p>}
      <ul className="venue-results">{places.map(p=><li className={selectedPlace?.id===p.id?"selected":""} key={p.id}>
       <div><span className="overline">{p.source}</span><strong>{p.displayName}</strong><small>{[p.area,p.formattedAddress].filter(Boolean).join(" · ")}</small>{p.isDemo?<span className="pill danger">Demo venue · not real</span>:p.listingStatus&&<span className={`pill ${p.listingStatus==="Verified"?"ok":"warn"}`}>{p.listingStatus==="Verified"?"Listing checked":"Unverified listing"}</span>}{p.activities&&<small>Sports: {p.activities}</small>}{p.source==="GameOn directory"&&!p.hasActivityDetails&&<small>Activity details not yet confirmed</small>}</div>
       <button type="button" className="secondary" onClick={()=>choose(p)}>{onSelect&&(p.venueId||config.mapsPickerAvailable)?"Choose venue":"View venue"}</button>
      </li>)}</ul>
      {selectedPlace&&<section className="selected-venue" aria-label="Selected venue"><span className="pill">Selected venue</span><h3>{selectedPlace.displayName}</h3><p>{selectedPlace.formattedAddress}</p>{selectedPlace.source==="GameOn directory"&&<dl className="venue-facts"><div><dt>Offers your sport</dt><dd>{selectedPlace.activities||"Not yet confirmed"}</dd></div><div><dt>Reservations</dt><dd>{({ContactVenue:"Contact the venue to reserve",OnlineBooking:"Venue takes online bookings",WalkIn:"Walk-in"})[selectedPlace.reservationMode]||"Unknown. Call to ask"}</dd></div><div><dt>Live availability</dt><dd>Not shown. GameOn has no booking link with this venue.</dd></div><div><dt>Source</dt><dd>{selectedPlace.sourceUrl?<a href={selectedPlace.sourceUrl} target="_blank" rel="noopener noreferrer">{selectedPlace.sourceName||"Source"} ↗</a>:"None recorded"}{selectedPlace.sourceCheckedOn&&` · checked ${String(selectedPlace.sourceCheckedOn).slice(0,10)}`}</dd></div>{selectedPlace.contactPhoneNumber&&!selectedPlace.isVerified&&<div><dt>Phone</dt><dd>Published number, not yet confirmed by GameOn</dd></div>}</dl>}{selectedPlace.note&&<p className="muted">{selectedPlace.note}</p>}{selectedPlace.websiteUrl&&<a className="secondary" href={selectedPlace.websiteUrl} target="_blank" rel="noopener noreferrer">Venue website ↗</a>}{selectedPlace.contactPhoneNumber&&/^\+[0-9]{7,15}$/.test(selectedPlace.contactPhoneNumber)&&<a className="secondary" href={`tel:${selectedPlace.contactPhoneNumber}`}>Call venue</a>}<a className="secondary" href={selectedPlace.googleMapsURI} target="_blank" rel="noopener noreferrer">Directions in Google Maps ↗</a></section>}
    </div>
    {value&&<label>Selected location name<input required maxLength={120} value={value.name} onChange={e=>onSelect({...value,name:e.target.value})}/><small className="muted">Pin: {value.latitude.toFixed(5)}, {value.longitude.toFixed(5)}</small></label>}
    {error&&<p className="alert" role="alert">{error}</p>}
  </section>;

}
