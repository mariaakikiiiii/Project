import React, { useEffect, useState } from "react";
import { api } from "../api";
import { ProBadge } from "./community";

// "Me": one place for subscription, rewards, club tools, venue listing and settings.
export default function AccountHub({ user, lookups, unread, navigate, children }) {
  const [rewards, setRewards] = useState(null), [clubs, setClubs] = useState([]);
  useEffect(() => {
    api("/me/rewards").then((r) => setRewards(r.summary)).catch(() => {});
    api("/clubs").then((r) => setClubs(r.myClubs)).catch(() => {});
  }, []);
  const tiles = [
    ["subscriptions", "Subscription", rewards?.isPro ? "Premium" : "Free", rewards?.isPro ? "See your Premium perks" : "Compare Free and Premium"],
    ["rewards", "Rewards", rewards ? `${rewards.points} pts` : "…", "Earn and redeem points"],
    ["passes", "Memberships", "Club passes", "QR entry, class packs, visits"],
    ["inbox", "Inbox", unread ? `${unread} new` : "Up to date", "Game updates and approvals"],
    ["listvenue", "List your venue", "Venue owners", "Courts, prices, bookings"],
    ...(user.isAdmin ? [["admin", "Admin panel", "Manage GameOn", "Users, settings, reports"]] : []),
    ...(clubs.length ? [["club", "Club manager", clubs.length === 1 ? clubs[0].name : `${clubs.length} clubs`, "Schedule, courts, dashboard"]] : []),
    ["venues", "Venue directory", "Lebanon", "Find venues to call"],
  ];
  return (
    <section className="stack account-hub">
      <div className="section-heading"><div><span className="overline">YOUR GAMEON</span><h1>{user.name} <ProBadge show={rewards?.isPro} /></h1></div></div>
      <div className="hub-tiles">{tiles.map(([page, title, value, hint]) => (
        <a key={page} className="panel hub-tile" href={`#/${{ subscriptions: "subscriptions", rewards: "rewards", inbox: "inbox", listvenue: "list-your-venue", club: "club", venues: "venues", passes: "memberships", admin: "admin" }[page]}`}
          onClick={(e) => { if (!e.ctrlKey && !e.metaKey) { e.preventDefault(); navigate(page); } }}>
          <span>{title}</span><strong>{value}</strong><small>{hint}</small></a>))}</div>
      <h2>Profile & preferences</h2>
      {children}
    </section>
  );
}
