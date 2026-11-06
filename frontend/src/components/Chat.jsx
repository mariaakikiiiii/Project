import React, { useEffect, useRef, useState } from "react";
import { HubConnectionBuilder, LogLevel } from "@microsoft/signalr";
import { api } from "../api";
import { takePendingChat, ProBadge } from "./community";

// One shared live connection. The server pushes "message" events only to the signed-in user's own group.
let connection, starting;
async function csrfToken() { const r = await fetch("/api/csrf", { credentials: "same-origin" }); return (await r.json()).token; }
export async function live() {
  if (connection) return connection;
  if (!starting) starting = (async () => {
    const token = await csrfToken();
    const c = new HubConnectionBuilder().withUrl("/hubs/live", { headers: { "X-CSRF-TOKEN": token }, withCredentials: true })
      .withAutomaticReconnect().configureLogging(LogLevel.Warning).build();
    await c.start(); connection = c; return c;
  })().catch((e) => { starting = null; throw e; });
  return starting;
}
export function stopLive() { connection?.stop(); connection = null; starting = null; }

function Friends({ onOpen }) {
  const [list, setList] = useState([]), [email, setEmail] = useState(""), [msg, setMsg] = useState(""), [error, setError] = useState(""), [v, setV] = useState(0);
  useEffect(() => { api("/me/friends").then(setList).catch(() => {}); }, [v]);
  async function act(body, note) { setError(""); setMsg(""); try { await api("/me/friends", "POST", body); setMsg(note); setEmail(""); setV((x) => x + 1); } catch (e) { setError(e.message); } }
  const pending = list.filter((f) => f.status === "Pending" && !f.requestedByMe), accepted = list.filter((f) => f.status === "Accepted"), sent = list.filter((f) => f.status === "Pending" && f.requestedByMe);
  return (
    <section className="stack">
      <form className="picker-row" onSubmit={(e) => { e.preventDefault(); act({ action: "Request", email }, "Request sent."); }}>
        <input type="email" required placeholder="Friend's email" aria-label="Friend's email" value={email} onChange={(e) => setEmail(e.target.value)} /><button className="primary">Add friend</button>
      </form>
      <p className="muted small">For privacy, players are found by exact email only.</p>
      {msg && <p className="success" role="status">{msg}</p>}{error && <p className="alert" role="alert">{error}</p>}
      {pending.length > 0 && <><h3>Requests</h3><ul className="ledger">{pending.map((f) => <li key={f.userId}><span><strong>{f.displayName}</strong> <ProBadge show={f.isPro} /></span><span className="button-row"><button className="primary" onClick={() => act({ action: "Accept", userId: f.userId }, "Friend added.")}>Accept</button><button className="text-link" onClick={() => act({ action: "Remove", userId: f.userId }, "Declined.")}>Decline</button></span></li>)}</ul></>}
      <h3>Friends</h3>
      {accepted.length === 0 ? <p className="muted">No friends yet. Add the people you play with.</p> :
        <ul className="ledger">{accepted.map((f) => <li key={f.userId}><span><strong>{f.displayName}</strong> <ProBadge show={f.isPro} /></span><span className="button-row"><button className="secondary" onClick={() => onOpen({ kind: "Direct", userId: f.userId })}>Message</button><button className="text-link" onClick={() => confirm(`Remove ${f.displayName}?`) && act({ action: "Remove", userId: f.userId }, "Removed.")}>Remove</button></span></li>)}</ul>}
      {sent.length > 0 && <p className="muted small">Waiting for: {sent.map((f) => f.displayName).join(", ")}</p>}
    </section>
  );
}

