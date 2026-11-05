import React,{useEffect,useState} from "react";
import {api} from "../api";
import {DepositTransfer,depositLabel,money} from "./DepositCheckout";
function Review({item,refresh}){
 const [decision,setDecision]=useState(item.depositStatus==="PENDING"?"VERIFY":"REFUND"),[note,setNote]=useState(""),[reference,setReference]=useState(""),[busy,setBusy]=useState(false),[error,setError]=useState("");
 async function save(e){e.preventDefault();setBusy(true);setError("");try{await api(`/deposits/${item.depositId}/review`,"POST",{decision,note,refundReference:reference||null});refresh();}catch(e){setError(e.message);}finally{setBusy(false);}}
 return <form className="panel stack" onSubmit={save}><h3>{item.displayName} · {depositLabel(item.depositStatus)}</h3><p>Transfer: {money(item.dueNow ?? item.totalAmount)} · commitment deposit: {money(item.depositAmount)}<br/>Reference: {item.transferReference||"Not submitted"}<br/>Recipient: {item.recipientNumber}</p>
 <label>Operator decision<select value={decision} onChange={e=>setDecision(e.target.value)}><option value="VERIFY" disabled={item.depositStatus!=="PENDING"||!item.transferReference}>Verify actual funds received & authorize spot</option><option value="REJECT">Reject unverified reference</option><option value="REFUND">Record an actual external refund</option><option value="FORFEIT">Record reviewed no-show forfeiture</option></select></label>
 {decision==="REFUND"&&<><p className="payment-note">Refund due: {money(item.depositStatus==="REFUND_PENDING"?(item.dueNow ?? item.totalAmount):item.depositAmount)}. Send the refund outside GameOn first.</p><label>Actual refund transaction reference<input required minLength={4} maxLength={100} value={reference} onChange={e=>setReference(e.target.value)}/></label></>}
 <label>Reconciliation / attendance review note<textarea required minLength={4} maxLength={400} value={note} onChange={e=>setNote(e.target.value)}/></label>
 <label className="checkbox"><input type="checkbox" required key={decision}/>I checked the statement, amount, currency, reference and any attendance/refund evidence for this decision.</label>
 <button className="primary" disabled={busy}>{busy?"Saving…":"Save deposit review"}</button>{error&&<p className="alert" role="alert">{error}</p>}</form>;
}
function ContactEditor({venue,refresh}){
 const [phone,setPhone]=useState(venue.contactPhoneNumber||""),[verified,setVerified]=useState(venue.isVerified),[error,setError]=useState(""),[busy,setBusy]=useState(false);
 async function save(e){e.preventDefault();setBusy(true);setError("");try{await api(`/operator/venues/${venue.venueId}`,"PUT",{phone:phone||null,verified});refresh();}catch(e){setError(e.message);}finally{setBusy(false);}}
 return <form className="panel stack" onSubmit={save}><h3>{venue.name} · {venue.area}</h3><label>Actual venue phone number<input type="tel" required={verified} pattern="\+[0-9]{7,15}" maxLength={16} placeholder="+961…" value={phone} onChange={e=>setPhone(e.target.value)}/></label><label className="checkbox"><input type="checkbox" checked={verified} onChange={e=>setVerified(e.target.checked)}/>I checked this venue and its contact number</label><button className="secondary" disabled={busy}>{busy?"Saving…":"Save venue contact"}</button>{error&&<p className="alert" role="alert">{error}</p>}</form>;
}
export default function DepositHistory(){
 const [data,setData]=useState(null),[reviews,setReviews]=useState([]),[venues,setVenues]=useState([]),[error,setError]=useState(""),[version,setVersion]=useState(0);
 const refresh=()=>setVersion(v=>v+1);
 useEffect(()=>{const c=new AbortController();setError("");api("/me/deposits","GET",undefined,{signal:c.signal}).then(async result=>{setData(result);if(result.canReview){const [r,v]=await Promise.all([api("/deposits/reviews","GET",undefined,{signal:c.signal}),api("/operator/venues","GET",undefined,{signal:c.signal})]);setReviews(r);setVenues(v);}}).catch(e=>{if(e.name!=="AbortError")setError(e.message);});return()=>c.abort();},[version]);
 return <section className="payment-history"><h2>Commitment deposits</h2><p className="muted">A submitted transfer does not reserve a spot until funds are verified. Deposits, refunds and no-shows require operator review.</p><button className="secondary" onClick={refresh}>Refresh deposit status</button>
 {error&&<p className="alert" role="alert">{error}</p>}{data?.deposits.length===0&&<p>No deposit bookings yet.</p>}
 {data?.deposits.map(d=><details className="panel payment-record" key={d.depositId}><summary>{d.sport} at {d.venue} · {depositLabel(d.depositStatus)}</summary><DepositTransfer key={`${d.depositId}:${d.depositStatus}`} booking={d} onUpdate={updated=>setData(old=>({...old,deposits:old.deposits.map(row=>row.depositId===updated.depositId?{...row,...updated}:row)}))}/></details>)}
 {data?.canReview&&<><h2>Deposit & attendance reviews</h2>{reviews.length===0&&<p>No deposits to review.</p>}{reviews.map(d=><Review key={`${d.depositId}:${d.depositStatus}`} item={d} refresh={refresh}/>)}<details><summary>Manage verified venue contact numbers</summary>{venues.map(v=><ContactEditor key={`${v.venueId}:${v.isVerified}:${v.contactPhoneNumber}`} venue={v} refresh={refresh}/>)}</details></>}
 </section>;
}
