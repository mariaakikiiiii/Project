import React, { useEffect, useState } from "react";
import { api } from "../api";
import { openChat, ProBadge } from "./community";

// Open spots, public/private, host approval and the game's group chat.
export default function GameAccess({ id, user, game, isHost, isMember, invite, notify, onChange }) {
  const [data, setData] = useState(null), [v, setV] = useState(0), [message, setMessage] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState(""), [copied, setCopied] = useState(false);
  useEffect(() => { api(`/games/${id}/access${invite ? `?invite=${invite}` : ""}`).then(setData).catch(() => {}); }, [id, v, user?.userId, invite]);
  if (!data) return null;
  const a = data.access, full = a.freeSpots <= 0;
  async function run(fn, note) { setBusy(true); setError(""); try { await fn(); notify?.(note); setV((x) => x + 1); onChange?.(); } catch (e) { setError(e.message); } finally { setBusy(false); } }
  const inviteUrl = a.inviteCode ? `${location.origin}${location.pathname}#/events/${id}?invite=${a.inviteCode}` : "";
  return (
    <section className="panel access-panel" aria-label="Spots and joining">
      <div className="spots">
        <strong className={full ? "full" : "open"}>{game.playerCount}/{game.capacity} players</strong>
        <span>{full ? `Full${a.waitlistCount ? ` · ${a.waitlistCount} on waitlist` : ""}` : `${a.freeSpots} free spot${a.freeSpots === 1 ? "" : "s"}`}</span>
        <span className="pill">{a.visibility === "Private" ? "Private game" : "Public game"}</span>
        {a.joinMode === "Approval" && <span className="pill warn">Host approves players</span>}
      </div>
      {!isHost && user && a.joinMode === "Approval" && !isMember && (
        a.myRequest === "Approved" ? <p className="success">The host approved you. Use Join below to confirm your place before spots run out.</p>
          : a.myRequest === "Pending" ? <p className="payment-note">Request sent. You'll get a notification when the host decides.</p>
          : a.myRequest === "Declined" ? <p className="muted">The host declined this request.</p>
          : <div className="stack"><label>Message to the host (optional)<input maxLength={200} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="Level, position, who you play with…" /></label>
              <button className="primary full" disabled={busy || game.gameStatus !== "Open"} onClick={() => run(() => api(`/games/${id}/join-requests`, "POST", { message, inviteCode: invite || null }), invite ? "You're approved through the invite link." : "Request sent to the host.")}>{invite ? "Accept invite" : "Ask to join"}</button></div>
      )}
      {(isMember || isHost) && <button className="secondary full" onClick={async () => { try { const r = await api("/chats", "POST", { kind: "Game", gameId: id }); openChat(r.conversationId); } catch (e) { setError(e.message); } }}>Open game chat</button>}
      {isHost && (
        <details className="stack" open={data.requests.length > 0}>
          <summary>Who can see and join {data.requests.length > 0 && <span className="badge">{data.requests.length}</span>}</summary>
          <div className="segmented">
            {[["Public", "Instant", "Public · anyone joins"], ["Public", "Approval", "Public · I approve"], ["Private", "Approval", "Private · invite only"]].map(([vis, mode, label]) => (
              <button key={label} className={a.visibility === vis && a.joinMode === mode ? "active" : ""} disabled={busy}
                onClick={() => run(() => api(`/games/${id}/access`, "PUT", { visibility: vis, joinMode: mode }), "Joining rules updated. Players already in keep their places.")}>{label}</button>))}
          </div>
          {inviteUrl && <div className="picker-row"><input readOnly value={inviteUrl} aria-label="Invite link" onFocus={(e) => e.target.select()} /><button className="secondary" onClick={async () => { try { await navigator.clipboard.writeText(inviteUrl); setCopied(true); } catch { setCopied(false); } }}>{copied ? "Copied" : "Copy invite"}</button></div>}
          {data.requests.length > 0 && <ul className="ledger">{data.requests.map((r) => (
            <li key={r.userId}><span><strong>{r.displayName} <ProBadge show={r.isPro} /></strong><small>{r.gamesPlayed} confirmed game{r.gamesPlayed === 1 ? "" : "s"}{r.message ? ` · “${r.message}”` : ""}</small></span>
              <span className="button-row"><button className="primary" disabled={busy} onClick={() => run(() => api(`/games/${id}/join-requests/${r.userId}`, "POST", { approve: true }), `${r.displayName} approved.`)}>Approve</button>
                <button className="text-link" disabled={busy} onClick={() => run(() => api(`/games/${id}/join-requests/${r.userId}`, "POST", { approve: false }), "Declined.")}>Decline</button></span></li>))}</ul>}
        </details>
      )}
      {error && <p className="alert" role="alert">{error}</p>}
    </section>
  );
}
