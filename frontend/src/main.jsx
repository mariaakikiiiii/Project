import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { api, refreshCsrf } from "./api";
import {
  dateOf,
  localInput,
  price,
  availableCovered,
  playable,
  mapQuery,
} from "./domain";
import {protectedPages, pageLabels, routeHref, readRoute} from "./navigation";
import "./style.css";
import "./theme.css";
import DepositCheckout from "./components/DepositCheckout";
import VenueContactCard from "./components/VenueContactCard";
import DepositHistory from "./components/DepositHistory";
import CheckoutModal from "./components/CheckoutModal";
import SponsoredVenues from "./components/SponsoredVenues";
import VenueMap from "./components/VenueMap";
import PaymentHistory from "./components/PaymentHistory";
import CategoryTabs from "./components/CategoryTabs";
import GameForm from "./components/EventWizard";
import SportsPicker,{genderOptions,todayInput} from "./components/SportsPicker";
import VenueDirectory from "./components/VenueDirectory";
import GameTrust from "./components/GameTrust";

function Mark({ name }) {
  const paths = {
    arrow: "M7 17 17 7M7 7h10v10",
    pin: "M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0ZM15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
    payments: "M3 7h18v14H3zM3 7V4h15v3M16 12h5v5h-5z",
    back: "M19 12H5m6-6-6 6 6 6",
    check: "m5 12 4 4L19 6",
    discover: "m3 11 9-8 9 8v10h-6v-6H9v6H3Z",
    games: "M3 5h18v16H3zM7 2v6m10-6v6M3 11h18",
    inbox: "M18 8a6 6 0 0 0-12 0c0 8-3 8-3 10h18c0-2-3-2-3-10M10 21h4",
    profile: "M20 21a8 8 0 0 0-16 0M16 6a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
    host: "M12 5v14M5 12h14",
    venues: "M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0ZM15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
  };
  return (
    <svg
      aria-hidden="true"
      className="icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d={paths[name] || paths.pin} />
    </svg>
  );
}
function Alert({ children }) {
  return children ? (
    <p className="alert" role="alert">
      {children}
    </p>
  ) : null;
}
function Empty({ title, children, action }) {
  return (
    <div className="empty">
      <span aria-hidden="true">◌</span>
      <h3>{title}</h3>
      <p>{children}</p>
      {action}
    </div>
  );
}
function Loading() {
  return (
    <div role="status" className="loading">
      <span className="spinner" /> Finding your next good game…
    </div>
  );
}
function useResource(path, dependency = 0) {
  const [state, setState] = useState({ data: null, error: "", loading: true });
  useEffect(() => {
    const controller = new AbortController();
    setState({ data: null, error: "", loading: true });
    api(path, "GET", undefined, { signal: controller.signal })
      .then((data) => setState({ data, error: "", loading: false }))
      .catch((error) => {
        if (error.name !== "AbortError")
          setState({ data: null, error: error.message, loading: false });
      });
    return () => controller.abort();
  }, [path, dependency]);
  return state;
}
function Court({ sport, large = false }) {
  return (
    <div
      aria-hidden="true"
      className={`court ${sport?.startsWith("Football") ? "football" : sport?.includes("Tennis") || ["Padel", "Badminton", "Squash"].includes(sport) ? "padel" : sport === "Swimming" ? "swimming" : ["Paintball", "Airsoft", "Archery Tag"].includes(sport) ? "tactical" : sport?.includes("Laser") || sport?.includes("iCombat") ? "laser" : sport === "Escape Rooms" ? "escape" : sport === "Go-Karting" ? "karting" : sport === "Bowling" ? "bowling" : "basketball"} ${large ? "large" : ""}`}
    >
      <div className="court-lines">
        <i />
        <b />
        <em />
      </div>
      <span>
        {sport?.startsWith("Football")
          ? "90 MINUTES. NEW FRIENDS."
          : sport === "Padel"
            ? "GOOD RALLIES. BETTER COMPANY."
            : "YOUR NEXT CREW IS HERE."}
      </span>
    </div>
  );
}
function GameCard({ game: g, select, user }) {
  const covered = availableCovered(g);
  return (
    <article className={`game-card ${g.gameStatus === "Cancelled" ? "is-cancelled" : g.playerCount>=g.capacity ? "is-full" : ""}`}>
      <button
        className="card-art"
        aria-label={`View ${g.sport} at ${g.venue}`}
        onClick={() => select(g.gameId)}
      >
        <Court sport={g.sport} />
        <span className="sport-tag">{g.sport}</span>
        {covered > 0 && (
          <span className="covered-tag">
            Host covers {covered} {covered === 1 ? "place" : "places"}
          </span>
        )}
      </button>
      <div className="card-content">
        <div className="eyebrow">
          {dateOf(g.startsAt).toLocaleDateString(undefined, {
            weekday: "short",
            month: "short",
            day: "numeric",
          })}{" "}
          ·{" "}
          {dateOf(g.startsAt).toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
          })}
        </div>
        <h3>
          <button className="text-button" onClick={() => select(g.gameId)}>
            {g.sport} at {g.venue}
          </button>
        </h3>
        <p className="muted">
          <Mark name="pin" />
          {g.area}, Lebanon
        </p>
        {(g.matchesSport || g.matchesArea) && (
          <p className="match">
            ✦{" "}
            {g.matchesSport && g.matchesArea
              ? "Your experience. Your neighborhood."
              : g.matchesSport
                ? "Matches your favorites"
                : "In your preferred area"}
          </p>
        )}
        <div className="card-meta">
          <span>
            <strong>{g.playerCount}</strong> / {g.capacity} players
          </span>
          <strong>{g.isSponsored ? "Host-covered · Free" : price(g)}</strong>
        </div>
        <div
          className="capacity"
          aria-label={`${g.playerCount} of ${g.capacity} places filled`}
        >
          <span
            style={{
              width: `${Math.min(100, (g.playerCount / g.capacity) * 100)}%`,
            }}
          />
        </div>
        <div className="card-bottom">
          <span
            className={`pill ${g.gameStatus === "Cancelled" || g.playerCount >= g.capacity ? "danger" : "availability"}`}
          >
            {g.gameStatus === "Cancelled"
              ? "Cancelled"
              : g.status === "Waitlisted"
                ? `Waitlist #${g.queuePosition}`
                : (g.status === "Joined" ? "Confirmed" : g.status) ||
                  (g.capacity === g.playerCount
                    ? "FULL — Join Waitlist"
                    : `${g.capacity - g.playerCount} spots left`)}
          </span>
          {user?.userId === g.hostUserId && (
            <span className="host-label">You host</span>
          )}
          {g.isSponsored && <span className="pill">Fee covered</span>}

        </div>
      </div>
          <button className="card-view" onClick={()=>select(g.gameId)} aria-label={`Open ${g.sport} at ${g.venue}`}>View game & join <Mark name="arrow"/></button>
    </article>
  );
}
function Feed({ lookups, user, select, navigate, revision, config }) {
  const [venueFinderOpen, setVenueFinderOpen] = useState(false);
  const [moreFilters, setMoreFilters] = useState(false);
  const [filters, setFilters] = useState({
    sportId: "",
    category: "",
    openOnly: false,
    area: "",
    date: "",
    freeOnly: false,
  });
  const [query, setQuery] = useState("");
  const { data, error, loading } = useResource("/games?" + query, revision);
  function search(event) {
    event?.preventDefault();
    setQuery(
      new URLSearchParams(
        Object.entries(filters).filter(([, v]) => v !== "" && v !== false),
      ).toString(),
    );
  }
  function sport(id) {
    const next = { ...filters, sportId: String(id) };
    setFilters(next);
    setQuery(
      new URLSearchParams(
        Object.entries(next).filter(([, v]) => v !== "" && v !== false),
      ).toString(),
    );
  }
  function category(slug) {
    const next = { ...filters, category: slug, sportId: "" };
    setFilters(next);
    setQuery(
      new URLSearchParams(
        Object.entries(next).filter(([, v]) => v !== "" && v !== false),
      ).toString(),
    );
  }
  const visibleTypes = lookups.sports.filter(
    (t) => !filters.category || t.categorySlug === filters.category,
  );
  function exploreSponsored(area) {
    const next = { ...filters, area };
    setFilters(next);
    setQuery(
      new URLSearchParams(
        Object.entries(next).filter(([, v]) => v !== "" && v !== false),
      ).toString(),
    );
    document
      .getElementById("discover-filters")
      ?.scrollIntoView({ behavior: "smooth" });
  }
  return (
    <>
      <section className="hero discovery-intro">
        <div className="hero-copy">
          <span className="overline"><span className="live-dot" /> SPORTS & ACTIVITIES · LEBANON</span>
          <h1>{user ? <>Your next game, <em>{user.name.split(" ")[0]}.</em></> : <>Find your <em>next game.</em></>}</h1>
          <p>Pick a sport. Find a place. Meet your crew.</p>
        </div>
        <div className="hero-sports-art" aria-hidden="true"><svg viewBox="0 0 260 220"><defs><linearGradient id="racket-accent" x2="1" y2="1"><stop stopColor="#ff3818"/><stop offset="1" stopColor="#ffc85c"/></linearGradient></defs><g transform="rotate(25 130 110)"><ellipse cx="130" cy="75" rx="53" ry="67" fill="#1a2628" stroke="url(#racket-accent)" strokeWidth="9"/><path d="M100 25v100m20-112v124m20-124v124m20-112v100M80 50h100M78 75h104M82 100h96" stroke="#d5e2d1" strokeWidth="2" opacity=".65"/><path d="m113 139 8 31h18l8-31M130 170v45" fill="none" stroke="url(#racket-accent)" strokeWidth="14" strokeLinecap="round"/></g><circle cx="51" cy="155" r="25" fill="#beed4c"/><path d="M32 140q28 9 30 36" fill="none" stroke="#edf9af" strokeWidth="3"/></svg></div>
      </section>
      <div className="home-shortcuts" aria-label="Quick actions">
        <button onClick={()=>document.getElementById("discover-filters")?.scrollIntoView({behavior:"smooth"})}><Mark name="games"/><span>Public games</span></button>
        <button onClick={()=>navigate("venues")}><Mark name="venues"/><span>Find a court</span></button>
        <button onClick={()=>navigate(user?"mine":"signup")}><Mark name="profile"/><span>{user?"My games":"Join the community"}</span></button>
        <button onClick={()=>navigate(user?"host":"auth")}><Mark name={user?"host":"profile"}/><span>{user?"Host a game":"Sign in"}</span></button>
      </div>
      <SponsoredVenues onExplore={exploreSponsored} />
      <div className="section-heading">
        <div>
          <span className="overline">GET OUT. GET IN THE GAME.</span>
          <h2>Public games</h2>
        </div>
        {user ? (
          <button className="text-link" onClick={() => navigate("profile")}>
            Tune your preferences ↗
          </button>
        ) : (
          <span className="muted">
            Sign in for a feed that knows your game.
          </span>
        )}
      </div>
      <CategoryTabs value={filters.category} onChange={category} />
      <form id="discover-filters" className="filter-bar" onSubmit={search}>
        <label>
          Sport or activity
          <select aria-label="Sport or activity" value={filters.sportId} onChange={e=>sport(e.target.value)}>
            <option value="">All types</option>
            {visibleTypes.map(t=><option key={t.sportId} value={t.sportId}>{t.name}</option>)}
          </select>
        </label>
        <button type="button" className="secondary filter-toggle" aria-expanded={moreFilters} aria-controls="extra-discovery-filters" onClick={()=>setMoreFilters(v=>!v)}>Filters{[filters.area,filters.date,filters.freeOnly,filters.openOnly].filter(Boolean).length ? ` (${[filters.area,filters.date,filters.freeOnly,filters.openOnly].filter(Boolean).length})` : ""}</button>
        <div id="extra-discovery-filters" className="filter-extra" data-expanded={moreFilters}>
        <label>
          Neighborhood
          <select
            aria-label="Neighborhood"
            value={filters.area}
            onChange={(e) => setFilters({ ...filters, area: e.target.value })}
          >
            <option value="">Anywhere in Lebanon</option>
            {[...new Set(lookups.venues.map((v) => v.area))].map((a) => (
              <option key={a}>{a}</option>
            ))}
          </select>
        </label>
        <label>
          Day (UTC)
          <input
            type="date"
            value={filters.date}
            onChange={(e) => setFilters({ ...filters, date: e.target.value })}
          />
        </label>
        <label className="checkbox">
          <input
            type="checkbox"
            checked={filters.freeOnly}
            onChange={(e) =>
              setFilters({ ...filters, freeOnly: e.target.checked })
            }
          />{" "}
          Free or host-covered
        </label>
        <label className="checkbox">
          <input
            type="checkbox"
            checked={filters.openOnly}
            onChange={(e) =>
              setFilters({ ...filters, openOnly: e.target.checked })
            }
          />{" "}
          Open spots only
        </label>
        </div>
        <button className="primary">Find events ↗</button>
      </form>
      <details className="venue-discovery" onToggle={e => setVenueFinderOpen(e.currentTarget.open)}><summary>Find courts & activity venues in Lebanon ↗</summary>{venueFinderOpen && <VenueMap config={config} type={lookups.sports.find(s => s.sportId === Number(filters.sportId))?.name} subtypeId={Number(filters.sportId)||undefined}/>}</details>
      <Alert>{error}</Alert>
      {loading ? (
        <Loading />
      ) : data?.length ? (
        <div className="cards">
          {data.map((g) => (
            <GameCard key={g.gameId} game={g} select={select} user={user} />
          ))}
        </div>
      ) : (
        !error && (
          <Empty
            title="Your next game starts with you"
            action={
              <button className="primary" onClick={() => navigate("host")}>
                Host an event +
              </button>
            }
          >
            Try another day or neighborhood, or bring a new game to the
            community.
          </Empty>
        )
      )}
      <section className="community-banner">
        <span className="banner-symbol" aria-hidden="true">
          <Mark name="pin" />
        </span>
        <div>
          <span className="overline">ONE MORE MAKES THE GAME</span>
          <h2>Short a player? Cover their place.</h2>
          <p>
            Invite someone to play for free when you host. A small gesture. A
            full court.
          </p>
        </div>
        <button className="primary" onClick={() => navigate("host")}>
          Host & give a place
        </button>
      </section>
    </>
  );
}
function Details({ id, user, config, select, navigate, lookups, notify }) {
  const [version, setVersion] = useState(0),
    [busy, setBusy] = useState(false),
    [checkoutOpen, setCheckoutOpen] = useState(false),
    [depositCovered, setDepositCovered] = useState(false),
    [error, setError] = useState(""),
    [editing, setEditing] = useState(false),
    [confirmCancel, setConfirmCancel] = useState(false);
  const {
    data,
    loading,
    error: loadError,
  } = useResource(`/games/${id}`, version);
  async function act(path, method = "POST", message = "Your game is updated.") {
    if (!user) return navigate("auth");
    setBusy(true);
    setError("");
    try {
      const result = await api(
        `/games/${id}${path}`,
        method,
        path === "/join" ? { paymentMethod: "Cash" } : undefined,
      );
      notify(result.message || message);
      setVersion((v) => v + 1);
      setConfirmCancel(false);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  if (loading) return <Loading />;
  if (loadError) return <Alert>{loadError}</Alert>;
  if (!data) return null;
  const g = data.game,
    host = user?.userId === g.hostUserId,
    member = data.roster.some((p) => p.userId === user?.userId),
    covered = availableCovered(g),
    queued = data.membership?.status === "Waitlisted",
    sponsoredMember = data.roster.some(
      (p) => p.userId === user?.userId && p.isSponsored,
    );
  if (editing)
    return (
      <GameForm
        lookups={lookups}
        config={config}
        existing={g}
        onSaved={() => {
          setEditing(false);
          setVersion((v) => v + 1);
          notify("Game updated. Players have been notified.");
        }}
        onBack={() => setEditing(false)}
      />
    );
  const query = mapQuery(g);
  const BookingCheckout = g.requiresDeposit ? DepositCheckout : CheckoutModal;
  return (
    <>
      {checkoutOpen && (
        <BookingCheckout
          covered={depositCovered}
          game={g}
          config={config}
          onClose={() => { setCheckoutOpen(false); setVersion(v => v + 1); }}
          onComplete={(message) => {
            setCheckoutOpen(false);
            setVersion((v) => v + 1);
            notify(message);
          }}
        />
      )}
      <button className="text-link back" onClick={() => navigate("discover")}>
        ← Back to games
      </button>
      <div className="detail-hero">
        <Court sport={g.sport} large />
        <div>
          <span className="overline">
            {g.categoryName} · {g.sport.toUpperCase()} · {g.area.toUpperCase()}
          </span>
          {g.depositBookingStatus === "CONFIRMED_DEPOSIT_LOCKED" && <span className="pill">Full crew · deposits locked</span>}
          <h1>
            {g.sport} at {g.venue}
          </h1>
          <p>Hosted by {host ? "you" : g.hostName}</p>
          {g.gameStatus === "Cancelled" && (
            <span className="pill danger">This game was cancelled</span>
          )}
        </div>
      </div>
      <div className="detail-layout">
        <div>
          <section className="panel">
            <h2>Good to know</h2>
            <div className="detail-facts">
              <div>
                <span>WHEN</span>
                <strong>
                  {dateOf(g.startsAt).toLocaleDateString([], {
                    weekday: "long",
                    month: "long",
                    day: "numeric",
                  })}
                </strong>
                <p>
                  {dateOf(g.startsAt).toLocaleTimeString([], {
                    hour: "2-digit",
                    minute: "2-digit",
                  })}{" "}
                  · your local time
                </p>
              </div>
              <div>
                <span>WHERE</span>
                <strong>{g.venue}</strong>
                <p>
                  {g.address}, {g.area}
                </p>
              </div>
            </div>
            <p className="description">
              {g.description ||
                "A casual game, a welcoming crew, and a good reason to get moving. Bring your gear and arrive a few minutes early."}
            </p>
          </section>
          <section className="panel">
            <div className="section-heading">
              <h2>The crew</h2>
              <span className="pill">
                {g.playerCount} / {g.capacity}
              </span>
            </div>
            <ul className="roster">
              {data.roster.map((p) => (
                <li key={p.userId}>
                  <span className="avatar">
                    {p.displayName.slice(0, 1).toUpperCase()}
                  </span>
                  <div>
                    <strong>{p.displayName}</strong>
                    <small>
                      {p.userId === g.hostUserId
                        ? "Host · bringing everyone together"
                        : p.isSponsored
                          ? "Playing with a host-covered place"
                          : "Ready to play"}
                    </small>
                    {g.requiresDeposit && p.userId !== g.hostUserId && <span className={`pill ${p.depositStatus === "PAID_HELD" ? "" : "danger"}`}>{p.depositStatus === "PAID_HELD" ? (g.gameStatus === "Cancelled" ? "Deposit Verified · refund review" : "Deposit Verified · Spot Reserved") : p.depositStatus === "REFUNDED" ? (g.gameStatus === "Cancelled" ? "Deposit Refunded" : "Deposit Refunded · Spot Reserved") : p.depositStatus === "FORFEITED" ? "Deposit Forfeited" : "Deposit Pending"}</span>}
                  </div>
                </li>
              ))}
            </ul>
          </section>
          <VenueContactCard game={g}/>
          <GameTrust id={id} user={user} game={g} roster={data.roster} notify={notify}/>
          <section className="panel">
            <div className="section-heading">
              <h2>Meet you here</h2>
              <a
                className="text-link"
                target="_blank"
                rel="noopener noreferrer"
                href={`https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(query)}`}
              >
                Get directions ↗
              </a>
            </div>
            {config.mapsEmbedApiKey ? (
              <iframe
                className="venue-map"
                title={`Map of ${g.venue}`}
                loading="lazy"
                referrerPolicy="strict-origin-when-cross-origin"
                allowFullScreen
                src={`https://www.google.com/maps/embed/v1/place?key=${encodeURIComponent(config.mapsEmbedApiKey)}&q=${encodeURIComponent(query)}`}
              />
            ) : (
              <a
                className="map-placeholder"
                target="_blank"
                rel="noopener noreferrer"
                href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}`}
              >
                <Mark name="pin" />
                <strong>{g.venue}</strong>
                <span>
                  {g.address}, {g.area}
                </span>
                <span className="text-link">Open in Google Maps ↗</span>
              </a>
            )}
          </section>
        </div>
        <aside>
          <section className="panel booking">
            <span className="overline">YOUR NEXT GOOD GAME</span>
            <h2>{sponsoredMember ? "Your place is covered" : price(g)}</h2>
            <p className="muted">
              {Number(g.costPerPlayer)
                ? "Venue share per player · settle directly with the host."
                : "Just bring yourself and your game."}
            </p>
            {covered > 0 && (
              <div className="offer">
                <span>✦ THE ONE-MORE OFFER</span>
                <h3>
                  {g.capacity - g.playerCount === 1
                    ? "One more player. Zero fee."
                    : "Your place. On the host."}
                </h3>
                <p>
                  {covered} host-covered {covered === 1 ? "place" : "places"}{" "}
                  available. The host covers your venue share.
                </p>
                {!member && !queued && (
                  <button
                    className="primary full"
                    disabled={busy || !playable(g)}
                    onClick={() =>
                      g.requiresDeposit ? (setDepositCovered(true), setCheckoutOpen(true)) : act(
                        "/sponsored-place",
                        "POST",
                        "You are in! The host covers your venue fee.",
                      )
                    }
                  >
                    {g.requiresDeposit ? "Claim host-covered share" : "Claim a free place ↗"}
                  </button>
                )}
              </div>
            )}
            <p>
              <strong>{Math.max(0, g.capacity - g.playerCount)}</strong> places
              left · {g.playerCount} already in
            </p>
            <Alert>{error}</Alert>
            {g.requiresDeposit && <p className="payment-note">A $1 commitment deposit applies to players, including host-covered shares. The host is exempt. Your spot is reserved only after an operator verifies the transfer.</p>}
            {data.membership && (
              <p className="membership-status" role="status">
                {queued
                  ? `Waitlisted · position #${data.membership.queuePosition}`
                  : "Your place is confirmed"}
                {data.membership.paymentMethod === "Cash"
                  ? " · cash at venue"
                  : data.membership.paymentMethod === "WhishMock"
                    ? " · DEMO Whish — no real charge"
                    : data.membership.paymentMethod === "WhishManual" ? " · Whish transfer — check Payments for status"
                    : ""}
              </p>
            )}
            {Number(g.costPerPlayer) > 0 && !sponsoredMember && (
              <p className="muted">
                A 5% platform service fee applies when you get a place. Review
                the exact total at checkout.
              </p>
            )}
            {sponsoredMember && (
              <p className="muted">
                {g.requiresDeposit ? "Your host covers the venue share. The $1 commitment deposit still applies." : "Your host-covered place is free, with no platform fee."}
              </p>
            )}
            {playable(g) ? (
              <>
                {!member && !queued && (
                  <button
                    className="primary full"
                    disabled={busy}
                    onClick={() =>
                      !user
                        ? navigate("auth")
                        : Number(g.costPerPlayer) > 0 || g.requiresDeposit
                          ? (setDepositCovered(false), setCheckoutOpen(true))
                          : act(
                              "/join",
                              "POST",
                              g.playerCount >= g.capacity
                                ? "You are on the waitlist."
                                : "Your place is confirmed.",
                            )
                    }
                  >
                    {busy
                      ? "One moment…"
                      : user
                        ? g.playerCount >= g.capacity
                          ? "FULL — Join Waitlist"
                          : "Join this event"
                        : "Sign in to join"}
                  </button>
                )}
                {user && (member || queued) && (
                  <button
                    className="secondary full"
                    disabled={busy}
                    onClick={() =>
                      act(
                        "/participation",
                        "DELETE",
                        "You left this game or its waitlist.",
                      )
                    }
                  >
                    Leave game / waitlist
                  </button>
                )}
                {queued && g.requiresDeposit && g.playerCount < g.capacity && <button className="primary full" onClick={() => {setDepositCovered(false);setCheckoutOpen(true);}}>Verify deposit to reserve this opening</button>}
                <button
                  className="text-link full"
                  onClick={() => navigate("mine")}
                >
                  Check my place & waitlist →
                </button>
              </>
            ) : (
              <p className="muted">
                {g.gameStatus === "Cancelled"
                  ? "The host cancelled this game."
                  : "This game has already started."}
              </p>
            )}
          </section>
          {host && playable(g) && (
            <section className="panel">
              <h3>Your game, your crew</h3>
              <p className="muted">
                Keep your players up to date. Changes send an in-app
                notification.
              </p>
              <button
                className="secondary full"
                onClick={() => setEditing(true)}
              >
                Edit game
              </button>
              {!confirmCancel ? (
                <button
                  className="danger-button full"
                  onClick={() => setConfirmCancel(true)}
                >
                  Cancel hosted game
                </button>
              ) : (
                <div
                  className="confirm"
                  role="group"
                  aria-label="Confirm game cancellation"
                >
                  <p>Cancel for everyone? All players will be notified.</p>
                  <button
                    className="danger-button full"
                    disabled={busy}
                    onClick={() => act("/cancel")}
                  >
                    Yes, cancel this game
                  </button>
                  <button
                    className="text-link full"
                    onClick={() => setConfirmCancel(false)}
                  >
                    Keep playing
                  </button>
                </div>
              )}
            </section>
          )}
        </aside>
      </div>
    </>
  );
}
function MyGames({ user, select }) {
  const [tab, setTab] = useState("upcoming");
  const { data, error, loading } = useResource("/me/games");
  const games =
    data?.filter((g) =>
      tab === "hosting"
        ? g.hostUserId === user.userId
        : tab === "waitlist"
          ? playable(g) && g.status === "Waitlisted"
          : tab === "past"
            ? !playable(g)
            : playable(g),
    ) || [];
  return (
    <>
      <span className="overline">YOUR PEOPLE. YOUR PLANS.</span>
      <h1>My games</h1>
      <p className="lead">
        Confirmed places, waiting lists, and the games you bring to life.
      </p>
      <div className="sport-chips">
        {["upcoming", "waitlist", "hosting", "past"].map((t) => (
          <button
            key={t}
            className={tab === t ? "selected" : ""}
            onClick={() => setTab(t)}
          >
            {t[0].toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>
      <Alert>{error}</Alert>
      {loading ? (
        <Loading />
      ) : games.length ? (
        <div className="cards">
          {games.map((g) => (
            <GameCard key={g.gameId} game={g} select={select} user={user} />
          ))}
        </div>
      ) : (
        <Empty title="A little room in your game plan">
          Your games and queue positions will appear here.
        </Empty>
      )}
    </>
  );
}
function Profile({ lookups, onSaved, onPayments }) {
  const { data, error, loading } = useResource("/me/profile");
  const [chosenSports,setChosenSports] = useState(null);
  const [saving, setSaving] = useState(false),
    [problem, setProblem] = useState("");
  useEffect(()=>{if(data)setChosenSports(data.sports.filter(id=>lookups.sports.some(s=>s.sportId===id&&s.categorySlug==="sports")).slice(0,3));},[data,lookups.sports]);
  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    if(!chosenSports?.length){setProblem("Choose at least one sport.");return;}
    setSaving(true);
    setProblem("");
    try {
      await api("/me/profile", "PUT", {
        displayName: f.get("name"),
        bio: f.get("bio"),
        area: f.get("area"),
        skillLevel: f.get("skill"),
        sportIds: chosenSports,
        gender:f.get("gender")||null,
        dateOfBirth:f.get("dateOfBirth")||null,
      });
      onSaved(f.get("name"));
    } catch (e) {
      setProblem(e.message);
    } finally {
      setSaving(false);
    }
  }
  if (loading) return <Loading />;
  if (error) return <Alert>{error}</Alert>;
  return (
    <div className="form-page">
      <span className="overline">MORE YOU. BETTER GAMES.</span>
      <h1>My profile</h1>
      <button className="secondary" onClick={onPayments}>Payments & deposits</button>
      <p className="lead">
        Your favorite sports and neighborhood shape what you see
        when you sign in.
      </p>
      <form className="panel form-grid" onSubmit={submit}>
        <label>
          What should the crew call you?
          <input
            required
            name="name"
            maxLength="80"
            defaultValue={data.profile.displayName}
          />
        </label>
        <label>
          Email
          <input value={data.profile.email} readOnly />
        </label>
        <label>
          Home court / neighborhood
          <select name="area" defaultValue={data.profile.area || ""}>
            <option value="">Anywhere in Lebanon</option>
            {[...new Set(lookups.venues.map((v) => v.area))].map((a) => (
              <option key={a}>{a}</option>
            ))}
          </select>
        </label>
        <label>
          Your level
          <select name="skill" defaultValue={data.profile.skillLevel}>
            {["All levels", "Beginner", "Intermediate", "Advanced"].map((s) => (
              <option key={s}>{s}</option>
            ))}
          </select>
        </label>
        <label>Gender<select aria-label="Gender" name="gender" defaultValue={data.profile.gender||""}><option value="">Not provided</option>{genderOptions.map(([value,label])=><option value={value} key={value}>{label}</option>)}</select></label>
        <label>Date of birth<input type="date" name="dateOfBirth" min="1900-01-01" max={todayInput()} defaultValue={data.profile.dateOfBirth?.slice(0,10)||""}/></label>
        <div className="form-wide"><SportsPicker sports={lookups.sports} value={chosenSports||[]} onChange={setChosenSports}/></div>
        <label className="form-wide">
          A little about you
          <textarea
            name="bio"
            maxLength="400"
            rows="3"
            defaultValue={data.profile.bio}
            placeholder="Weekend baller? First-time padel player? There’s a crew for you."
          />
        </label>
        <div className="form-wide">
          <Alert>{problem}</Alert>
          <button className="primary" disabled={saving}>
            {saving ? "Saving…" : "Save my preferences ↗"}
          </button>
        </div>
      </form>
    </div>
  );
}
function Inbox({ notifications, select, refresh }) {
  const [older, setOlder] = useState([]),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const items = [...(notifications?.items || []), ...older].filter(
    (x, i, all) =>
      all.findIndex((y) => y.notificationId === x.notificationId) === i,
  );
  async function open(n) {
    try {
      await api(`/me/notifications/${n.notificationId}/read`, "POST");
      await refresh();
      if (n.gameId) select(n.gameId);
    } catch (e) {
      setError(e.message);
    }
  }
  async function more() {
    if (!items.length) return;
    setBusy(true);
    try {
      const r = await api(
        `/me/notifications?beforeId=${items.at(-1).notificationId}`,
      );
      setOlder((v) => [...v, ...r.items]);
      if (!r.items.length) setError("You are all caught up.");
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="inbox">
      <span className="overline">NEVER MISS YOUR MOMENT</span>
      <h1>Inbox</h1>
      <p className="lead">
        Game changes, new players, and the moment your waitlist place opens.
      </p>
      <Alert>{error}</Alert>
      {items.length ? (
        <>
          <ul className="notification-list">
            {items.map((n) => (
              <li key={n.notificationId}>
                <button
                  className={n.readAt ? "read" : "unread"}
                  onClick={() => open(n)}
                >
                  <span className="notification-dot" />
                  <div>
                    <strong>{n.title}</strong>
                    <p>{n.body}</p>
                    <small>{dateOf(n.createdAt).toLocaleString()}</small>
                  </div>
                  <span aria-hidden="true">↗</span>
                </button>
              </li>
            ))}
          </ul>
          <button className="secondary" disabled={busy} onClick={more}>
            {busy ? "Loading…" : "Older updates"}
          </button>
        </>
      ) : (
        <Empty title="All quiet on the court">
          Your updates will land here. You’ll hear when the game changes or your
          place opens.
        </Empty>
      )}
    </div>
  );
}
function Payments({ config, user }) {
  return (
    <div className="form-page">
      <span className="overline">YOUR PLAN. YOUR PAYMENT CHOICE.</span>
      <h1>Payments</h1>
      <p className="lead">
        Prices are shown in USD or LBP before you reserve. No currency
        conversion is performed.
      </p>
      <section className="panel">
        <h2>Cash or Whish</h2>
        <p><strong>Cash in person</strong> — pay the host at the venue.</p>
        <p><strong>Whish Money transfer</strong> — {config.manualWhishAvailable ? `choose Whish when booking, then follow the instructions to send to ${config.manualWhishRecipient}. GameOn checks transfers manually.` : "not currently available."}</p>
        <p>
          Cash is settled in person with the host. A host-covered place means
          your host pays your venue share.
        </p>
        <div className="offer">
          <h3>Whish Pay demo checkout</h3>
          <p>
            {config.mockPaymentsAvailable
              ? "Try the clearly labeled mock Whish option in a priced event’s checkout. It simulates verification and transfers no real money."
              : "Mock Whish checkout is unavailable in this environment."}
            Automated Whish merchant checkout remains unconnected. Manual transfers
            are separate; a demo is never a real payment receipt.
          </p>
          <p>
            GameOn does not collect your Whish password, PIN, or one-time codes.
          </p>
        </div>
      </section>
      {user && <><DepositHistory/><PaymentHistory/></>}
    </div>
  );
}
function Auth({ config, lookups, onLogin, destination, initialMode="login", onModeChange }) {
  const reset = useRef(new URLSearchParams(location.search).get("reset"));
  const [sports,setSports] = useState([]);
  const [mode, setMode] = useState(reset.current ? "reset" : initialMode),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [message, setMessage] = useState("");
  useEffect(() => {
    if (reset.current) history.replaceState({}, "", location.pathname);
  }, []);
  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    if(mode==="register"&&sports.length<1){setError("Choose at least one sport (up to three).");return;}
    setBusy(true);
    setError("");
    setMessage("");
    try {
      if (mode === "forgot") {
        const r = await api("/auth/forgot-password", "POST", {
          email: f.get("email"),
        });
        setMessage(r.message);
      } else if (mode === "reset") {
        const r = await api("/auth/reset-password", "POST", {
          token: reset.current,
          password: f.get("password"),
        });
        reset.current = null;
        setMode("login");
        setMessage(r.message);
      } else {
        const r = await api(`/auth/${mode}`, "POST", {
          email: f.get("email"),
          password: f.get("password"),
          displayName: f.get("name"),
          ...(mode==="register"?{gender:f.get("gender"),dateOfBirth:f.get("dateOfBirth"),sportIds:sports}:{}),
        });
        await refreshCsrf();
        const me = await api("/auth/me");
        onLogin(me);
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  function change(m) {
    if((m==="register"||m==="login")&&onModeChange){onModeChange(m);return;}
    setMode(m);
    setError("");
    setMessage("");
  }
  return (
    <div className="auth-layout">
      <div className="auth-story">
        <span className="overline">THE BEST PLANS START WITH “GAME ON.”</span>
        <h1>
          Your people.
          <br />
          Your sport.
          <br />
          <em>Your next move.</em>
        </h1>
        <p>
          From your first rally to your regular Sunday crew. Find your place in
          the game.
        </p>
        <Court sport="Basketball" large />
      </div>
      <div className="panel auth-panel">
        {destination && <p className="auth-context" role="status">Sign in to continue to {pageLabels[destination] || "your account"}.</p>}
        <span className="overline">WELCOME TO THE CREW</span>
        <h2>
          {mode === "register"
            ? "Make yourself at home."
            : mode === "forgot"
              ? "Let’s get you back in."
              : mode === "reset"
                ? "A fresh start."
                : "Good to see you."}
        </h2>
        <form className="stack" onSubmit={submit}>
          {mode === "register" && (
            <label>
              Your name
              <input
                required
                name="name"
                maxLength="80"
                autoComplete="nickname"
              />
            </label>
          )}
          {mode !== "reset" && (
            <label>
              Email
              <input
                required
                name="email"
                type="email"
                maxLength="254"
                autoComplete="email"
              />
            </label>
          )}
          {mode !== "forgot" && (
            <label>
              {mode === "reset" ? "New password" : "Password"}
              <input
                required
                name="password"
                aria-label={mode === "reset" ? "New password" : "Password"}
                type="password"
                minLength={mode === "login" ? 1 : 12}
                maxLength="128"
                autoComplete={
                  mode === "login" ? "current-password" : "new-password"
                }
              />
              {mode !== "login" && (
                <small>At least 12 characters. Make it yours.</small>
              )}
            </label>
          )}
          {mode==="register"&&<>
            <div className="signup-demographics"><label>Gender<select aria-label="Gender" required name="gender" defaultValue=""><option value="" disabled>Choose an option</option>{genderOptions.map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label>
            <label>Date of birth<input required type="date" name="dateOfBirth" min="1900-01-01" max={todayInput()} autoComplete="bday"/></label></div>
            <SportsPicker sports={lookups.sports} value={sports} onChange={next=>{setSports(next);if(next.length)setError("");}}/>
            <p className="muted privacy-note">Gender and date of birth stay in your private profile. Sports preferences personalize your feed.</p>
          </>}
          <Alert>{error}</Alert>
          {message && (
            <p className="success" role="status">
              {message}
            </p>
          )}
          <button
            className="primary full"
            disabled={
              busy || (mode === "forgot" && !config.passwordResetAvailable)
            }
          >
            {busy
              ? "One moment…"
              : mode === "register"
                ? "Join the crew ↗"
                : mode === "forgot"
                  ? "Send reset link"
                  : mode === "reset"
                    ? "Save new password"
                    : "Let’s play ↗"}
          </button>
        </form>
        {mode === "login" && (
          <button className="text-link" onClick={() => change("forgot")}>
            Forgot your password?
          </button>
        )}
        {mode === "forgot" && !config.passwordResetAvailable && (
          <p className="muted">
            Email recovery is not available yet. Contact the organizer for help.
          </p>
        )}
        <div className="auth-switch">
          {mode === "login" ? (
            <>
              New around here?{" "}
              <button className="text-link" onClick={() => change("register")}>
                Create an account
              </button>
            </>
          ) : (
            <button className="text-link" onClick={() => change("login")}>
              Back to sign in
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
function AccountGate({page, onSignIn, onDiscover}) {
  const descriptions = {mine:"Your bookings, hosted games and waitlist places will appear here.",inbox:"Get game updates, player notifications and waitlist alerts here.",profile:"Save your favorite sports, preferred area and player profile.",host:"Choose a sport, venue and time, then invite your next crew."};
  return <section className="account-gate" aria-labelledby="account-heading"><span className="gate-icon"><Mark name={page === "mine" ? "games" : page}/></span><span className="overline">YOUR GAMEON ACCOUNT</span><h1 id="account-heading">{pageLabels[page]}</h1><p>{descriptions[page]}</p><p className="muted">Sign in to access this page.</p><div className="gate-actions"><button className="primary" onClick={onSignIn}>Sign in to continue</button><button className="secondary" onClick={onDiscover}>Browse games</button></div></section>;
}
function App() {
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme || "dark");
  function toggleTheme() {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    document.documentElement.style.backgroundColor = next === "light" ? "#f6f6f8" : "#000000";
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", next === "light" ? "#f6f6f8" : "#000000");
    setTheme(next);
    try { localStorage.setItem("gameon-theme", next); } catch { /* Storage is optional. */ }
  }
  const [page, setPage] = useState(
      new URLSearchParams(location.search).has("reset") ? "auth" : readRoute().page,
    ),
    [selected, setSelected] = useState(() => readRoute().selected),
    [user, setUser] = useState(null),
    [authReady, setAuthReady] = useState(false);
  const [lookups, setLookups] = useState({ sports: [], venues: [] }),
    [config, setConfig] = useState({}),
    [error, setError] = useState(""),
    [toast, setToast] = useState(""),
    [revision, setRevision] = useState(0),
    [notifications, setNotifications] = useState(null);
  const [returnAfterAuth, setReturnAfterAuth] = useState(null);
  const currentRoute = useRef({page, selected});
  currentRoute.current = {page, selected};
  const toastTimer = useRef();
  function notify(text) {
    clearTimeout(toastTimer.current);
    setToast(text);
    toastTimer.current = setTimeout(() => setToast(""), 6500);
  }
  useEffect(() => {
    const c = new AbortController();
    Promise.all([
      api("/lookups", "GET", undefined, { signal: c.signal }),
      api("/config", "GET", undefined, { signal: c.signal }),
    ])
      .then(([l, cfg]) => {
        setLookups(l);
        setConfig(cfg);
      })
      .catch((e) => {
        if (e.name !== "AbortError") setError(e.message);
      });
    api("/auth/me", "GET", undefined, { signal: c.signal })
      .then(setUser)
      .catch(() => {})
      .finally(() => setAuthReady(true));
    return () => {
      c.abort();
      clearTimeout(toastTimer.current);
    };
  }, []);
  async function refreshInbox() {
    const n = await api("/me/notifications");
    setNotifications(n);
  }
  useEffect(() => {
    if (!user) {
      setNotifications(null);
      return;
    }
    let stopped = false,
      controller;
    async function poll() {
      if (document.hidden) return;
      controller = new AbortController();
      try {
        const n = await api("/me/notifications", "GET", undefined, {
          signal: controller.signal,
        });
        if (!stopped) setNotifications(n);
      } catch (e) {
        if (!stopped && e.status === 401) {
          setUser(null);
          setReturnAfterAuth(currentRoute.current);
          setPage("auth");
          history.replaceState(null, "", routeHref("auth"));
          await refreshCsrf().catch(() => {});
          notify("Your session ended. Please sign in again.");
        }
      }
    }
    poll();
    const timer = setInterval(poll, 30000);
    document.addEventListener("visibilitychange", poll);
    return () => {
      stopped = true;
      controller?.abort();
      clearInterval(timer);
      document.removeEventListener("visibilitychange", poll);
    };
  }, [user?.userId]);
  useEffect(() => {
    function restoreRoute() {const next=readRoute();setPage(next.page);setSelected(next.selected);window.scrollTo({top:0,behavior:"auto"});}
    window.addEventListener("popstate",restoreRoute);
    window.addEventListener("hashchange",restoreRoute);
    return () => {window.removeEventListener("popstate",restoreRoute);window.removeEventListener("hashchange",restoreRoute);};
  }, []);
  useEffect(() => {document.title = `${page === "details" ? "Event details" : pageLabels[page] || "Sign in"} · GameOn`;}, [page]);
  function navigate(next, eventId = selected, replace = false) {
    if (["auth","signup"].includes(next) && !["auth","signup"].includes(page)) setReturnAfterAuth({page: protectedPages.has(page) || page === "details" ? page : "discover",selected});
    setPage(next);
    if (next === "details") setSelected(eventId);
    const href=routeHref(next,eventId);
    if (location.hash !== href) history[replace ? "replaceState" : "pushState"](null,"",href);
    window.scrollTo({top:0,behavior:matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"});
  }
  function select(id) {navigate("details",id);}
  async function logout() {
    try {
      await api("/auth/logout", "POST");
      await refreshCsrf();
      setUser(null);
      setReturnAfterAuth(null);
      navigate("discover",null,true);
      notify("Signed out. See you next game.");
    } catch (e) {
      notify(e.message);
    }
  }
  const links = [["discover","Discover"],["venues","Venues"],...(user?[["mine","My games"],["inbox","Inbox"],["profile","My profile"]]:[])];
  return (
    <>
      <a className="skip" href="#main" onClick={e => {e.preventDefault();document.getElementById("main")?.focus();}}>
        Skip to content
      </a>
      <header className="site-header">
        <button className="brand" onClick={() => navigate("discover")}>
          <span className="brand-icon">
            <Mark name="pin" />
          </span>
          game<span>on</span>
          <i />
        </button>
        <nav aria-label="Main navigation" style={{"--nav-count":links.length}}>
          {links.map(([key, label]) => (
            <a
              key={key}
              href={routeHref(key)}
              aria-current={page === key ? "page" : undefined}
              className={page === key ? "active" : ""}
              onClick={e => {if (!e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey) {e.preventDefault();navigate(key);}}}
            >
              <Mark name={key === "mine" ? "games" : key} />
              {label}
              {key === "inbox" && notifications?.unreadCount > 0 && (
                <span
                  className="badge"
                  aria-label={`${notifications.unreadCount} unread notifications`}
                >
                  {Math.min(notifications.unreadCount, 99)}
                </span>
              )}
            </a>
          ))}
        </nav>
        <div className="header-actions">
          <button className="theme-toggle" onClick={toggleTheme} aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} mode`} title={`Switch to ${theme === "dark" ? "light" : "dark"} mode`}>
            {theme === "dark" ? <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg> : <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.8 13a9 9 0 0 1-9.8-9.8A9 9 0 1 0 20.8 13Z"/></svg>}
          </button>
          {user && <button className="primary small" onClick={() => navigate("host")}>
            + Host event
          </button>}
          {authReady &&
            (user ? (
              <button className="user-button" onClick={logout} title="Sign out">
                <span className="avatar small">{user.name[0]}</span>
                <span className="signout">Sign out</span>
              </button>
            ) : (
              <div className="public-auth-actions"><button className="text-link" onClick={() => navigate("auth")}>Sign in ↗</button><button className="primary small" onClick={()=>navigate("signup")}>Sign up</button></div>
            ))}
        </div>
      </header>
      <main id="main" tabIndex={-1}>
        <Alert>{error}</Alert>
        {!authReady ? (
          <Loading />
        ) : (
          <>
            {page === "discover" && (
              <Feed
                config={config}
                lookups={lookups}
                user={user}
                select={select}
                navigate={navigate}
                revision={revision}
              />
            )}
            {page === "venues" && <VenueDirectory lookups={lookups} config={config} user={user}/>}
            {page === "details" && (
              <Details
                key={selected}
                id={selected}
                user={user}
                config={config}
                select={select}
                navigate={navigate}
                lookups={lookups}
                notify={notify}
              />
            )}
            {protectedPages.has(page) && !user && <AccountGate page={page} onSignIn={() => navigate("auth")} onDiscover={() => navigate("discover")}/>}
            {page === "host" && user && (
              <GameForm
                lookups={lookups}
                config={config}
                onBack={() => navigate("discover")}
                onSaved={(id) => {
                  notify("Your event is live. Time to find your crew.");
                  select(id);
                }}
              />
            )}{" "}
            {page === "mine" && user && <MyGames user={user} select={select} />}{" "}
            {page === "profile" && user && (
              <Profile
                lookups={lookups}
                onPayments={()=>navigate("payments")}
                onSaved={(name) => {
                  setUser({ ...user, name });
                  setRevision((v) => v + 1);
                  notify("Preferences saved. Your feed is now more you.");
                  navigate("discover");
                }}
              />
            )}{" "}
            {page === "inbox" && user && (
              <Inbox
                notifications={notifications}
                select={select}
                refresh={refreshInbox}
              />
            )}{" "}
            {page === "payments" && user && <Payments config={config} user={user} />}
            {["auth","signup"].includes(page) && (
              <Auth
                key={page}
                config={config}
                lookups={lookups}
                initialMode={page==="signup"?"register":"login"}
                onModeChange={mode=>navigate(mode==="register"?"signup":"auth",selected,true)}
                destination={protectedPages.has(returnAfterAuth?.page) || returnAfterAuth?.page === "details" ? returnAfterAuth.page : undefined}
                onLogin={(me) => {
                  setUser(me);
                  setRevision((v) => v + 1);
                  const destination=returnAfterAuth || {page:"discover",selected:null};
                  navigate(destination.page,destination.selected,true);
                  setReturnAfterAuth(null);
                  notify(`${page === "signup" ? "Welcome" : "Welcome back"}, ${me.name.split(" ")[0]}.`);
                }}
              />
            )}
          </>
        )}
      </main>
      {user && page !== "host" && !["auth","signup"].includes(page) && <button className="primary floating-host" onClick={() => navigate("host")} aria-label="Create an event">+ Host event</button>}
      <footer>
        <button className="brand" onClick={() => navigate("discover")}>
          game<span>on</span>
          <i />
        </button>
        <p>A little less online. A lot more on court.</p>
        {user && <button className="text-link" onClick={() => navigate("payments")}>
          Payments & deposits ↗
        </button>}
        <span>Made for the way Lebanon plays.</span>
      </footer>
      {toast && (
        <div className="toast" role="status">
          <Mark name="check" />
          {toast}
          <button
            aria-label="Dismiss notification"
            onClick={() => setToast("")}
          >
            ×
          </button>
        </div>
      )}
    </>
  );
}
createRoot(document.getElementById("root")).render(<App />);
