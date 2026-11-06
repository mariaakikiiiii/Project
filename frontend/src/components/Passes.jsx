import React, { useEffect, useRef, useState } from "react";
import QRCode from "qrcode";
import { api } from "../api";
import { money } from "./community";

// A player's club memberships and class packs, with a QR code to show at the entrance.
function Qr({ code }) {
  const canvas = useRef();
  useEffect(() => { QRCode.toCanvas(canvas.current, code, { width: 200, margin: 1, color: { dark: "#111111", light: "#ffffff" } }).catch(() => {}); }, [code]);
  return <canvas ref={canvas} className="qr" role="img" aria-label={`Entry code ${code}`} />;
}

export function ClubProducts({ club, user, onBought }) {
  const [list, setList] = useState(null), [busy, setBusy] = useState(""), [msg, setMsg] = useState(""), [error, setError] = useState("");
  useEffect(() => { api(`/clubs/${club.clubId}/products`).then(setList).catch(() => setList([])); }, [club.clubId]);
  if (!list || !list.length) return null;
  async function buy(p) {
    if (!user) { location.hash = "#/sign-in"; return; }
    if (!confirm(`Buy ${p.name} for ${money(p.price)} from your GameOn wallet?`)) return;
    setBusy(String(p.productId)); setError(""); setMsg("");
    try { await api(`/products/${p.productId}/buy`, "POST", { idempotencyKey: crypto.randomUUID() }); setMsg(`${p.name} is yours. Find it in Me → Memberships.`); onBought?.(); }
    catch (e) { setError(e.message); } finally { setBusy(""); }
  }
  return (
    <section className="panel">
      <h2>Memberships & class packs</h2>
      <ul className="ledger">{list.filter((p) => p.isActive).map((p) => (
        <li key={p.productId}><span><strong>{p.name}</strong><small>{p.kind === "Membership" ? `Unlimited entry for ${p.durationDays} days` : `${p.credits} classes, valid ${p.durationDays} days`}</small></span>
          <button className="primary" disabled={busy === String(p.productId)} onClick={() => buy(p)}>{money(p.price)}</button></li>))}</ul>
      <p className="muted small">Paid from your GameOn wallet. GameOn passes the money to the club.</p>
      {msg && <p className="success" role="status">{msg}</p>}{error && <p className="alert" role="alert">{error}{error.includes("wallet") && <> · <a href="#/wallet">Top up</a></>}</p>}
    </section>
  );
}

export default function Passes() {
  const [data, setData] = useState(null), [error, setError] = useState("");
  useEffect(() => { api("/me/passes").then(setData).catch((e) => setError(e.message)); }, []);
  if (error) return <p className="alert">{error}</p>;
  if (!data) return <p className="muted">Loading…</p>;
  return (
    <section className="wallet-page">
      <div className="section-heading"><div><span className="overline">CLUB ACCESS</span><h1>Memberships & class packs</h1></div></div>
      {data.passes.length === 0 ? <div className="panel"><p>No memberships yet. Clubs that sell them show a <strong>Memberships & class packs</strong> section on their Courts page.</p></div> :
        <div className="card-grid">{data.passes.map((p) => (
          <article key={p.purchaseId} className={`panel pass ${p.isValid ? "" : "expired"}`}>
            <span className="overline">{p.club}</span><h2>{p.name}</h2>
            {p.kind === "Membership" ? (p.isValid ? <><Qr code={p.accessCode} /><p className="copyable small">{p.accessCode}</p><p className="muted small">Show this at the entrance. Valid until {new Date(p.endsAt + "Z").toLocaleDateString()}.</p></> : <p className="muted">Expired {new Date(p.endsAt + "Z").toLocaleDateString()}</p>)
              : <p><strong>{p.creditsLeft}</strong> class credit{p.creditsLeft === 1 ? "" : "s"} left · until {new Date(p.endsAt + "Z").toLocaleDateString()}<br /><small className="muted">Choose "Use pack credit" when joining a class at {p.club}.</small></p>}
          </article>))}</div>}
      {data.visits.length > 0 && <section className="panel"><h2>Visit history</h2><ul className="ledger">{data.visits.map((v) => <li key={v.checkInId}><span><strong>{v.club}</strong></span><small>{new Date(v.checkedInAt + "Z").toLocaleString()}</small></li>)}</ul></section>}
    </section>
  );
}
