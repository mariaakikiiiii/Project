import React from "react";
export default function CategoryTabs({ value, onChange, includeAll = true }) {
  const items = [
    ...(includeAll ? [["", "All"]] : []),
    ["sports", "Sports"],
    ["activities", "Activities"],
  ];
  return (
    <div className="category-tabs" role="group" aria-label="Event category">
      {items.map(([slug, label]) => (
        <button
          key={slug}
          type="button"
          aria-pressed={value === slug}
          className={value === slug ? "selected" : ""}
          onClick={() => onChange(slug)}
        >
          <svg
            aria-hidden="true"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
          >
            <path
              d={
                slug === "sports"
                  ? "M4 12h16M12 4v16M20 12a8 8 0 1 1-16 0 8 8 0 0 1 16 0"
                  : slug === "activities"
                    ? "m12 3 2.5 5.5L21 10l-5 4.5 1 6.5-5-3-5 3 1-6.5L3 10l6.5-1.5L12 3Z"
                    : "M3 3h7v7H3zm11 0h7v7h-7zM3 14h7v7H3zm11 0h7v7h-7z"
              }
            />
          </svg>
          {label}
        </button>
      ))}
    </div>
  );
}