function Thread({ conv, me, onBack }) {
  const [messages, setMessages] = useState([]), [body, setBody] = useState(""), [error, setError] = useState(""), [liveOk, setLiveOk] = useState(true);
  const end = useRef();
  useEffect(() => {
    let off = false, handler;
    api(`/chats/${conv.conversationId}/messages`).then((m) => { if (!off) setMessages(m.reverse()); }).catch((e) => setError(e.message));
    live().then((c) => { handler = (m) => { if (m.conversationId === conv.conversationId) setMessages((old) => old.some((x) => x.messageId === m.messageId) ? old : [...old, m]); }; c.on("message", handler); })
      .catch(() => setLiveOk(false));
    // Fallback refresh every 20 s in case the live connection is unavailable (e.g. a proxy blocks WebSockets).
    const t = setInterval(() => api(`/chats/${conv.conversationId}/messages`).then((m) => !off && setMessages(m.reverse())).catch(() => {}), 20000);
    return () => { off = true; clearInterval(t); connection?.off("message", handler); };
  }, [conv.conversationId]);
  useEffect(() => { end.current?.scrollIntoView({ block: "end" }); }, [messages.length]);
  async function send(e) {
    e.preventDefault(); if (!body.trim()) return; setError("");
    const text = body; setBody("");
    try { const m = await api(`/chats/${conv.conversationId}/messages`, "POST", { body: text, clientKey: crypto.randomUUID() }); setMessages((old) => old.some((x) => x.messageId === m.messageId) ? old : [...old, m]); }
    catch (err) { setBody(text); setError(err.message); }
  }
  return (
    <section className="thread">
      <header className="thread-head"><button className="text-link" onClick={onBack} aria-label="Back to chats">←</button><h2>{conv.title || "Chat"}</h2>{conv.gameId && <a className="text-link" href={`#/events/${conv.gameId}`}>Open game</a>}{!liveOk && <span className="pill warn">Refreshing every 20 s</span>}</header>
      <ol className="messages" aria-live="polite">
        {messages.length === 0 && <li className="muted">Say hi 👋</li>}
        {messages.map((m) => <li key={m.messageId} className={m.senderId === me ? "mine" : ""}><small>{m.senderId === me ? "You" : m.senderName} · {new Date(m.createdAt + "Z").toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</small><p>{m.body}</p></li>)}
        <li ref={end} aria-hidden="true" />
      </ol>
      <form className="composer" onSubmit={send}><input aria-label="Message" maxLength={1000} value={body} onChange={(e) => setBody(e.target.value)} placeholder="Write a message" /><button className="primary" disabled={!body.trim()}>Send</button></form>
      {error && <p className="alert" role="alert">{error}</p>}
    </section>
  );
}

export default function Chat({ user }) {
  const [tab, setTab] = useState("chats"), [list, setList] = useState(null), [open, setOpen] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/chats").then((l) => { setList(l); const pending = takePendingChat(); if (pending) { const c = l.find((x) => x.conversationId === pending); setOpen(c || { conversationId: pending, title: "Chat" }); } }).catch((e) => setError(e.message)); }, [v]);
  useEffect(() => { let c; live().then((x) => { c = x; x.on("message", () => setV((n) => n + 1)); }).catch(() => {}); return () => c?.off("message"); }, []);
  async function openWith(spec) { try { const r = await api("/chats", "POST", spec); setTab("chats"); setOpen({ conversationId: r.conversationId, title: "" }); setV((x) => x + 1); } catch (e) { setError(e.message); } }
  if (open) return <Thread conv={{ ...open, ...(list?.find((c) => c.conversationId === open.conversationId) || {}) }} me={user.userId} onBack={() => { setOpen(null); setV((x) => x + 1); }} />;
  return (
    <section className="chat-page stack">
      <div className="section-heading"><div><span className="overline">PLAYERS · HOSTS · CLUBS</span><h1>Chat</h1></div></div>
      <div className="segmented" role="tablist"><button role="tab" aria-selected={tab === "chats"} className={tab === "chats" ? "active" : ""} onClick={() => setTab("chats")}>Chats</button><button role="tab" aria-selected={tab === "friends"} className={tab === "friends" ? "active" : ""} onClick={() => setTab("friends")}>Friends</button></div>
      {error && <p className="alert" role="alert">{error}</p>}
      {tab === "friends" ? <Friends onOpen={openWith} /> : !list ? <p className="muted">Loading…</p> : list.length === 0 ? (
        <div className="panel"><h2>No chats yet</h2><p className="muted">Every game you join has a group chat. Message clubs from their court page, and friends from the Friends tab.</p></div>
      ) : <ul className="chat-list">{list.map((c) => <li key={c.conversationId}><button onClick={() => setOpen(c)}>
          <span className="chat-kind">{c.kind === "Game" ? "🏆" : c.kind === "Club" ? "🏟️" : "💬"}</span>
          <span className="chat-main"><strong>{c.title}</strong><small>{c.lastMessage || "No messages yet"}</small></span>
          {c.unread > 0 && <span className="badge" aria-label={`${c.unread} unread`}>{c.unread}</span>}
        </button></li>)}</ul>}
    </section>
  );
}
