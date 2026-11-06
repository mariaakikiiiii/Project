import React from "react";
// Shared helpers for the clubs/community screens.
export const money = (v) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(v) || 0);
// Court hours and class times are Beirut wall-clock times; the API returns them as "LocalStart" without a zone.
export const localTime = (s) => String(s).slice(11, 16);
export const localDate = (s) => new Date(String(s).slice(0, 10) + "T12:00:00").toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
export function beirutToday(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400000);
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Beirut", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
export const nextDays = (n = 14) => Array.from({ length: n }, (_, i) => beirutToday(i));
export function openChat(conversationId) {
  try { sessionStorage.setItem("gameon.openChat", String(conversationId)); } catch { /* storage may be blocked */ }
  location.hash = "#/chat";
}
export function takePendingChat() {
  try { const v = sessionStorage.getItem("gameon.openChat"); sessionStorage.removeItem("gameon.openChat"); return v ? Number(v) : null; } catch { return null; }
}
export const ProBadge = ({ show }) => (show ? <span className="pro-badge" title="GameOn Pro member">PRO</span> : null);
