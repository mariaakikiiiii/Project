import React, { useRef, useState } from "react";
import { api } from "../api";
import { localInput } from "../domain";
import CategoryTabs from "./CategoryTabs";
import VenueMap from "./VenueMap";
export default function EventWizard({ lookups, existing, onSaved, onBack, config = {} }) {
  const [customLocation, setCustomLocation] = useState(null), [useMap, setUseMap] = useState(false);
  const [finderOpen, setFinderOpen] = useState(false);
  const initialType = lookups.sports.find(
    (t) => t.sportId === existing?.sportId,
  );
  const [step, setStep] = useState(existing ? 1 : 0),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const [form, setForm] = useState({
    category: initialType?.categorySlug || "sports",
    sportId: existing?.sportId || "",
    venueId: existing?.venueId || "",
    start: existing ? localInput(existing.startsAt) : "",
    capacity: existing?.capacity || 10,
    price: existing?.costPerPlayer ?? 0,
    currency: existing?.currency || "USD",
    sponsored: existing?.sponsoredSlots || 0,
    description: existing?.description || "",
  });
  const formRef = useRef();
  const types = lookups.sports.filter((t) => t.categorySlug === form.category);
  const subtype = lookups.sports.find(
    (t) => t.sportId === Number(form.sportId),
  );
  const venue = lookups.venues.find((v) => v.venueId === Number(form.venueId));
  const change = (key, value) => setForm((f) => ({ ...f, [key]: value }));
  function nextStep() {
    if (!formRef.current.reportValidity()) return;
    if (step === 0 && !subtype) {
      setError("Choose a sport or activity first.");
      return;
    }
    if (step === 1 && useMap && !customLocation?.name?.trim()) {
      setError("Choose a map pin and enter its location name before continuing.");
      return;
    }
    setError("");
    setStep((s) => s + 1);
  }
  async function submit(e) {
    e.preventDefault();
    if (step < 2) return nextStep();
    setBusy(true);
    setError("");
    try {
      const body = {
        sportId: Number(form.sportId),
        venueId: Number(form.venueId),
        startsAt: new Date(form.start).toISOString(),
        capacity: Number(form.capacity),
        description: form.description,
        costPerPlayer: Number(form.price),
        currency: form.currency,
        sponsoredSlots: Number(form.sponsored),
        revision: existing?.revision,
        location: useMap ? customLocation : null,
      };
      if (useMap && !customLocation?.name?.trim()) throw new Error("Choose a map location and give it a name.");
      const result = await api(
        existing ? `/games/${existing.gameId}` : "/games",
        existing ? "PUT" : "POST",
        body,
      );
      onSaved(existing ? existing.gameId : result.gameId);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="form-page wizard">
      <button className="text-link" onClick={onBack}>
        ← Back to your plans
      </button>
      <span className="overline">HOST SOMETHING WORTH SHOWING UP FOR</span>
      <h1>
        {existing ? "Edit your event" : "Host an event"}
      </h1>
      <p className="lead">
        Choose an activity, a place and a time. You are included in the player count.
      </p>
      <ol className="wizard-steps" aria-label="Event creation progress">
        {["Activity", "Time & place", "Price & publish"].map(
          (label, index) => (
            <li
              key={label}
              className={
                step === index ? "current" : step > index ? "complete" : ""
              }
              aria-current={step === index ? "step" : undefined}
            >
              <span>{step > index ? "✓" : index + 1}</span>
              {label}
            </li>
          ),
        )}
      </ol>
      <form ref={formRef} className="panel form-grid" onSubmit={submit}>
        {step === 0 && (
          <>
            <div className="form-wide">
              <h2>What brings everyone together?</h2>
              <CategoryTabs
                includeAll={false}
                value={form.category}
                onChange={(category) =>
                  setForm((f) => ({ ...f, category, sportId: "" }))
                }
              />
              <p className="muted">
                {form.category === "sports"
                  ? "9 sports. From your first rally to your weekly match."
                  : "8 ways to break the routine. Choose your next adventure."}
              </p>
            </div>
            <label className="form-wide">
              Sport or activity type
              <select
                required
                name="sport"
                value={form.sportId}
                onChange={(e) => change("sportId", e.target.value)}
              >
                <option value="">Choose an experience</option>
                {types.map((t) => (
                  <option key={t.sportId} value={t.sportId}>
                    {t.name}
                  </option>
                ))}
              </select>
            </label>
            <div className={`experience-preview form-wide ${form.category}`}>
              <span className="overline">
                {form.category === "sports"
                  ? "GET IN THE GAME"
                  : "MAKE A MEMORY"}
              </span>
              <h3>
                {subtype?.name ||
                  (form.category === "sports"
                    ? "A good game changes your whole day."
                    : "The group chat deserves a better plan.")}
              </h3>
              <p>
                {form.category === "sports"
                  ? "Find teammates, build a regular crew, and make every spot count."
                  : "Assemble your team for a new challenge. A little competition. A lot of stories."}
              </p>
            </div>
          </>
        )}
        {step === 1 && (
          <>
            <div className="form-wide">
              <span className="pill">{subtype?.name || existing?.sport}</span>
              <h2>Set the time. Save the places.</h2>
            </div>
            <label>
              Date & time (your local time)
              <input
                required
                type="datetime-local"
                name="start"
                value={form.start}
                onChange={(e) => change("start", e.target.value)}
              />
            </label>
            <label>
              Total places, including you
              <input
                required
                type="number"
                name="capacity"
                min="2"
                max="100"
                value={form.capacity}
                onChange={(e) => change("capacity", e.target.value)}
              />
            </label>
            <label className="form-wide">
              Venue
              <select
                aria-label="Venue"
                required={!useMap}
                name="venue"
                value={form.venueId}
                disabled={!!existing || useMap}
                onChange={(e) => change("venueId", e.target.value)}
              >
                <option value="">Choose a venue</option>
                {lookups.venues.map((v) => (
                  <option key={v.venueId} value={v.venueId}>
                    {v.name} · {v.area}
                  </option>
                ))}
              </select>
              {existing && (
                <small>The existing venue is retained when editing.</small>
              )}
            </label>
            {!existing && <div className="form-wide">
              {config.mapsPickerAvailable && <label className="checkbox"><input type="checkbox" checked={useMap} onChange={e => setUseMap(e.target.checked)}/>Choose my own location on Google Maps</label>}
              <details open={useMap || finderOpen} onToggle={e => setFinderOpen(e.currentTarget.open)}><summary>Find {subtype?.name || "activity"} venues in Lebanon</summary>{(useMap || finderOpen) && <VenueMap config={config} type={subtype?.name} onSelect={useMap ? setCustomLocation : undefined} value={useMap ? customLocation : null}/>}</details>
            </div>}
            <p className="muted form-wide">
              You are included in the capacity. Venue availability must be
              confirmed with the operator before publishing.
            </p>
          </>
        )}
        {step === 2 && (
          <>
            <div className="form-wide">
              <h2>Make the invitation yours.</h2>
              <div className="review-summary">
                <span className="pill">
                  {form.category === "sports" ? "Sports" : "Activities"}
                </span>
                <strong>{subtype?.name}</strong>
                <span>
                  {useMap ? customLocation?.name : venue?.name} · {new Date(form.start).toLocaleString()}
                </span>
                <span>{form.capacity} total places</span>
              </div>
            </div>
            <label>
              Venue share per person
              <input
                required
                type="number"
                min="0"
                max="99999999.99"
                step="0.01"
                value={form.price}
                onChange={(e) => change("price", e.target.value)}
              />
            </label>
            <label>
              Currency
              <select
                value={form.currency}
                onChange={(e) => change("currency", e.target.value)}
              >
                <option>USD</option>
                {existing && <option>LBP</option>}
              </select>
            </label>
            <div className="offer form-wide">
              <span>✦ ONE MORE MAKES IT HAPPEN</span>
              <h3>Cover a place. Complete the crew.</h3>
              <p>
                Offer a place at no cost to another person. You agree to pay
                their venue share directly; no money is transferred by the app.
              </p>
              <label>
                Host-covered places
                <input
                  required
                  type="number"
                  min="0"
                  max={Math.max(0, Number(form.capacity) - 1)}
                  value={form.sponsored}
                  onChange={(e) => change("sponsored", e.target.value)}
                />
              </label>
            </div>
            <label className="form-wide">
              Set the vibe
              <textarea
                maxLength="1000"
                rows="4"
                value={form.description}
                onChange={(e) => change("description", e.target.value)}
                placeholder="Skill level, what to bring, safety requirements, and where to meet…"
              />
            </label>
            <div className="form-wide payment-note">
              <strong>Clear prices. No surprises.</strong>
              <p>
                New events require a $1 commitment deposit and a 5% service fee on the game share,
                shown to players at checkout. Free and host-covered places have
                no platform fee on the covered share; the $1 deposit still applies to new events. Manual Whish
                transfers, when enabled, are sent to GameOn and require verification.
              </p>
            </div>
          </>
        )}
        <div className="form-wide">
          <p className="alert" role="alert" hidden={!error}>
            {error}
          </p>
          <div className="wizard-actions">
            {step > (existing ? 1 : 0) && (
              <button
                type="button"
                className="secondary"
                disabled={busy}
                onClick={() => {
                  setError("");
                  setStep((s) => s - 1);
                }}
              >
                ← Previous
              </button>
            )}
            <button className="primary" disabled={busy}>
              {busy
                ? "Saving…"
                : step < 2
                  ? "Continue →"
                  : existing
                    ? "Save & notify the crew"
                    : "Publish event →"}
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}
