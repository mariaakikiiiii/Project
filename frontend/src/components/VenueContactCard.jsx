import React from "react";
export default function VenueContactCard({game}) {
 const phone=/^\+[0-9]{7,15}$/.test(game.contactPhoneNumber||"")?game.contactPhoneNumber:null;
 const verified=game.venueIsVerified && Boolean(phone);
 return <section className="panel venue-contact"><div><span className="overline">CONTACT THE OPERATOR</span><h2>Call Venue to Reserve</h2><p><strong>{game.venue}</strong> · {game.area}</p><span className={`pill ${verified?"":"danger"}`}>{verified?"Venue contact checked":"Venue contact not verified"}</span></div>
 <p className="muted">Confirm court availability, price and your venue reservation directly. A GameOn spot or deposit does not book the venue.</p>
 {phone?<><a className="venue-phone" href={`tel:${phone}`}>{phone}</a><a className="primary full" href={`tel:${phone}`}>Call Now</a></>:<p className="payment-note">The venue’s phone number has not been provided. GameOn has not verified a reservable court here.</p>}</section>;
}
