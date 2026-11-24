import React, { useEffect, useState } from "react";
import { api } from "../api";

// Opens the link from the confirmation email (?verify=TOKEN). Works signed in or out; the token is the proof.
// Opening the link only shows a button: a person must click it. Mail security scanners (e.g. Microsoft Safe Links)
// open every link in an email automatically, and must not be able to confirm an address on the user's behalf.
export function VerifyLinkPrompt({ onDone }) {
  const [token, setToken] = useState(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const t = new URLSearchParams(location.search).get("verify");
    if (!t) return;
    setToken(t);
    history.replaceState({}, "", location.pathname + location.hash);
  }, []);
  if (!token) return null;
  async function confirm() {
    setBusy(true);
    try { const r = await api("/auth/verify-email", "POST", { token }); onDone(true, r.message); }
    catch (e) { onDone(false, e.message); }
    setToken(null);
  }
  return (
    <div className="verify-banner" role="dialog" aria-label="Confirm your email">
      <span><strong>Confirm your GameOn email</strong>: click the button to finish confirming your address.</span>
      <span className="button-row">
        <button className="small" onClick={confirm} disabled={busy}>{busy ? "Confirming…" : "Confirm my email"}</button>
        <button className="text-link" onClick={() => setToken(null)} disabled={busy}>Cancel</button>
      </span>
    </div>
  );
}

// Shown to signed-in players whose email is not confirmed yet. Booking, hosting and chat unlock after confirming.
export function VerifyBanner({ user, onRefresh }) {
  const [state, setState] = useState({ busy: false, msg: "", error: "" });
  if (!user || user.emailVerified !== false) return null;
  async function resend() {
    setState({ busy: true, msg: "", error: "" });
    try { const r = await api("/auth/resend-verification", "POST"); setState({ busy: false, msg: r.message, error: "" }); }
    catch (e) { setState({ busy: false, msg: "", error: e.message }); }
  }
  return (
    <div className="verify-banner" role="status">
      <span>
        <strong>Confirm your email</strong> — we sent a link to <b>{user.email}</b>. Booking, hosting and chat unlock once you open it.
        {state.msg && <em className="success"> {state.msg}</em>}{state.error && <em className="alert-inline"> {state.error}</em>}
      </span>
      <span className="button-row">
        <button className="secondary small" onClick={resend} disabled={state.busy}>{state.busy ? "Sending…" : "Resend link"}</button>
        <button className="text-link" onClick={onRefresh}>I've confirmed</button>
      </span>
    </div>
  );
}
