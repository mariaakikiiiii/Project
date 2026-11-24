import React, { useEffect, useRef, useState } from "react";
import { HubConnectionBuilder, LogLevel } from "@microsoft/signalr";
import { api } from "../api";
import { takePendingChat, ProBadge } from "./community";
import Shots from "./Shots";

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

const REACTIONS = ["👍", "❤️", "😂", "😮", "😢", "🙏", "🔥"];
const EDIT_WINDOW_MS = 15 * 60 * 1000;
const roleLabel = { Owner: "Owner", Admin: "Admin" };
const parseReactions = (m) => { try { return m.reactionsJson ? JSON.parse(m.reactionsJson) : []; } catch { return []; } };
const time = (iso) => new Date(iso + "Z").toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

function Groups({ onOpen, onInfo }) {
  const [groups, setGroups] = useState(null), [friends, setFriends] = useState([]), [name, setName] = useState(""), [description, setDescription] = useState(""), [pick, setPick] = useState([]), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/me/groups").then(setGroups).catch((e) => setError(e.message)); api("/me/friends").then((f) => setFriends(f.filter((x) => x.status === "Accepted"))).catch(() => {}); }, [v]);
  async function create(e) {
    e.preventDefault(); setError("");
    try { const r = await api("/me/groups", "POST", { name, description, memberIds: pick }); setName(""); setDescription(""); setPick([]); setV((x) => x + 1); onOpen({ conversationId: r.conversationId, title: name, kind: "Group", groupId: r.groupId }); }
    catch (x) { setError(x.message); }
  }
  return (
    <section className="stack">
      {error && <p className="alert" role="alert">{error}</p>}
      {groups && (groups.length === 0 ? <p className="muted">No groups yet. Make one for your regular crew, then invite the whole group to a game in one tap.</p> :
        <ul className="ledger">{groups.map((g) => <li key={g.groupId}>
          <span><strong>{g.name}</strong> {roleLabel[g.myRole] && <span className="pill">{roleLabel[g.myRole]}</span>}<small>{g.description ? g.description + " · " : ""}{g.members} members · {g.memberNames}</small></span>
          <span className="button-row"><button className="secondary" onClick={() => onOpen({ conversationId: g.conversationId, title: g.name, kind: "Group", groupId: g.groupId })}>Chat</button><button className="text-link" onClick={() => onInfo(g.groupId)}>Info</button></span>
        </li>)}</ul>)}
      <form className="panel stack" onSubmit={create}>
        <h3>New group</h3>
        <label>Group name<input required maxLength={60} value={name} onChange={(e) => setName(e.target.value)} placeholder="Tuesday padel crew" /></label>
        <label>Description <span className="muted small">(optional)</span><input maxLength={300} value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Weekly games at 8 pm, split the court fee" /></label>
        {friends.length === 0 ? <p className="muted small">Add friends first. Only friends can be in your groups.</p> :
          <fieldset><legend>Friends to add</legend><div className="preference-sports">{friends.map((f) => <label className="checkbox" key={f.userId}><input type="checkbox" checked={pick.includes(f.userId)} onChange={(e) => setPick(e.target.checked ? [...pick, f.userId] : pick.filter((x) => x !== f.userId))} />{f.displayName}</label>)}</div></fieldset>}
        <button className="primary" disabled={!name.trim()}>Create group</button>
      </form>
    </section>
  );
}

