// Apply before rendering so a saved light preference never flashes dark.
try {
  document.documentElement.dataset.theme = localStorage.getItem("gameon-theme") === "light" ? "light" : "dark";
} catch {
  document.documentElement.dataset.theme = "dark";
}
document.documentElement.style.backgroundColor = document.documentElement.dataset.theme === "light" ? "#f6f6f8" : "#000000";
