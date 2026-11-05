import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
import ManualWhish from "./ManualWhish";
const money = (amount, currency) =>
  new Intl.NumberFormat("en-LB", {
    style: "currency",
    currency,
    maximumFractionDigits: 2,
  }).format(amount);
export default function CheckoutModal({ game, config, onClose, onComplete }) {
  const dialog = useRef(),
    key = useRef(crypto.randomUUID());
  const [quote, setQuote] = useState(null),
    [method, setMethod] = useState("Cash"),
    [payment, setPayment] = useState(null),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    const element = dialog.current;
    element.showModal();
    const controller = new AbortController();
    api(`/games/${game.gameId}/quote`, "GET", undefined, {
      signal: controller.signal,
    })
      .then(setQuote)
      .catch((e) => {
        if (e.name !== "AbortError") setError(e.message);
      });
    return () => {
      controller.abort();
      element.close();
    };
  }, [game.gameId]);
  async function initialize() {
    setBusy(true);
    setError("");
    try {
      const result = await api(`/games/${game.gameId}/checkout`, "POST", {
        method,
        idempotencyKey: key.current,
        revision: quote.revision,
      });
      if (result.paymentId) setQuote(q => ({...q,amount:result.amount,serviceFee:result.serviceFee,totalAmount:result.totalAmount,currency:result.currency}));
      if (result.status === "MockSucceeded")
        onComplete("Demo payment already verified. No real money was charged.");
      else if (result.status === "MockPending") setPayment(result);
      else if (result.mode === "WhishManual") setPayment(result);
      else if (["PendingCash", "Joined", "Waitlisted"].includes(result.status))
        onComplete(
          result.status === "Waitlisted"
            ? "You are on the waitlist. No payment is due until a place opens."
            : "Your place is confirmed. Cash and service fee are due at the venue.",
        );
      else {
        setPayment(result);
        setError(
          "This checkout is no longer active. Close it and review the event again.",
        );
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  async function simulate() {
    setBusy(true);
    setError("");
    try {
      const result = await api(
        `/payments/${payment.paymentId}/mock-complete`,
        "POST",
      );
      setPayment(result);
      if (result.status === "MockSucceeded")
        onComplete(
          "Demo payment verified and place confirmed. No real money was charged.",
        );
      else
        setError(
          "The demo could not confirm a place. Nothing was charged. Close checkout and refresh the event.",
        );
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  const canReserve = quote?.isOpen && !quote.alreadyEnrolled;
  return (
    <dialog
      className="checkout-dialog"
      ref={dialog}
      aria-labelledby="checkout-heading"
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) onClose();
      }}
    >
      <button
        className="dialog-close"
        aria-label="Close checkout"
        onClick={onClose}
        disabled={busy}
      >
        ×
      </button>
      <span className="overline">YOUR PLACE. EVERY COST, UP FRONT.</span>
      <h2 id="checkout-heading">Review your booking</h2>
      <p className="muted">
        {game.sport} at {game.venue}
      </p>
      {!quote && !error && <p role="status">Getting your current price…</p>}
      {error && (
        <p className="alert" role="alert">
          {error}
        </p>
      )}
      {quote && (
        <>
          <dl className="fee-breakdown">
            <div>
              <dt>Base price</dt>
              <dd>{money(quote.amount, quote.currency)}</dd>
            </div>
            <div>
              <dt>Platform service fee (5%)</dt>
              <dd>{money(quote.serviceFee, quote.currency)}</dd>
            </div>
            <div className="total">
              <dt>Total amount</dt>
              <dd>{money(quote.totalAmount, quote.currency)}</dd>
            </div>
          </dl>
          {quote.alreadyEnrolled && (
            <p className="alert">
              You already have a place or waitlist entry. Close checkout and
              refresh your event.
            </p>
          )}
          {!quote.isOpen && (
            <p className="alert">This event is no longer open.</p>
          )}
          {quote.isFull && (
            <p className="payment-note">
              This event is full. You can join the waitlist without payment. The
              displayed total applies if you are promoted.
            </p>
          )}
          {!payment && (
            <fieldset
              className="payment-selector"
              disabled={busy || !canReserve}
            >
              <legend>Choose your payment method</legend>
              <label
                className={`payment-choice ${method === "Cash" ? "chosen" : ""}`}
              >
                <input
                  type="radio"
                  name="checkoutMethod"
                  checked={method === "Cash"}
                  onChange={() => setMethod("Cash")}
                />
                <span>
                  <strong>Cash at the venue</strong>
                  <small>
                    Reservation only. Settle the displayed total in person.
                  </small>
                </span>
              </label>
              <label
                className={`payment-choice ${method === "WhishMock" ? "chosen" : ""}`}
              >
                <input
                  type="radio"
                  name="checkoutMethod"
                  checked={method === "WhishMock"}
                  disabled={!config.mockPaymentsAvailable || quote.isFull}
                  onChange={() => setMethod("WhishMock")}
                />
                <span>
                  <strong>Whish Pay — demo</strong>
                  <small>
                    {config.mockPaymentsAvailable
                      ? "Simulated checkout. No real money is transferred."
                      : "Demo checkout is unavailable in this environment."}
                  </small>
                </span>
                <span className="pill">Mock</span>
              </label>
              {config.manualWhishAvailable && <label className={`payment-choice ${method === "WhishManual" ? "chosen" : ""}`}><input type="radio" name="checkoutMethod" checked={method === "WhishManual"} disabled={quote.isFull} onChange={() => setMethod("WhishManual")}/><span><strong>Whish Money transfer</strong><small>Reserve first, then send to {config.manualWhishRecipient}. Manually verified.</small></span></label>}
            </fieldset>
          )}
          {payment?.mode === "WhishMock" && (
            <div className="mock-payment-panel" role="status">
              <span className="pill">DEMO · NO REAL MONEY</span>
              <h3>
                {payment.status === "MockPending"
                  ? "Mock Whish checkout initialized"
                  : payment.status}
              </h3>
              <p>
                Your place is not held while this demo is pending. It will be
                checked again on confirmation.
              </p>
              <p className="payment-reference">
                Reference: {payment.paymentId}
              </p>
            </div>
          )}
          {payment?.mode === "WhishManual" && <ManualWhish payment={payment} onUpdate={setPayment}/>}
          {!payment ? (
            <button
              className="primary full"
              disabled={busy || !canReserve}
              onClick={initialize}
            >
              {busy
                ? "One moment…"
                : quote.isFull
                  ? "Join waitlist — no payment now"
                  : method === "WhishMock"
                    ? "Initialize mock Whish checkout"
                    : method === "WhishManual" ? "Reserve & show Whish instructions"
                    : "Confirm cash reservation"}
            </button>
          ) : payment.status === "MockPending" ? (
            <button className="primary full" disabled={busy} onClick={simulate}>
              {busy
                ? "Verifying demo…"
                : "Simulate Whish payment — no real charge"}
            </button>
          ) : null}
          <p className="checkout-footnote">
            The 5% fee is rounded to the nearest cent, with half cents rounded
            up. No currency conversion. Host-covered places are free and have no
            fee.
          </p>
        </>
      )}
    </dialog>
  );
}
