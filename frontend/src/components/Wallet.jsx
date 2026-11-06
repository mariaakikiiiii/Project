import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { money } from "./DepositCheckout";

const kindText = { TopUp: "Top-up from Whish", DepositPayment: "Game deposit", DepositRefund: "Deposit returned", Withdrawal: "Withdrawal to Whish", WithdrawalReversal: "Withdrawal returned" };
const quick = [5, 10, 20];

function TopUp({ config, pending, refresh }) {
  const key = useRef(crypto.randomUUID());
  const [amount, setAmount] = useState(10), [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function start(e) {
    e.preventDefault(); setBusy(true); setError("");
    try { await api("/me/wallet/top-ups", "POST", { idempotencyKey: key.current, amount: Number(amount) }); key.current = crypto.randomUUID(); refresh(); }
    catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <section className="panel wallet-card">
      <h2>Add money</h2>
      {pending.map((t) => <PendingTopUp key={`${t.topUpId}:${t.status}`} t={t} refresh={refresh} />)}
      <form className="stack" onSubmit={start}>
        <div className="chips" role="group" aria-label="Quick amounts">{quick.map((q) => <button type="button" key={q} className={Number(amount) === q ? "chip active" : "chip"} onClick={() => setAmount(q)}>${q}</button>)}</div>
        <label>Amount (USD)<input type="number" min="1" max="200" step="1" required value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <button className="primary full" disabled={busy || !config.walletAvailable}>{busy ? "One moment…" : `Top up ${money(Number(amount) || 0)} with Whish`}</button>
      </form>
      {!config.walletAvailable && <p className="alert">Top-ups are switched off right now.</p>}
      {error && <p className="alert" role="alert">{error}</p>}
    </section>
  );
}

function PendingTopUp({ t, refresh }) {
  const [reference, setReference] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function run(fn) { setBusy(true); setError(""); try { await fn(); refresh(); } catch (err) { setError(err.message); } finally { setBusy(false); } }
  if (t.status === "Submitted") return <div className="notice-card"><strong>{money(t.amount)} top-up is being checked</strong><p className="muted">Reference {t.transferReference}. It appears in your balance as soon as GameOn confirms it on the Whish statement.</p></div>;
  if (t.status === "Rejected") return <div className="notice-card warn"><strong>{money(t.amount)} top-up not confirmed</strong><p className="muted">{t.reviewNote}</p></div>;
  return (
    <div className="notice-card">
      <ol className="steps">
        <li>Open the <strong>Whish</strong> app and send <strong>{money(t.amount)}</strong> to <strong className="copyable">{t.recipientNumber}</strong> (GameOn).</li>
        <li>Copy the transaction reference Whish shows you.</li>
        <li>Paste it here. Your balance updates once GameOn sees the transfer.</li>
      </ol>
      <form className="picker-row" onSubmit={(e) => { e.preventDefault(); run(() => api(`/me/wallet/top-ups/${t.topUpId}/reference`, "POST", { reference })); }}>
        <input required minLength={4} maxLength={100} value={reference} placeholder="Whish reference" aria-label="Whish reference" onChange={(e) => setReference(e.target.value)} />
        <button className="primary" disabled={busy}>Submit</button>
      </form>
      <button type="button" className="text-link" disabled={busy} onClick={() => run(() => api(`/me/wallet/top-ups/${t.topUpId}`, "DELETE"))}>Cancel this top-up</button>
      <p className="muted small">Never share your Whish PIN or OTP. GameOn will never ask for it.</p>
      {error && <p className="alert" role="alert">{error}</p>}
    </div>
  );
}

function Withdraw({ balance, refresh }) {
  const key = useRef(crypto.randomUUID());
  const [amount, setAmount] = useState(""), [number, setNumber] = useState("+961"), [busy, setBusy] = useState(false), [error, setError] = useState(""), [done, setDone] = useState("");
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError(""); setDone("");
    try { await api("/me/wallet/withdrawals", "POST", { idempotencyKey: key.current, amount: Number(amount), whishNumber: number }); key.current = crypto.randomUUID(); setDone("Requested. GameOn sends it to your Whish and shows the reference here."); setAmount(""); refresh(); }
    catch (err) { setError(err.message); } finally { setBusy(false); }
  }
  return (
    <details className="panel wallet-card">
      <summary>Withdraw to Whish</summary>
      <form className="stack" onSubmit={submit}>
        <label>Amount (USD)<input type="number" min="1" max={balance} step="0.01" required value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <label>Your Whish number<input type="tel" required pattern="\+961[0-9]{7,8}" value={number} onChange={(e) => setNumber(e.target.value)} /></label>
        <button className="secondary full" disabled={busy || balance < 1}>{busy ? "Requesting…" : "Request withdrawal"}</button>
      </form>
      {done && <p className="success" role="status">{done}</p>}
      {error && <p className="alert" role="alert">{error}</p>}
    </details>
  );
}