// Group info: name/description, members with roles, add/remove, promote admins, leave.
function GroupInfo({ groupId, me, onBack, onOpenChat, onLeft }) {
  const [data, setData] = useState(null), [friends, setFriends] = useState([]), [edit, setEdit] = useState(null), [addId, setAddId] = useState(""), [error, setError] = useState(""), [confirmLeave, setConfirmLeave] = useState(false), [v, setV] = useState(0);
  useEffect(() => { api(`/groups/${groupId}`).then(setData).catch((e) => setError(e.message)); api("/me/friends").then((f) => setFriends(f.filter((x) => x.status === "Accepted"))).catch(() => {}); }, [groupId, v]);
  useEffect(() => { let c; const h = () => setV((x) => x + 1); live().then((x) => { c = x; x.on("chatChanged", h); }).catch(() => {}); return () => c?.off("chatChanged", h); }, []);
  if (!data) return <section className="stack"><button className="text-link" onClick={onBack}>← Back</button>{error ? <p className="alert" role="alert">{error}</p> : <p className="muted">Loading…</p>}</section>;
  const { group, members } = data, myRole = group.myRole, isAdmin = myRole === "Owner" || myRole === "Admin";
  const candidates = friends.filter((f) => !members.some((m) => m.userId === f.userId));
  async function act(fn) { setError(""); try { await fn(); setV((x) => x + 1); } catch (e) { setError(e.message); } }
  const saveInfo = (e) => { e.preventDefault(); act(async () => { await api(`/groups/${groupId}`, "PUT", edit); setEdit(null); }); };
  const leave = () => act(async () => { await api(`/groups/${groupId}/members`, "POST", { userId: me, add: false }); onLeft(); });
  return (
    <section className="stack group-info">
      <header className="thread-head"><button className="text-link" onClick={onBack} aria-label="Back">←</button><h2>{group.name}</h2><button className="secondary small" onClick={() => onOpenChat({ conversationId: group.conversationId, title: group.name, kind: "Group", groupId })}>Open chat</button></header>
      {error && <p className="alert" role="alert">{error}</p>}
      {edit ? (
        <form className="panel stack" onSubmit={saveInfo}>
          <label>Group name<input required maxLength={60} value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></label>
          <label>Description<textarea maxLength={300} rows={3} value={edit.description} onChange={(e) => setEdit({ ...edit, description: e.target.value })} /></label>
          <span className="button-row"><button className="primary" disabled={!edit.name.trim()}>Save</button><button type="button" className="text-link" onClick={() => setEdit(null)}>Cancel</button></span>
        </form>
      ) : (
        <div className="panel">
          <p className={group.description ? "" : "muted"}>{group.description || "No description yet."}</p>
          <small className="muted">Created {new Date(group.createdAt + "Z").toLocaleDateString()} · {members.length} members</small>
          {isAdmin && <p><button className="text-link" onClick={() => setEdit({ name: group.name, description: group.description || "" })}>Edit name & description</button></p>}
        </div>
      )}
      {isAdmin && (
        <div className="picker-row">
          <select aria-label="Friend to add" value={addId} onChange={(e) => setAddId(e.target.value)}>
            <option value="">{candidates.length ? "Add a friend…" : "All your friends are here"}</option>
            {candidates.map((f) => <option key={f.userId} value={f.userId}>{f.displayName}</option>)}
          </select>
          <button className="primary" disabled={!addId} onClick={() => act(async () => { await api(`/groups/${groupId}/members`, "POST", { userId: Number(addId), add: true }); setAddId(""); })}>Add</button>
        </div>
      )}
      <h3>Members</h3>
      <ul className="ledger">{members.map((m) => {
        const canRemove = m.userId !== me && (myRole === "Owner" || (myRole === "Admin" && m.role === "Member"));
        return <li key={m.userId}>
          <span><strong>{m.userId === me ? "You" : m.displayName}</strong> {roleLabel[m.role] && <span className="pill">{roleLabel[m.role]}</span>}</span>
          <span className="button-row">
            {myRole === "Owner" && m.role !== "Owner" && <button className="text-link" onClick={() => act(() => api(`/groups/${groupId}/role`, "POST", { userId: m.userId, role: m.role === "Admin" ? "Member" : "Admin" }))}>{m.role === "Admin" ? "Remove admin" : "Make admin"}</button>}
            {canRemove && <button className="text-link danger-text" onClick={() => act(() => api(`/groups/${groupId}/members`, "POST", { userId: m.userId, add: false }))}>Remove</button>}
          </span>
        </li>;
      })}</ul>
      {confirmLeave ? (
        <div className="panel stack"><p>Leave <strong>{group.name}</strong>?{myRole === "Owner" && members.length > 1 ? " Ownership passes to an admin, or the longest-standing member." : ""}</p>
          <span className="button-row"><button className="primary" onClick={leave}>Leave group</button><button className="text-link" onClick={() => setConfirmLeave(false)}>Cancel</button></span></div>
      ) : <button className="secondary danger-text" onClick={() => setConfirmLeave(true)}>Leave group</button>}
    </section>
  );
}

