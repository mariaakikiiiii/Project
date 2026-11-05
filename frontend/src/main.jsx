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
import "./style.css";
import CheckoutModal from "./components/CheckoutModal";
import SponsoredVenues from "./components/SponsoredVenues";
import CategoryTabs from "./components/CategoryTabs";
import GameForm from "./components/EventWizard";
import PaymentSelector from "./components/PaymentSelector";

function Mark({ name }) {
  const paths = {
    pin: "M7 17 17 7M7 7h10v10",
    back: "M19 12H5m6-6-6 6 6 6",
    check: "m5 12 4 4L19 6",
    discover: "m21 21-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0",
    games: "M3 5h18v16H3zM7 2v6m10-6v6M3 11h18",
    inbox: "M18 8a6 6 0 0 0-12 0c0 8-3 8-3 10h18c0-2-3-2-3-10M10 21h4",
    profile: "M20 21a8 8 0 0 0-16 0M16 6a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
    host: "M12 5v14M5 12h14",
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
    <article className="game-card">
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
            className={`pill ${g.gameStatus === "Cancelled" ? "danger" : ""}`}
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
    </article>
  );
}
function Feed({ lookups, user, select, navigate, revision }) {
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
      <SponsoredVenues onExplore={exploreSponsored} />
      <section className="hero">
        <div className="hero-copy">
          <span className="overline">
            <span className="live-dot" /> GOOD GAMES START WITH GOOD PEOPLE
          </span>
          <h1>
            {user ? (
              <>
                Your next game,
                <br />
                <em>{user.name.split(" ")[0]}.</em>
              </>
            ) : (
              <>
                Less scrolling.
                <br />
                <em>More playing.</em>
              </>
            )}
          </h1>
          <p>
            From pickup matches to escape-room missions. Find your people. Make
            a better plan.
          </p>
          <div className="hero-actions">
            <button
              className="primary"
              onClick={() =>
                document
                  .getElementById("discover-filters")
                  .scrollIntoView({ behavior: "smooth" })
              }
            >
              Find my next game <Mark name="pin" />
            </button>
            <button className="hero-secondary" onClick={() => navigate("host")}>
              Bring your own crew +
            </button>
          </div>
          <div className="hero-note">
            <span className="mini-avatars">
              <i>M</i>
              <i>J</i>
              <i>R</i>
            </span>
            <span>Casual games. Real connections. Across Lebanon.</span>
          </div>
        </div>
        <div className="hero-visual">
          <div className="orbit one" />
          <div className="orbit two" />
          <div className="hero-ball">
            <svg viewBox="0 0 200 200" aria-hidden="true">
              <circle cx="100" cy="100" r="98" />
              <path d="M2 100h196M100 2v196M28 30c80 5 80 135 0 140M172 30c-80 5-80 135 0 140" />
            </svg>
          </div>
          <div className="floating-card">
            <span>THE ONE-MORE CLUB</span>
            <strong>One player short?</strong>
            <p>
              Offer a host-covered place.
              <br />
              Their game. Your treat.
            </p>
            <span className="tiny-pill">More play. Less friction.</span>
          </div>
          <span className="visual-label">BEIRUT & BEYOND ↗</span>
        </div>
      </section>
      <div className="section-heading">
        <div>
          <span className="overline">FIND YOUR KIND OF GAME</span>
          <h2>{user ? "Picked with you in mind" : "A game for every mood"}</h2>
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
      <label className="mobile-type-select">
        Sport or activity
        <select value={filters.sportId} onChange={(e) => sport(e.target.value)}>
          <option value="">All types</option>
          {visibleTypes.map((t) => (
            <option key={t.sportId} value={t.sportId}>
              {t.name}
            </option>
          ))}
        </select>
      </label>
      <div
        className="sport-chips type-chips"
        aria-label="Filter by sport or activity"
      >
        <button
          className={!filters.sportId ? "selected" : ""}
          onClick={() => sport("")}
        >
          All types
        </button>
        {visibleTypes.map((s) => (
          <button
            key={s.sportId}
            className={String(s.sportId) === filters.sportId ? "selected" : ""}
            onClick={() => sport(s.sportId)}
          >
            {s.name === "Basketball" ? "◉" : s.name === "Football" ? "⬡" : "◍"}{" "}
            {s.name}
          </button>
        ))}
      </div>
      <form id="discover-filters" className="filter-bar" onSubmit={search}>
        <label>
          Neighborhood
          <select
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
        <button className="primary">Find events ↗</button>
      </form>
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
  return (
    <>
      {checkoutOpen && (
        <CheckoutModal
          game={g}
          config={config}
          onClose={() => setCheckoutOpen(false)}
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
                  </div>
                </li>
              ))}
            </ul>
          </section>
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
                      act(
                        "/sponsored-place",
                        "POST",
                        "You are in! The host covers your venue fee.",
                      )
                    }
                  >
                    Claim a free place ↗
                  </button>
                )}
              </div>
            )}
            <p>
              <strong>{Math.max(0, g.capacity - g.playerCount)}</strong> places
              left · {g.playerCount} already in
            </p>
            <Alert>{error}</Alert>
            {data.membership && (
              <p className="membership-status" role="status">
                {queued
                  ? `Waitlisted · position #${data.membership.queuePosition}`
                  : "Your place is confirmed"}
                {data.membership.paymentMethod === "Cash"
                  ? " · cash at venue"
                  : data.membership.paymentMethod === "WhishMock"
                    ? " · DEMO Whish — no real charge"
                    : ""}
              </p>
            )}
            {Number(g.costPerPlayer) > 0 && !sponsoredMember && (
              <p className="muted">
                A 2% platform service fee applies when you get a place. Review
                the exact total at checkout.
              </p>
            )}
            {sponsoredMember && (
              <p className="muted">
                Your host-covered place is free, with no platform fee.
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
                        : Number(g.costPerPlayer) > 0
                          ? setCheckoutOpen(true)
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
      <h1>Your game plan.</h1>
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
function Profile({ lookups, onSaved }) {
  const { data, error, loading } = useResource("/me/profile");
  const [saving, setSaving] = useState(false),
    [problem, setProblem] = useState("");
  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    setSaving(true);
    setProblem("");
    try {
      await api("/me/profile", "PUT", {
        displayName: f.get("name"),
        bio: f.get("bio"),
        area: f.get("area"),
        skillLevel: f.get("skill"),
        sportIds: f.getAll("sports").map(Number),
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
      <h1>What’s your game?</h1>
      <p className="lead">
        Your favorite sports, activities and neighborhood shape what you see
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
        <fieldset className="form-wide">
          <legend>Your favorite sports & activities</legend>
          <div className="preference-sports">
            {lookups.sports.map((s) => (
              <label className="checkbox" key={s.sportId}>
                <input
                  type="checkbox"
                  name="sports"
                  value={s.sportId}
                  defaultChecked={data.sports.includes(s.sportId)}
                />
                {s.name}
              </label>
            ))}
          </div>
        </fieldset>
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
      <h1>The latest from your crew.</h1>
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
function Payments({ config }) {
  const [choice, setChoice] = useState("Cash");
  return (
    <div className="form-page">
      <span className="overline">YOUR PLAN. YOUR PAYMENT CHOICE.</span>
      <h1>Clear shares. Better plans.</h1>
      <p className="lead">
        Prices are shown in USD or LBP before you reserve. No currency
        conversion is performed.
      </p>
      <section className="panel">
        <h2>Cash or Whish</h2>
        <PaymentSelector value={choice} onChange={setChoice} />
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
            Real Whish remains unconnected; a demo is never a real payment
            receipt.
          </p>
          <p>
            GameOn does not collect your Whish password, PIN, or one-time codes.
          </p>
        </div>
      </section>
    </div>
  );
}
function Auth({ config, onLogin }) {
  const reset = useRef(new URLSearchParams(location.search).get("reset"));
  const [mode, setMode] = useState(reset.current ? "reset" : "login"),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [message, setMessage] = useState("");
  useEffect(() => {
    if (reset.current) history.replaceState({}, "", location.pathname);
  }, []);
  async function submit(e) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
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
        });
        if (mode === "register") {
          setMode("login");
          setMessage(r.message);
        } else {
          await refreshCsrf();
          const me = await api("/auth/me");
          onLogin(me);
        }
      }
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }
  function change(m) {
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
function App() {
  const [page, setPage] = useState(
      new URLSearchParams(location.search).has("reset") ? "auth" : "discover",
    ),
    [selected, setSelected] = useState(null),
    [user, setUser] = useState(null),
    [authReady, setAuthReady] = useState(false);
  const [lookups, setLookups] = useState({ sports: [], venues: [] }),
    [config, setConfig] = useState({}),
    [error, setError] = useState(""),
    [toast, setToast] = useState(""),
    [revision, setRevision] = useState(0),
    [notifications, setNotifications] = useState(null);
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
          setPage("auth");
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
  function navigate(next) {
    if (["host", "mine", "profile", "inbox"].includes(next) && !user)
      next = "auth";
    setPage(next);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }
  function select(id) {
    setSelected(id);
    navigate("details");
  }
  async function logout() {
    try {
      await api("/auth/logout", "POST");
      await refreshCsrf();
      setUser(null);
      navigate("discover");
      notify("Signed out. See you next game.");
    } catch (e) {
      notify(e.message);
    }
  }
  const links = [
    ["discover", "Discover"],
    ["mine", "My games"],
    ["inbox", "Inbox"],
    ["profile", "My profile"],
  ];
  return (
    <>
      <a className="skip" href="#main">
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
        <nav aria-label="Main navigation">
          {links.map(([key, label]) => (
            <button
              key={key}
              className={page === key ? "active" : ""}
              onClick={() => navigate(key)}
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
            </button>
          ))}
        </nav>
        <div className="header-actions">
          <button className="primary small" onClick={() => navigate("host")}>
            + Host event
          </button>
          {authReady &&
            (user ? (
              <button className="user-button" onClick={logout} title="Sign out">
                <span className="avatar small">{user.name[0]}</span>
                <span className="signout">Sign out</span>
              </button>
            ) : (
              <button className="text-link" onClick={() => navigate("auth")}>
                Sign in ↗
              </button>
            ))}
        </div>
      </header>
      <main id="main">
        <Alert>{error}</Alert>
        {!authReady ? (
          <Loading />
        ) : (
          <>
            {page === "discover" && (
              <Feed
                lookups={lookups}
                user={user}
                select={select}
                navigate={navigate}
                revision={revision}
              />
            )}
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
            {page === "host" && user && (
              <GameForm
                lookups={lookups}
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
            {page === "payments" && <Payments config={config} />}
            {page === "auth" && (
              <Auth
                config={config}
                onLogin={(me) => {
                  setUser(me);
                  setRevision((v) => v + 1);
                  navigate("discover");
                  notify(`Welcome back, ${me.name.split(" ")[0]}.`);
                }}
              />
            )}
          </>
        )}
      </main>
      <footer>
        <button className="brand" onClick={() => navigate("discover")}>
          game<span>on</span>
          <i />
        </button>
        <p>A little less online. A lot more on court.</p>
        <button className="text-link" onClick={() => navigate("payments")}>
          Payments & venue shares ↗
        </button>
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
