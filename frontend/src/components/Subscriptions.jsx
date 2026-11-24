import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { money, ProBadge } from "./community";

// Free plan (every account) and Premium (stored as GameOn Pro). Demo: Premium activates without taking money in the app.
const freePerks = [
  "Find and join games and events near you",
  "Host your own games, public or private",
  "Book courts at clubs and venues across Lebanon",
  "Chat with friends, groups and clubs",
  "Play & Earn: 20 points per court booking, 15 per class",
  "Redeem points for court discounts",
];
const premiumPerks = [
  ["Discounts on partner courts", "Save up to 50% on every court at GameOn partner clubs."],
  ["Free water bottle", "With every court booking of 1 hour or more."],
  ["50% more points", "30 points per court booking instead of 20."],
  ["100 welcome points", "Added the first time you go Premium."],
  ["PRO badge", "Shown next to your name in games and chat."],
];

export default function Subscriptions({ user, config, navigate, notify }) {
  const [data, setData] = useState(null), [v, setV] = useState(0), [busy, setBusy] = useState(false), [error, setError] = useState("");
  const key = useRef(crypto.randomUUID());
  useEffect(() => { if (user) api("/me/rewards").then(setData).catch((e) => setError(e.message)); }, [user, v]);
  const isPro = !!data?.summary?.isPro, price = data?.pro?.price ?? config?.premiumPrice ?? 5;
  async function start() {
    if (!user) return navigate("auth");
    setBusy(true); setError("");
    try {
      const r = await api("/me/pro", "POST", { idempotencyKey: key.current });
      key.current = crypto.randomUUID();
      notify(`Premium is active until ${new Date(r.endsAt + "Z").toLocaleDateString()}.`);
      setV((x) => x + 1);
    } catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  async function cancel() {
    if (!confirm("End Premium now? You go back to the Free plan immediately.")) return;
    setBusy(true); setError("");
    try { await api("/me/pro", "DELETE"); notify("You're back on the Free plan."); setV((x) => x + 1); }
    catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  return (
    <section className="subscriptions-page">
      <div className="section-heading"><div><span className="overline">PLANS</span><h1>Subscriptions</h1></div></div>
      <p className="lead">Every GameOn account starts on Free. Go Premium for perks at the courts.</p>
      {error && <p className="alert" role="alert">{error}</p>}
      <div className="plan-grid">
        <article className={`panel plan ${user && !isPro ? "current" : ""}`}>
          <span className="overline">INCLUDED WITH EVERY ACCOUNT</span>
          <h2>Free</h2>
          <p className="plan-price">$0 <small>forever</small></p>
          <ul className="perk-list">{freePerks.map((p) => <li key={p}>{p}</li>)}</ul>
          {user ? (!isPro ? <span className="pill ok">Your current plan</span> : <span className="pill">Included</span>)
            : <button className="secondary full" onClick={() => navigate("signup")}>Create a free account</button>}
        </article>
        <article className={`panel plan premium ${isPro ? "current" : ""}`}>
          <span className="overline">FOR REGULAR PLAYERS</span>
          <h2>Premium <ProBadge show /></h2>
          <p className="plan-price">{money(price)} <small>/ 30 days</small></p>
          <p className="muted small">Everything in Free, plus:</p>
          <ul className="perk-list">{premiumPerks.map(([t, d]) => <li key={t}><strong>{t}</strong><small>{d}</small></li>)}</ul>
          {isPro ? <>
            <p className="success">Premium until <strong>{new Date(data.summary.proUntil + "Z").toLocaleDateString()}</strong>.</p>
            <div className="button-row"><button className="primary" disabled={busy} onClick={start}>Add 30 days</button><button className="secondary" disabled={busy} onClick={cancel}>End Premium</button></div>
          </> : <button className="primary full" disabled={busy} onClick={start}>{busy ? "One moment…" : user ? "Start Premium" : "Sign in to go Premium"}</button>}
          <p className="muted small">Demo version: Premium starts right away and no money is collected in the app. It never renews automatically.</p>
        </article>
      </div>
    </section>
  );
}