function Message({ m, me, myRole, onReply, onEdit, onChanged, onError }) {
  const [picker, setPicker] = useState(false);
  if (m.kind === "System") return <li className="system-note"><span>{m.body}</span></li>;
  const mine = m.senderId === me, reactions = parseReactions(m);
  const grouped = REACTIONS.map((e) => ({ e, people: reactions.filter((r) => r.emoji === e) })).filter((x) => x.people.length);
  const canEdit = mine && !m.isDeleted && Date.now() - new Date(m.createdAt + "Z").getTime() < EDIT_WINDOW_MS;
  const canDelete = !m.isDeleted && (mine || myRole === "Owner" || myRole === "Admin");
  async function call(fn) { try { onChanged(await fn()); } catch (e) { onError(e.message); } }
  const react = (emoji) => { setPicker(false); call(() => api(`/messages/${m.messageId}/reactions`, "POST", { emoji })); };
  return (
    <li className={`msg ${mine ? "mine" : ""} ${m.isDeleted ? "deleted" : ""}`}>
      <small>{mine ? "You" : m.senderName} · {time(m.createdAt)}{m.editedAt && !m.isDeleted ? " · edited" : ""}</small>
      {m.replyToId && <blockquote className="reply-quote"><b>{m.replyToSenderName}</b><span>{m.replyToBody === "" ? "Message deleted" : m.replyToBody}</span></blockquote>}
      <p>{m.isDeleted ? "🚫 This message was deleted" : m.body}</p>
      {grouped.length > 0 && <div className="reactions">{grouped.map(({ e, people }) =>
        <button key={e} className={people.some((p) => p.userId === me) ? "mine" : ""} title={people.map((p) => p.name).join(", ")} onClick={() => react(e)} aria-label={`${e} ${people.length}, by ${people.map((p) => p.name).join(", ")}`}>{e} {people.length}</button>)}</div>}
      {!m.isDeleted && <div className="msg-actions">
        <button onClick={() => setPicker(!picker)} aria-label="React" aria-expanded={picker}>☺</button>
        <button onClick={() => onReply(m)} aria-label="Reply">↩</button>
        {canEdit && <button onClick={() => onEdit(m)} aria-label="Edit">✎</button>}
        {canDelete && <button onClick={() => call(() => api(`/messages/${m.messageId}`, "DELETE"))} aria-label="Delete for everyone">🗑</button>}
      </div>}
      {picker && <div className="reaction-picker" role="menu">{REACTIONS.map((e) => <button key={e} role="menuitem" onClick={() => react(e)}>{e}</button>)}</div>}
    </li>
  );
}

