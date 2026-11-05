// Small hash routes work with the existing single-page deployment and browser Back.
const routes = {discover:"/discover",mine:"/my-games",inbox:"/inbox",profile:"/profile",payments:"/payments",host:"/host",auth:"/sign-in"};
export const protectedPages = new Set(["mine","inbox","profile","host"]);
export const pageLabels = {mine:"My games",inbox:"Inbox",profile:"My profile",host:"Host an event",discover:"Discover",payments:"Payments",details:"this event"};
export function routeHref(page, selected) {
  return "#" + (page === "details" && Number.isSafeInteger(selected) && selected > 0 ? `/events/${selected}` : routes[page] || routes.discover);
}
export function readRoute() {
  const hash = location.hash.slice(1), event = /^\/events\/([1-9]\d*)$/.exec(hash);
  if (event && Number.isSafeInteger(Number(event[1]))) return {page:"details", selected:Number(event[1])};
  return {page:Object.keys(routes).find(key => routes[key] === hash) || "discover", selected:null};
}
