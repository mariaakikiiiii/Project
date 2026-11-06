import React, { useEffect, useState } from "react";
import { api } from "../api";

const reasons = [
  ["HostNoShow", "The host or game did not show up"],
  ["FalseCompletion", "The host reported the game wrongly"],
  ["HostCancelled", "The game was cancelled but I was not refunded"],
  ["RefundNotReceived", "My refund was recorded but never arrived"],
  ["Other", "Something else"],
];
const depositText = {
  PENDING: "Waiting for GameOn to verify your transfer",
  PAID_HELD: "$1 held until attendance is confirmed",
  REFUND_PENDING: "Refund owed. An operator will send it",
  REFUNDED: "Refunded",
  DISPUTED: "Frozen while a dispute is reviewed",
  REJECTED: "Transfer could not be verified",
};

function HostReport({ id, roster, hostId, onDone }) {
  const players = roster.filter((p) => p.userId !== hostId);
  const [outcome, setOutcome] = useState("Played");
  const [marks, setMarks] = useState(() => Object.fromEntries(players.map((p) => [p.userId, "Attended"])));
  const [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError("");
    try {
      const r = await api(`/games/${id}/completion`, "POST", {
        outcome, marks: outcome === "Played" ? players.map((p) => ({ userId: p.userId, mark: marks[p.userId] })) : [],
      });
      onDone(r.message);
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <form className="panel stack" onSubmit={submit}>
      <h3>Report how the game went</h3>
      <p className="muted">Each player also confirms. A $1 deposit is queued for refund only when your report and theirs agree; disagreements go to GameOn for review. You can report once.</p>
      <fieldset><legend>Did the game take place?</legend>
        <label className="checkbox"><input type="radio" name="outcome" checked={outcome === "Played"} onChange={() => setOutcome("Played")} />Yes, we played</label>
        <label className="checkbox"><input type="radio" name="outcome" checked={outcome === "DidNotTakePlace"} onChange={() => setOutcome("DidNotTakePlace")} />No, it did not happen (all deposits are refunded)</label>
      </fieldset>
      {outcome === "Played" && players.map((p) => (
        <label key={p.userId}>{p.displayName}
          <select value={marks[p.userId]} onChange={(e) => setMarks({ ...marks, [p.userId]: e.target.value })}>
            <option value="Attended">Attended</option><option value="NoShow">Did not show up</option>
          </select>
        </label>
      ))}
      {outcome === "Played" && players.length === 0 && <p className="muted">No other players are on the roster.</p>}
      <button className="primary" disabled={busy}>{busy ? "Saving…" : "Submit report"}</button>
      {error && <p className="alert" role="alert">{error}</p>}
    </form>
  );
}

function DisputeForm({ id, onDone }) {
  const [reason, setReason] = useState("HostNoShow"), [details, setDetails] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError("");
    try { const r = await api(`/games/${id}/disputes`, "POST", { reason, details }); onDone(r.message); }
    catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <form className="panel stack" onSubmit={submit}>
      <h3>Report a problem</h3>
      <label>What happened?<select value={reason} onChange={(e) => setReason(e.target.value)}>{reasons.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
      <label>Details<textarea required minLength={10} maxLength={800} value={details} onChange={(e) => setDetails(e.target.value)} placeholder="Dates, what you saw, any Whish reference…" /></label>
      <p className="muted">Your deposit is frozen (not paid to anyone) until a GameOn operator who is not part of this game reviews it.</p>
      <button className="secondary" disabled={busy}>{busy ? "Sending…" : "Open dispute"}</button>
      {error && <p className="alert" role="alert">{error}</p>}
    </form>
  );
}

export default function GameTrust({ id, user, game, roster, notify }) {
  const [data, setData] = useState(null), [version, setVersion] = useState(0), [disputing, setDisputing] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState("");
  useEffect(() => {
    const c = new AbortController();
    api(`/games/${id}/trust`, "GET", undefined, { signal: c.signal }).then(setData).catch((e) => { if (e.name !== "AbortError") setError(e.message); });
    return () => c.abort();
  }, [id, version, user?.userId]);
  if (error) return <p className="alert" role="alert">{error}</p>;
  if (!data) return null;
  const t = data.trust, host = user?.userId === game.hostUserId, member = roster.some((p) => p.userId === user?.userId);
  const done = (message) => { notify(message); setDisputing(false); setVersion((v) => v + 1); };
  async function confirm(mark) {
    setBusy(true); setError("");
    try { const r = await api(`/games/${id}/attendance`, "POST", { mark }); done(r.message); }
    catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  const listing = t.listingStatus === "Verified" ? "Venue listing checked against an official source" : t.listingStatus === "Demo" ? "Demo venue (not real)" : "Venue not yet checked by GameOn";
  return (
    <section className="panel trust" aria-label="Trust and what happens next">
      <span className="overline">BEFORE YOU JOIN</span>
      <h2>Host & venue</h2>
      {t.hostUnderReview && <p className="alert" role="alert">This host is under review. GameOn is not accepting new deposits for their games.</p>}
      <ul className="trust-facts">
        <li>Host on GameOn since {new Date(t.hostSince).toLocaleDateString()}</li>
        <li>{t.hostedCount} game{t.hostedCount === 1 ? "" : "s"} hosted · {t.completedCount} reported played · {t.cancelledCount} cancelled</li>
        <li className={t.listingStatus === "Verified" ? "ok" : "warn"}>{listing}</li>
        <li className={t.contactVerified ? "ok" : "warn"}>{t.contactVerified ? "Venue phone confirmed by GameOn" : "Venue phone not confirmed by GameOn"}</li>
        <li className="warn">GameOn cannot confirm the host has reserved the court. Ask the host, or call the venue.</li>
      </ul>
      <details><summary>How the $1 deposit works</summary>
        <ol className="muted">
          <li>You send the amount due to GameOn's Whish number and enter the transfer reference.</li>
          <li>A GameOn operator checks the Whish statement. Your place is confirmed only then.</li>
          <li>If the host cancels, or after you attend and the host's report matches yours, your $1 is refunded.</li>
          <li>Refunds show as Refunded only after the operator sends them and records the Whish reference.</li>
          <li>If you leave early or don't show up, no automatic decision is made. GameOn reviews it.</li>
        </ol>
      </details>
      {t.myDepositStatus && <p><strong>Your deposit:</strong> {depositText[t.myDepositStatus] || t.myDepositStatus}</p>}
      {t.reportingOpen && host && !t.completionOutcome && <HostReport id={id} roster={roster} hostId={game.hostUserId} onDone={done} />}
      {t.completionOutcome && <p className="muted">Host report: {t.completionOutcome === "Played" ? "game played" : "game did not take place"}.</p>}
      {t.reportingOpen && member && !host && !t.playerMark && (
        <div className="stack">
          <h3>Did you play?</h3>
          <div className="button-row">
            <button className="primary" disabled={busy} onClick={() => confirm("Attended")}>I played</button>
            <button className="secondary" disabled={busy} onClick={() => confirm("NotPlayed")}>The game did not happen</button>
          </div>
        </div>
      )}
      {t.playerMark && <p className="muted">You confirmed: {t.playerMark === "Attended" ? "you played" : "the game did not happen"}.</p>}
      {user && (member || t.myDepositStatus) && !host && (disputing
        ? <DisputeForm id={id} onDone={done} />
        : <button className="text-link" onClick={() => setDisputing(true)}>Report a problem with this game or refund</button>)}
    </section>
  );
}