function OperatorQueue() {
  const [data, setData] = useState(null), [version, setVersion] = useState(0), [error, setError] = useState("");
  useEffect(() => { api("/operator/wallet").then(setData).catch((e) => setError(e.message)); }, [version]);
  if (error) return <p className="alert">{error}</p>;
  if (!data) return null;
  return (
    <section className="stack">
      <h2>Operator: wallet</h2>
      <p className="payment-note">Check every item in the real GameOn Whish account before deciding. Money held for users: <strong>{money(data.totals.totalHeldForUsers)}</strong>{Number(data.totals.totalHeldForUsers) !== Number(data.totals.ledgerSum) && <strong className="danger-text">. Ledger mismatch: stop and investigate</strong>} · awaiting payout {money(data.totals.awaitingPayout)}</p>
      {data.topUps.length === 0 && data.withdrawals.length === 0 && <p className="muted">Nothing waiting.</p>}
      {data.topUps.map((t) => <Decision key={t.topUpId} title={`Top-up ${money(t.amount)} · ${t.displayName}`} detail={`Look for reference ${t.transferReference} received on ${t.recipientNumber}.`} path={`/operator/wallet/top-ups/${t.topUpId}`} options={[["VERIFY", "Money received: credit wallet"], ["REJECT", "Not found on statement"]]} done={() => setVersion((v) => v + 1)} />)}
      {data.withdrawals.map((w) => <Decision key={w.withdrawalId} title={`Withdrawal ${money(w.amount)} · ${w.displayName}`} detail={`Send ${money(w.amount)} from GameOn's Whish to ${w.whishNumber}, then record the reference.`} path={`/operator/wallet/withdrawals/${w.withdrawalId}`} needsReference options={[["SENT", "I sent it"], ["REJECT", "Cannot send: return to wallet"]]} done={() => setVersion((v) => v + 1)} />)}
    </section>
  );
}

function Decision({ title, detail, path, options, needsReference, done }) {
  const [decision, setDecision] = useState(options[0][0]), [note, setNote] = useState(""), [reference, setReference] = useState(""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function submit(e) { e.preventDefault(); setBusy(true); setError(""); try { await api(path, "POST", { decision, note, reference: reference || null }); done(); } catch (err) { setError(err.message); } finally { setBusy(false); } }
  return (
    <form className="panel stack" onSubmit={submit}>
      <h3>{title}</h3><p>{detail}</p>
      <label>Decision<select value={decision} onChange={(e) => setDecision(e.target.value)}>{options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
      {needsReference && decision === "SENT" && <label>Whish reference of the money you sent<input required minLength={4} maxLength={100} value={reference} onChange={(e) => setReference(e.target.value)} /></label>}
      <label>What you checked<input required minLength={4} maxLength={400} value={note} onChange={(e) => setNote(e.target.value)} /></label>
      <button className="primary" disabled={busy}>Save</button>
      {error && <p className="alert" role="alert">{error}</p>}
    </form>
  );
}

export default function Wallet({ config }) {
  const [data, setData] = useState(null), [version, setVersion] = useState(0), [error, setError] = useState("");
  const refresh = () => setVersion((v) => v + 1);
  useEffect(() => { const c = new AbortController(); api("/me/wallet", "GET", undefined, { signal: c.signal }).then(setData).catch((e) => { if (e.name !== "AbortError") setError(e.message); }); return () => c.abort(); }, [version]);
  if (error) return <p className="alert" role="alert">{error}</p>;
  if (!data) return <p className="muted" role="status">Loading your wallet…</p>;
  const s = data.summary;
  return (
    <section className="wallet-page">
      <div className="wallet-hero">
        <span className="overline">GAMEON WALLET</span>
        <p className="wallet-balance" aria-live="polite">{money(s.balance)}</p>
        <p className="muted">{Number(s.pendingTopUps) > 0 && `${money(s.pendingTopUps)} being checked · `}{Number(s.pendingWithdrawals) > 0 && `${money(s.pendingWithdrawals)} on its way to Whish · `}Join any game for $1. It comes back after you play.</p>
      </div>
      <div className="wallet-grid">
        <TopUp config={config} pending={data.topUps} refresh={refresh} />
        <section className="panel wallet-card">
          <h2>How it works</h2>
          <ol className="steps">
            <li><strong>Top up once</strong> with Whish. GameOn confirms the transfer, usually within the day.</li>
            <li><strong>Join a game for $1</strong>. Your place is confirmed instantly. Pay the venue share in cash on the day.</li>
            <li><strong>Play.</strong> When you and the host both confirm, your $1 returns to your wallet. If the host cancels, it returns straight away.</li>
            <li><strong>Withdraw</strong> any time to your own Whish number.</li>
          </ol>
          <p className="muted small">The $1 reserves your place in the GameOn game. The host books the court with the venue.</p>
        </section>
      </div>
      <Withdraw balance={Number(s.balance)} refresh={refresh} />
      {data.withdrawals.length > 0 && <section className="panel"><h2>Withdrawals</h2><ul className="ledger">{data.withdrawals.map((w) => <li key={w.withdrawalId}><span>{money(w.amount)} to {w.whishNumber}</span><span className={`pill ${w.status === "Sent" ? "ok" : w.status === "Rejected" ? "danger" : "warn"}`}>{w.status === "Requested" ? "Processing" : w.status}{w.sentReference ? ` · ${w.sentReference}` : ""}</span></li>)}</ul></section>}
      <section className="panel">
        <h2>Activity</h2>
        {data.entries.length === 0 ? <p className="muted">No activity yet. Top up to join your first game.</p> : (
          <ul className="ledger">{data.entries.map((e) => (
            <li key={e.entryId}><span><strong>{kindText[e.kind] || e.kind}</strong>{e.gameId ? <a href={`#/events/${e.gameId}`}> · game #{e.gameId}</a> : null}<small>{new Date(e.createdAt).toLocaleString()}</small></span>
              <span className={Number(e.amount) > 0 ? "amount plus" : "amount minus"}>{Number(e.amount) > 0 ? "+" : "−"}{money(Math.abs(e.amount))}</span></li>
          ))}</ul>
        )}
      </section>
      {s.canReview && <OperatorQueue />}
      <p className="muted small">GameOn's Whish number receives top-ups; balances are recorded in GameOn's ledger. Wallet limit USD 500.</p>
    </section>
  );
}
