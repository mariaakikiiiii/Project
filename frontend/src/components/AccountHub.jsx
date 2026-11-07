import React, { useEffect, useState } from "react";
import { api } from "../api";
import { money, ProBadge } from "./community";

// "Me": one place for wallet, rewards, Pro, club tools, coach profile, payments and settings.
function CoachProfile({ lookups }) {
  const [f, setF] = useState(null), [msg, setMsg] = useState(""), [error, setError] = useState("");
  useEffect(() => { api("/coaches?area=__none__").then((r) => { const m = r.mine; setF(m ? { headline: m.headline, bio: m.bio, hourlyRate: m.hourlyRate ?? "", area: m.area ?? "", isListed: m.isListed, subtypeIds: JSON.parse(m.sportsJson || "[]") } : { headline: "", bio: "", hourlyRate: "", area: "", isListed: true, subtypeIds: [] }); }).catch(() => {}); }, []);
  if (!f) return null;
  async function save(e) { e.preventDefault(); setMsg(""); setError(""); try { await api("/me/coach-profile", "PUT", { ...f, hourlyRate: f.hourlyRate === "" ? null : Number(f.hourlyRate) }); setMsg("Coach profile saved."); } catch (err) { setError(err.message); } }
  return (
    <form className="form-grid" onSubmit={save}>
      <label className="form-wide">Headline<input required maxLength={120} value={f.headline} onChange={(e) => setF({ ...f, headline: e.target.value })} placeholder="Certified padel coach, all levels" /></label>
      <label className="form-wide">About you<textarea maxLength={800} value={f.bio} onChange={(e) => setF({ ...f, bio: e.target.value })} /></label>
      <label>Hourly rate ($, optional)<input type="number" min="0" step="1" value={f.hourlyRate} onChange={(e) => setF({ ...f, hourlyRate: e.target.value })} /></label>
      <label>Area<input maxLength={80} value={f.area} onChange={(e) => setF({ ...f, area: e.target.value })} /></label>
      <fieldset className="form-wide"><legend>Sports you coach (1–5)</legend><div className="preference-sports">{lookups.sports.filter((s) => s.categorySlug === "sports").map((s) => (
        <label className="checkbox" key={s.sportId}><input type="checkbox" checked={f.subtypeIds.includes(s.sportId)} disabled={!f.subtypeIds.includes(s.sportId) && f.subtypeIds.length >= 5}
          onChange={(e) => setF({ ...f, subtypeIds: e.target.checked ? [...f.subtypeIds, s.sportId] : f.subtypeIds.filter((x) => x !== s.sportId) })} />{s.name}</label>))}</div></fieldset>
      <label className="checkbox form-wide"><input type="checkbox" checked={f.isListed} onChange={(e) => setF({ ...f, isListed: e.target.checked })} />Show me in Courts → Coaches</label>
      <div className="form-wide"><button className="primary" disabled={!f.subtypeIds.length}>Save coach profile</button></div>
      {msg && <p className="success form-wide">{msg}</p>}{error && <p className="alert form-wide">{error}</p>}
    </form>
  );
}

export default function AccountHub({ user, lookups, unread, navigate, children }) {
  const [wallet, setWallet] = useState(null), [rewards, setRewards] = useState(null), [clubs, setClubs] = useState([]), [coach, setCoach] = useState(() => { try { const v = sessionStorage.getItem("gameon.openCoach") === "1"; sessionStorage.removeItem("gameon.openCoach"); return v; } catch { return false; } });
  useEffect(() => {
    api("/me/wallet").then((w) => setWallet(w.summary)).catch(() => {});
    api("/me/rewards").then((r) => setRewards(r.summary)).catch(() => {});
    api("/clubs").then((r) => setClubs(r.myClubs)).catch(() => {});
  }, []);
  const tiles = [
    ["wallet", "Wallet", wallet ? money(wallet.balance) : "…", "Top up, pay $1, withdraw"],
    ["rewards", "Rewards & Pro", rewards ? `${rewards.points} pts` : "…", rewards?.isPro ? "Pro member" : "Earn points, go Pro"],
    ["passes", "Memberships", "Club passes", "QR entry, class packs, visits"],
    ["inbox", "Inbox", unread ? `${unread} new` : "Up to date", "Game updates and approvals"],
    ["payments", "Payments", "Deposits", "Deposits, refunds, disputes"],
    ...(user.isAdmin ? [["admin", "Admin panel", "Manage GameOn", "Users, settings, reports"]] : []),
    ...(clubs.length ? [["club", "Club manager", clubs.length === 1 ? clubs[0].name : `${clubs.length} clubs`, "Schedule, courts, dashboard"]] : []),
    ["venues", "Venue directory", "Lebanon", "Find venues to call"],
  ];
  return (
    <section className="stack account-hub">
      <div className="section-heading"><div><span className="overline">YOUR GAMEON</span><h1>{user.name} <ProBadge show={rewards?.isPro} /></h1></div></div>
      <div className="hub-tiles">{tiles.map(([page, title, value, hint]) => (
        <a key={page} className="panel hub-tile" href={`#/${{ wallet: "wallet", rewards: "rewards", inbox: "inbox", payments: "payments", club: "club", venues: "venues", passes: "memberships", admin: "admin" }[page]}`}
          onClick={(e) => { if (!e.ctrlKey && !e.metaKey) { e.preventDefault(); navigate(page); } }}>
          <span>{title}</span><strong>{value}</strong><small>{hint}</small></a>))}</div>
      <details className="panel" open={coach} onToggle={(e) => setCoach(e.currentTarget.open)}><summary>Coach profile (appear in Courts → Coaches)</summary>{coach && <CoachProfile lookups={lookups} />}</details>
      <h2>Profile & preferences</h2>
      {children}
    </section>
  );
}