function Thread({ conv, me, onBack, onInfo }) {
  const [messages, setMessages] = useState([]), [body, setBody] = useState(""), [error, setError] = useState(""), [liveOk, setLiveOk] = useState(true);
  const [replyTo, setReplyTo] = useState(null), [editing, setEditing] = useState(null), [myRole, setMyRole] = useState(null);
  const end = useRef(), input = useRef();
  const upsert = (m) => setMessages((old) => old.some((x) => x.messageId === m.messageId) ? old.map((x) => x.messageId === m.messageId ? m : x) : [...old, m]);
  useEffect(() => {
    let off = false, onMsg, onUpd, onChg;
    const load = () => api(`/chats/${conv.conversationId}/messages`).then((m) => { if (!off) setMessages(m.reverse()); }).catch((e) => !off && setError(e.message));
    load();
    if (conv.groupId) api(`/groups/${conv.groupId}`).then((g) => !off && setMyRole(g.group.myRole)).catch(() => {});
    live().then((c) => {
      onMsg = (m) => { if (m.conversationId === conv.conversationId) upsert(m); };
      onUpd = (m) => { if (m.conversationId === conv.conversationId) setMessages((old) => old.map((x) => x.messageId === m.messageId ? m : x.replyToId === m.messageId && m.isDeleted ? { ...x, replyToBody: "" } : x)); };
      onChg = (e) => { if (e.conversationId === conv.conversationId) { load(); if (conv.groupId) api(`/groups/${conv.groupId}`).then((g) => setMyRole(g.group.myRole)).catch(() => onBack()); } };
      c.on("message", onMsg); c.on("messageUpdated", onUpd); c.on("chatChanged", onChg);
    }).catch(() => setLiveOk(false));
    // Fallback refresh every 20 s in case the live connection is unavailable (e.g. a proxy blocks WebSockets).
    const t = setInterval(load, 20000);
    return () => { off = true; clearInterval(t); connection?.off("message", onMsg); connection?.off("messageUpdated", onUpd); connection?.off("chatChanged", onChg); };
  }, [conv.conversationId]);
  useEffect(() => { end.current?.scrollIntoView({ block: "end" }); }, [messages.length]);
  function startReply(m) { setEditing(null); setReplyTo(m); input.current?.focus(); }
  function startEdit(m) { setReplyTo(null); setEditing(m); setBody(m.body); input.current?.focus(); }
  function cancel() { setReplyTo(null); if (editing) setBody(""); setEditing(null); }
  async function send(e) {
    e.preventDefault(); if (!body.trim()) return; setError("");
    const text = body, reply = replyTo, edit = editing; setBody(""); setReplyTo(null); setEditing(null);
    try {
      if (edit) upsert(await api(`/messages/${edit.messageId}`, "PUT", { body: text }));
      else upsert(await api(`/chats/${conv.conversationId}/messages`, "POST", { body: text, clientKey: crypto.randomUUID(), replyToId: reply?.messageId }));
    } catch (err) { setBody(text); setReplyTo(reply); setEditing(edit); setError(err.message); }
  }
  return (
    <section className="thread">
      <header className="thread-head"><button className="text-link" onClick={onBack} aria-label="Back to chats">←</button><h2>{conv.title || "Chat"}</h2>
        {conv.gameId && <a className="text-link" href={`#/events/${conv.gameId}`}>Open game</a>}
        {conv.groupId && <button className="text-link" onClick={() => onInfo(conv.groupId)}>Group info</button>}
        {!liveOk && <span className="pill warn">Refreshing every 20 s</span>}</header>
      <ol className="messages" aria-live="polite">
        {messages.length === 0 && <li className="muted">Say hi 👋</li>}
        {messages.map((m) => <Message key={m.messageId} m={m} me={me} myRole={myRole} onReply={startReply} onEdit={startEdit} onChanged={upsert} onError={setError} />)}
        <li ref={end} aria-hidden="true" className="scroll-anchor" />
      </ol>
      {(replyTo || editing) && <div className="composer-context">
        <span>{editing ? <><b>Editing message</b><small>{editing.body}</small></> : <><b>Replying to {replyTo.senderId === me ? "yourself" : replyTo.senderName}</b><small>{replyTo.body}</small></>}</span>
        <button className="text-link" onClick={cancel} aria-label="Cancel">✕</button></div>}
      <form className="composer" onSubmit={send}><input ref={input} aria-label="Message" maxLength={1000} value={body} onChange={(e) => setBody(e.target.value)} onKeyDown={(e) => e.key === "Escape" && cancel()} placeholder={editing ? "Edit your message" : "Write a message"} /><button className="primary" disabled={!body.trim()}>{editing ? "Save" : "Send"}</button></form>
      {error && <p className="alert" role="alert">{error}</p>}
    </section>
  );
}

