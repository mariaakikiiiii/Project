import React, { useEffect, useRef, useState } from "react";
import { api } from "../api";
export default function SponsoredVenues({ onExplore }) {
  const [venues, setVenues] = useState([]),
    [error, setError] = useState(false);
  const rail = useRef();
  useEffect(() => {
    const controller = new AbortController();
    api("/venues/sponsored", "GET", undefined, { signal: controller.signal })
      .then(setVenues)
      .catch((e) => {
        if (e.name !== "AbortError") setError(true);
      });
    return () => controller.abort();
  }, []);
  if (error)
    return (
      <p className="muted" role="status">
        Featured venues are temporarily unavailable.
      </p>
    );
  if (!venues.length) return null;
  function move(direction) {
    rail.current.scrollBy({
      left: direction * 300,
      behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
        ? "auto"
        : "smooth",
    });
  }
  return (
    <section className="sponsored-section" aria-label="Sponsored venues">
      <div className="section-heading">
        <div>
          <span className="overline">SPONSORED VENUES</span>
          <h2>Local spots. In the spotlight.</h2>
        </div>
        <div className="carousel-controls">
          <button
            aria-label="Previous sponsored venues"
            onClick={() => move(-1)}
          >
            ←
          </button>
          <button aria-label="Next sponsored venues" onClick={() => move(1)}>
            →
          </button>
        </div>
      </div>
      <ul className="venue-carousel" ref={rail}>
        {venues.map((v) => (
          <li
            className={`venue-feature ${v.tier.toLowerCase()}`}
            key={v.venueId}
          >
            <div className="venue-pattern" aria-hidden="true" />
            <div className="venue-feature-content">
              <div className="venue-labels">
                <span className="sponsored-label">Sponsored</span>
                <span>{v.tier} partner</span>
              </div>
              <h3>{v.name}</h3>
              <p>
                {v.area} · {v.address}
              </p>
              <button className="text-link" onClick={() => onExplore(v.area)}>
                Explore {v.area} →
              </button>
            </div>
          </li>
        ))}
      </ul>
      <p className="sponsor-disclosure">
        Paid placements, clearly labeled. Event results below still follow your
        filters and preferences.
      </p>
    </section>
  );
}
