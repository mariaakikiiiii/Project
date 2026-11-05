import React, { useEffect, useState } from "react";
import { api } from "../api";
import ManualWhish, { paymentStatus } from "./ManualWhish";
function ReviewItem({ payment, onReviewed }) {
  const [note, setNote] = useState(""), [decision, setDecision] = useState("VerifiedManual"), [error, setError] = useState(""), [busy, setBusy] = useState(false);
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError("");
    try { await api(`/payments/${payment.paymentId}/review`, "POST", { decision, note }); onReviewed(); }
    catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  return <form className="panel stack" onSubmit={submit}><h3>{payment.displayName} · {payment.currency} {payment.totalAmount}</h3><p>Status: {paymentStatus(payment.status)}<br/>Reference: {payment.transferReference || "Not submitted"}<br/>Recipient: {payment.recipientNumber}</p>
    <p className="payment-note">Check the actual Whish statement, amount, currency, recipient and reference before verifying. A submitted reference alone is not proof of payment.</p>
    <label>Decision<select value={decision} onChange={e => setDecision(e.target.value)}><option value="VerifiedManual" disabled={payment.status === "RefundReview"}>Verified against Whish statement</option><option value="Rejected">Reference rejected</option><option value="RefundReview">Needs refund review</option></select></label>
    <label>Reconciliation note<textarea required minLength={4} maxLength={400} value={note} onChange={e => setNote(e.target.value)}/></label>
    <button className="primary" disabled={busy}>{busy ? "Saving…" : "Save review"}</button>{error && <p role="alert" className="alert">{error}</p>}
  </form>;
}
export default function PaymentHistory() {
  const [data, setData] = useState(null), [reviews, setReviews] = useState([]), [error, setError] = useState(""), [version, setVersion] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    api("/me/payments", "GET", undefined, {signal:controller.signal}).then(async result => {
      setData(result);
      if (result.canReview) setReviews(await api("/payments/reviews", "GET", undefined, {signal:controller.signal}));
    }).catch(e => { if (e.name !== "AbortError") setError(e.message); });
    return () => controller.abort();
  }, [version]);
  return <div className="payment-history"><h2>Your bookings & payments</h2>
    <p className="muted">Whish transfers are checked manually. Refresh to see the latest review.</p>
    <button className="secondary" onClick={() => {setError(""); setVersion(v => v + 1);}}>Refresh payment status</button>
    {error && <p className="alert" role="alert">{error}</p>}
    {!data && !error && <p role="status">Loading payments…</p>}
    {data?.payments.length === 0 && <p>No paid bookings yet.</p>}
    {data?.payments.map(p => <details className="panel payment-record" key={p.paymentId}><summary>{p.sport} at {p.venue} · {p.currency} {p.totalAmount} · {paymentStatus(p.status)}</summary>{p.mode === "WhishManual" ? <ManualWhish key={`${p.paymentId}:${p.status}`} payment={p} onUpdate={updated => setData(d => ({...d, payments: d.payments.map(row => row.paymentId === updated.paymentId ? {...row,...updated} : row)}))}/> : <p className="muted">{p.mode === "Cash" ? "Settle the booking total in person with the host." : "Demo payment: no real funds were transferred."}</p>}</details>)}
    {data?.canReview && <section><h2>Whish transfer reviews</h2>{reviews.length === 0 && <p>No pending reviews.</p>}{reviews.map(p => <ReviewItem key={p.paymentId} payment={p} onReviewed={() => setVersion(v => v + 1)}/>)}</section>}
  </div>;
}