export default function Chat({ user, lookups, shotsEnabled = true }) {
  const [tab, setTab] = useState("chats"), [list, setList] = useState(null), [open, setOpen] = useState(null), [info, setInfo] = useState(null), [v, setV] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/chats").then((l) => { setList(l); const pending = takePendingChat(); if (pending) { const c = l.find((x) => x.conversationId === pending); setOpen(c || { conversationId: pending, title: "Chat" }); } }).catch((e) => setError(e.message)); }, [v]);
  useEffect(() => { let c; const h = () => setV((n) => n + 1); live().then((x) => { c = x; x.on("message", h); x.on("chatChanged", h); }).catch(() => {}); return () => { c?.off("message", h); c?.off("chatChanged", h); }; }, []);
  async function openWith(spec) { try { const r = await api("/chats", "POST", spec); setTab("chats"); setOpen({ conversationId: r.conversationId, title: "" }); setV((x) => x + 1); } catch (e) { setError(e.message); } }
  if (info) return <GroupInfo groupId={info} me={user.userId} onBack={() => { setInfo(null); setV((x) => x + 1); }} onOpenChat={(c) => { setInfo(null); setOpen(c); }} onLeft={() => { setInfo(null); setOpen(null); setTab("groups"); setV((x) => x + 1); }} />;
  if (open) return <Thread conv={{ ...open, ...(list?.find((c) => c.conversationId === open.conversationId) || {}) }} me={user.userId} onInfo={(id) => setInfo(id)} onBack={() => { setOpen(null); setV((x) => x + 1); }} />;
  return (
    <section className="chat-page stack">
      <div className="section-heading"><div><span className="overline">PLAYERS · HOSTS · CLUBS</span><h1>Chat</h1></div></div>
      <div className="segmented tabs-scroll" role="tablist"><button role="tab" aria-selected={tab === "chats"} className={tab === "chats" ? "active" : ""} onClick={() => setTab("chats")}>Chats</button><button role="tab" aria-selected={tab === "groups"} className={tab === "groups" ? "active" : ""} onClick={() => setTab("groups")}>Groups</button><button role="tab" aria-selected={tab === "friends"} className={tab === "friends" ? "active" : ""} onClick={() => setTab("friends")}>Friends</button>{shotsEnabled && <button role="tab" aria-selected={tab === "shots"} className={tab === "shots" ? "active" : ""} onClick={() => setTab("shots")}>Shots</button>}</div>
      {error && <p className="alert" role="alert">{error}</p>}
      {tab === "shots" ? <Shots user={user} lookups={lookups} /> : tab === "groups" ? <Groups onOpen={(c) => setOpen(c)} onInfo={(id) => setInfo(id)} /> : tab === "friends" ? <Friends onOpen={openWith} /> : !list ? <p className="muted">Loading…</p> : list.length === 0 ? (
        <div className="panel"><h2>No chats yet</h2><p className="muted">Every game you join has a group chat. Message clubs from their court page, and friends from the Friends tab.</p></div>
      ) : <ul className="chat-list">{list.map((c) => <li key={c.conversationId}><button onClick={() => setOpen(c)}>
          <span className="chat-kind">{c.kind === "Game" ? "🏆" : c.kind === "Club" ? "🏟️" : c.kind === "Group" ? "👥" : "💬"}</span>
          <span className="chat-main"><strong>{c.title}</strong><small>{c.lastMessage || "No messages yet"}</small></span>
          {c.unread > 0 && <span className="badge" aria-label={`${c.unread} unread`}>{c.unread}</span>}
        </button></li>)}</ul>}
    </section>
  );
}
