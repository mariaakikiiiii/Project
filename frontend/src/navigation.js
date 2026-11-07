// Small hash routes work with the existing single-page deployment and browser Back.
const routes = {discover:"/discover",venues:"/venues",signup:"/sign-up",mine:"/my-games",inbox:"/inbox",profile:"/profile",payments:"/payments",wallet:"/wallet",courts:"/courts",chat:"/chat",rewards:"/rewards",club:"/club",passes:"/memberships",admin:"/admin",host:"/host",auth:"/sign-in"};
export const protectedPages = new Set(["mine","inbox","profile","host","payments","wallet","chat","rewards","club","passes","admin"]);
export const pageLabels = {mine:"My games",inbox:"Inbox",profile:"My profile",host:"Host an event",discover:"Discover",venues:"Venues",signup:"Sign up",payments:"Payments",wallet:"Wallet",courts:"Courts",chat:"Chat",rewards:"Rewards",club:"Club manager",passes:"Memberships",admin:"Admin",profile_me:"Me",details:"this event"};
export function routeHref(page, selected) {
  return "#" + (page === "details" && Number.isSafeInteger(selected) && selected > 0 ? `/events/${selected}` : routes[page] || routes.discover);
}
export function readRoute() {
  const hash = location.hash.slice(1), event = /^\/events\/([1-9]\d*)(?:\?invite=([A-Za-z0-9]{10}))?$/.exec(hash);
  if (event && Number.isSafeInteger(Number(event[1]))) {
    // Private-game invite links (#/events/12?invite=CODE): remember the code for this game in this tab.
    if (event[2]) try { sessionStorage.setItem("gameon.invite." + event[1], event[2].toUpperCase()); } catch { /* storage blocked */ }
    return {page:"details", selected:Number(event[1])};
  }
  return {page:Object.keys(routes).find(key => routes[key] === hash) || "discover", selected:null};
}

export function inviteFor(id) { try { return sessionStorage.getItem("gameon.invite." + id) || ""; } catch { return ""; } }
