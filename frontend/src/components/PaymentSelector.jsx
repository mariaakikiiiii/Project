import React from "react";
export default function PaymentSelector({ value, onChange, disabled = false }) {
  return (
    <fieldset className="payment-selector" disabled={disabled}>
      <legend>How would you like to pay?</legend>
      <label className={`payment-choice ${value === "Cash" ? "chosen" : ""}`}>
        <input
          type="radio"
          name="paymentMethod"
          value="Cash"
          checked={value === "Cash"}
          onChange={() => onChange("Cash")}
        />
        <span>
          <strong>Cash at the venue</strong>
          <small>Pay the host in person. No online charge.</small>
        </span>
        <span aria-hidden="true">$</span>
      </label>
      <label className="payment-choice unavailable">
        <input type="radio" name="paymentMethod" value="Whish" disabled />
        <span>
          <strong>Whish Money</strong>
          <small>Online checkout is not connected yet.</small>
        </span>
        <span className="pill">Not connected</span>
      </label>
      <p className="muted">
        A reservation is not a payment receipt. No funds are collected through
        this screen.
      </p>
    </fieldset>
  );
}
