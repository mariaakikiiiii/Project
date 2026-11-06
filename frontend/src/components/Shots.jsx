import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { ProBadge } from "./community";

// Community photos. Uploads go through multipart (CSRF header included); the server checks the file
// is a real image, limits size, and removes hidden location data before saving.
async function csrf() { const r = await fetch("/api/csrf", { credentials: "same-origin" }); return (await r.json()).token; }

function Upload({ lookups, onDone }) {
  const [file, setFile] = useState(null), [preview, setPreview] = useState(""), [caption, setCaption] = useState(""), [sport, setSport] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const input = useRef();
  function pick(f) {
    setError("");
    if (!f) return;
    if (!["image/jpeg", "image/png", "image/webp"].includes(f.type)) { setError("Choose a JPEG, PNG or WebP photo."); return; }
    if (f.size > 3 * 1024 * 1024) { setError("Photos must be 3 MB or smaller."); return; }
    setFile(f); setPreview(URL.createObjectURL(f));
  }
  async function send(e) {
    e.preventDefault(); if (!file) return; setBusy(true); setError("");
    try {
      const fd = new FormData(); fd.append("photo", file); fd.append("caption", caption); if (sport) fd.append("subtypeId", sport);
      const r = await fetch("/api/shots", { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": await csrf() }, body: fd });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || "Upload failed. Try again.");
      setFile(null); setPreview(""); setCaption(""); input.current.value = ""; onDone();
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <form className="panel stack" onSubmit={send}>
      <h2>Share a shot</h2>
      <input ref={input} type="file" accept="image/jpeg,image/png,image/webp" aria-label="Photo" onChange={(e) => pick(e.target.files[0])} />
      {preview && <img className="shot-preview" src={preview} alt="Preview of your photo" />}
      <label>Caption<input maxLength={280} value={caption} onChange={(e) => setCaption(e.target.value)} placeholder="What happened on court?" /></label>
      <label>Sport<select value={sport} onChange={(e) => setSport(e.target.value)}><option value="">Any</option>{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => <option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select></label>
      <p className="muted small">Only share photos you took and people who agreed to be in them. Location data hidden inside photos is removed automatically.</p>
      <button className="primary" disabled={!file || busy}>{busy ? "Uploading…" : "Share"}</button>
      {error && <p className="alert" role="alert">{error}</p>}
    </form>
  );
}

export default function Shots({ user, lookups }) {
  const [items, setItems] = useState(null), [v, setV] = useState(0), [more, setMore] = useState(true), [error, setError] = useState("");
  useEffect(() => { api("/shots").then((r) => { setItems(r); setMore(r.length === 24); }).catch((e) => setError(e.message)); }, [v]);
  async function loadMore() { const last = items[items.length - 1]; const r = await api(`/shots?beforeId=${last.shotId}`); setItems([...items, ...r]); setMore(r.length === 24); }
  async function act(s, action) {
    let reason = null;
    if (action === "Report") { reason = prompt("What is wrong with this photo?"); if (!reason) return; }
    if (action === "Delete" && !confirm("Delete this shot?")) return;
    try { const r = await api(`/shots/${s.shotId}/action`, "POST", { action, reason });
      setItems((list) => action === "Delete" || action === "Report" ? list.filter((x) => x.shotId !== s.shotId) : list.map((x) => x.shotId === s.shotId ? { ...x, likes: r.likes, likedByMe: action === "Like" } : x)); }
    catch (e) { setError(e.message); }
  }
  return (
    <section className="stack">
      {user ? <Upload lookups={lookups} onDone={() => setV((x) => x + 1)} /> : <p className="muted"><a href="#/sign-in">Sign in</a> to share your shots.</p>}
      {error && <p className="alert" role="alert">{error}</p>}
      {!items ? <p className="muted">Loading…</p> : items.length === 0 ? <p className="muted">No shots yet. Be the first to share a moment from your game.</p> :
        <div className="shots-grid">{items.map((s) => (
          <figure key={s.shotId} className="panel shot">
            <img src={`/api/shots/${s.shotId}/media`} alt={s.caption || `Shot by ${s.displayName}`} loading="lazy" />
            <figcaption>
              <strong>{s.displayName}<ProBadge show={s.isPro} /></strong>{s.sport && <span className="pill">{s.sport}</span>}
              {s.caption && <p>{s.caption}</p>}
              <div className="button-row">
                {user && <button className={s.likedByMe ? "chip active" : "chip"} aria-pressed={s.likedByMe} onClick={() => act(s, s.likedByMe ? "Unlike" : "Like")}>♥ {s.likes}</button>}
                {!user && <span className="muted small">♥ {s.likes}</span>}
                {user && (s.mine ? <button className="text-link" onClick={() => act(s, "Delete")}>Delete</button> : <button className="text-link" onClick={() => act(s, "Report")}>Report</button>)}
              </div>
            </figcaption>
          </figure>))}</div>}
      {items && more && <button className="secondary" onClick={loadMore}>Load more</button>}
    </section>
  );
}
