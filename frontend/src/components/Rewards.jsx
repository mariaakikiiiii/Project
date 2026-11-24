import React, { useEffect, useState } from "react";
import { api } from "../api";
import { ProBadge } from "./community";

const reasonText = { CourtBooking: "Court booking", Class: "Class", GamePlayed: "Game played", Redemption: "Reward redeemed", Reversal: "Cancelled booking", ProBonus: "Premium welcome bonus" };

export default function Rewards() {
  const [data, setData] = useState(null), [v, setV] = useState(0), [msg, setMsg] = useState(""), [error, setError] = useState(""), [busy, setBusy] = useState("");
  useEffect(() => { api("/me/rewards").then(setData).catch((e) => setError(e.message)); }, [v]);
  async function run(id, fn, note) { setBusy(id); setMsg(""); setError(""); try { const r = await fn(); setMsg(note(r)); setV((x) => x + 1); } catch (e) { setError(e.message); } finally { setBusy(""); } }
  if (error && !data) return <p className="alert" role="alert">{error}</p>;
  if (!data) return <p className="muted">Loading…</p>;
  const s = data.summary;
  return (
    <section className="wallet-page">
      <div className="wallet-hero">
        <span className="overline">PLAY & EARN</span>
        <p className="wallet-balance">{s.points} pts</p>
        <p className="muted">{s.lifetimePoints} earned in total · Court booking +20 (Premium +30) · Class +15</p>
      </div>
      {msg && <p className="success" role="status">{msg}</p>}{error && <p className="alert" role="alert">{error}</p>}
      <section className={`panel pro-card ${s.isPro ? "active" : ""}`}>
        <h2>{s.isPro ? "You're on Premium" : "Earn more with Premium"} <ProBadge show={s.isPro} /></h2>
        <p>{s.isPro ? `30 points per court booking until ${new Date(s.proUntil + "Z").toLocaleDateString()}.` : "Premium members earn 30 points per court booking instead of 20, plus partner-court discounts and free water."}</p>
        <a className="primary" href="#/subscriptions">{s.isPro ? "Manage subscription" : "See subscriptions"}</a>
      </section>
      <section className="panel">
        <h2>Rewards</h2>
        <ul className="ledger">{data.rewards.map((r) => (
          <li key={r.rewardId}><span><strong>{r.title}</strong><small>{r.description}{r.club ? ` · ${r.club} only` : ""}</small></span>
            <button className={s.points >= r.pointsCost ? "primary" : "secondary"} disabled={s.points < r.pointsCost || busy === `r${r.rewardId}`}
              onClick={() => run(`r${r.rewardId}`, () => api(`/me/rewards/${r.rewardId}/redeem`, "POST", { idempotencyKey: crypto.randomUUID() }), (x) => `Your code: ${x.code}. Enter it when booking a court.`)}>{r.pointsCost} pts</button></li>))}</ul>
      </section>
      {data.codes.length > 0 && <section className="panel"><h2>Your codes</h2><ul className="ledger">{data.codes.map((c) => <li key={c.redemptionId}><span><strong className="copyable">{c.code}</strong><small>{c.title} · valid until {new Date(c.expiresAt + "Z").toLocaleDateString()}</small></span><span className={`pill ${c.status === "Issued" ? "ok" : ""}`}>{c.status === "Issued" ? "Ready to use" : c.status}</span></li>)}</ul></section>}
      <section className="panel"><h2>Points history</h2>{data.history.length === 0 ? <p className="muted">Book a court, join a class or play a game to start earning.</p> :
        <ul className="ledger">{data.history.map((h) => <li key={h.entryId}><span><strong>{reasonText[h.reason] || h.reason}</strong><small>{new Date(h.createdAt + "Z").toLocaleString()}</small></span><span className={h.points > 0 ? "amount plus" : "amount minus"}>{h.points > 0 ? "+" : ""}{h.points}</span></li>)}</ul>}</section>
    </section>
  );
}
