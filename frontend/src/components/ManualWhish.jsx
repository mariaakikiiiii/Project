import React, { useState } from "react";
import { api } from "../api";
export const paymentStatus = status => ({ AwaitingTransfer: "Transfer not submitted", AwaitingVerification: "Awaiting verification", VerifiedManual: "Transfer verified", Rejected: "Reference needs correction", RefundReview: "Refund review required", PendingCash: "Cash due at venue", MockSucceeded: "Demo verified — no money charged" }[status] || status);
export default function ManualWhish({ payment, onUpdate }) {
  const [reference, setReference] = useState(payment.transferReference || ""), [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function submit(e) {
    e.preventDefault(); setBusy(true); setError("");
    try { onUpdate(await api(`/payments/${payment.paymentId}/transfer`, "POST", { reference })); }
    catch (e) { setError(e.message); } finally { setBusy(false); }
  }
  const pending = ["AwaitingTransfer", "Rejected"].includes(payment.status);
  return <section className="manual-whish">
    <span className="pill">{paymentStatus(payment.status)}</span>
    {pending ? <>
      <h3>Your place is reserved. Transfer with Whish.</h3>
      <p>Send exactly <strong>{new Intl.NumberFormat("en-LB", {style:"currency", currency:payment.currency}).format(payment.totalAmount)}</strong> to:</p>
      <div className="transfer-number"><a href={`tel:${payment.recipientNumber}`}>{payment.recipientNumber}</a><button type="button" className="secondary" onClick={async () => { try { await navigator.clipboard.writeText(payment.recipientNumber); } catch { setError("Copy the number shown above manually."); } }}>Copy number</button></div>
      <p className="muted">Open your Whish app to make the transfer. Check the recipient in Whish before sending. This page never charges your account.</p>
      <form onSubmit={submit} className="stack"><label>Whish transfer reference<input required minLength={4} maxLength={100} value={reference} onChange={e => setReference(e.target.value)} autoComplete="off"/></label><button className="primary full" disabled={busy}>{busy ? "Submitting…" : "I transferred — submit reference"}</button></form>
    </> : <p>{payment.status === "AwaitingVerification" ? "Your reference was submitted. GameOn must check the Whish account before marking this payment verified. Do not send it again." : payment.status === "RefundReview" ? "Your booking was cancelled or needs reconciliation. Contact the payment operator; refunds are arranged manually, never automatically." : payment.status === "VerifiedManual" ? "A payment operator checked and verified this transfer." : "This transfer is no longer open."}</p>}
    {payment.reviewNote && <p className="payment-note">{payment.reviewNote}</p>}
    <p className="payment-reference">Booking reference: {payment.paymentId}</p>
    <p className="muted">You can return to this transfer under Payments. Never share your PIN, password, or one-time codes.</p>
    {error && <p className="alert" role="alert">{error}</p>}
  </section>;
}
