export const dateOf = (value) =>
  new Date(/(?:Z|[+-]\d{2}:\d{2})$/.test(value) ? value : value + "Z");
export const localInput = (value) => {
  const date = dateOf(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
};
export const price = (game) =>
  Number(game.costPerPlayer) === 0
    ? "Free to play"
    : new Intl.NumberFormat("en-LB", {
        style: "currency",
        currency: game.currency,
        maximumFractionDigits: game.currency === "LBP" ? 0 : 2,
      }).format(game.costPerPlayer);
export const availableCovered = (game) =>
  game.gameStatus === "Open" && dateOf(game.startsAt) > new Date()
    ? Math.max(
        0,
        Math.min(
          game.sponsoredSlots - game.sponsoredClaimed,
          game.capacity - game.playerCount,
        ),
      )
    : 0;
export const playable = (game) =>
  game.gameStatus === "Open" && dateOf(game.startsAt) > new Date();
export const mapQuery = (game) =>
  [game.venue, game.address, game.area, "Lebanon"].filter(Boolean).join(", ");
