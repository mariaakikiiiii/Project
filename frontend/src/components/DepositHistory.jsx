import React,{useEffect,useState} from "react";
import {api} from "../api";
import {DepositTransfer,depositLabel,money} from "./DepositCheckout";
import VenueEditor from "./VenueEditor";

const nextStepText={AwaitingPlayerReference:"Waiting for the player's Whish reference",VerifyTransfer:"Check the Whish statement, then verify or reject",SendRefund:"Send the refund in Whish, then record its reference",
 PlayerLeftPolicyDecision:"Player left early. No policy decided yet: refund only if the business agrees",AttendanceIncomplete:"14 days passed without matching reports. Review evidence",HeldUntilAttendance:"Held until host and player both report attendance"};

function Review({item,refresh}){
 const canRefund=item.depositStatus==="REFUND_PENDING"||(item.depositStatus==="PAID_HELD"&&item.nextStep!=="HeldUntilAttendance");
 const [decision,setDecision]=useState(item.depositStatus==="PENDING"?"VERIFY":"REFUND"),[note,setNote]=useState(""),[reference,setReference]=useState(""),[busy,setBusy]=useState(false),[error,setError]=useState("");
 async function save(e){e.preventDefault();setBusy(true);setError("");try{await api(`/deposits/${item.depositId}/review`,"POST",{decision,note,refundReference:decision==="REFUND"?reference:null});refresh();}catch(e){setError(e.message);}finally{setBusy(false);}}
 return <form className="panel stack" onSubmit={save}><h3>{item.displayName} · game #{item.gameId} · {depositLabel(item.depositStatus)}</h3>
 <p className="payment-note"><strong>Next step:</strong> {nextStepText[item.nextStep]||item.nextStep}</p>
 <p>Transfer due: {money(item.dueNow ?? item.totalAmount)} (includes {money(item.depositAmount)} deposit)<br/>Player reference: {item.transferReference||"Not submitted"} · to {item.recipientNumber}<br/>Host: {item.hostName}{item.hostOnHold&&" (on hold)"} · attendance: host {item.hostMark||"—"}, player {item.playerMark||"—"}</p>
 {item.reviewNote&&<p className="muted">{item.reviewNote}</p>}
 <label>Decision<select value={decision} onChange={e=>setDecision(e.target.value)}>
  <option value="VERIFY" disabled={item.depositStatus!=="PENDING"||!item.transferReference}>Funds received: verify and confirm the place</option>
  <option value="REJECT" disabled={item.depositStatus!=="PENDING"&&!(item.depositStatus==="REFUND_PENDING"&&!item.depositPaidAt)}>Reject: reference not found on statement</option>
  <option value="REFUND" disabled={!canRefund}>Refund already sent: record it</option>
 </select></label>
 {decision==="REFUND"&&<><p className="payment-note">Refund amount: {money(item.depositStatus==="REFUND_PENDING"&&item.reviewNote?.includes("cancel")?(item.dueNow ?? item.totalAmount):item.depositAmount)}. Send it from Whish first; only mark it once the transfer shows as completed.</p><label>Whish refund transaction reference<input required minLength={4} maxLength={100} value={reference} onChange={e=>setReference(e.target.value)}/></label></>}
 <label>What you checked<textarea required minLength={4} maxLength={400} value={note} onChange={e=>setNote(e.target.value)}/></label>
 <label className="checkbox"><input type="checkbox" required key={decision}/>I checked the actual Whish statement (reference, amount, currency, recipient).</label>
 <button className="primary" disabled={busy}>{busy?"Saving…":"Save decision"}</button>{error&&<p className="alert" role="alert">{error}</p>}</form>;
}

function Dispute({item,operator,refresh}){
 const [outcome,setOutcome]=useState("RefundOwed"),[note,setNote]=useState(""),[holdReason,setHoldReason]=useState(""),[busy,setBusy]=useState(false),[error,setError]=useState("");
 async function run(fn){setBusy(true);setError("");try{await fn();refresh();}catch(e){setError(e.message);}finally{setBusy(false);}}
 return <div className="panel stack"><h3>{item.sport} · {new Date(item.startsAt).toLocaleString()} · {item.reason}</h3>
  <p>{item.details}</p><p className="muted">Status: {item.status}{item.outcome?` · ${item.outcome}`:""}{item.resolution?` · ${item.resolution}`:""}{item.depositStatus?` · deposit ${depositLabel(item.depositStatus)}`:""}</p>
  {operator&&item.status==="Open"&&<form className="stack" onSubmit={e=>{e.preventDefault();run(()=>api(`/disputes/${item.disputeId}/resolve`,"POST",{outcome,note}));}}>
   <p className="muted">Raised by {item.raisedByName||"system"} · host {item.hostName}{item.hostOnHold?" (on hold)":""}</p>
   <label>Outcome<select value={outcome} onChange={e=>setOutcome(e.target.value)}><option value="RefundOwed">Refund owed to the player</option><option value="Restored">No refund now: restore previous status</option><option value="NoAction">Close with no money change</option></select></label>
   <label>Resolution note<textarea required minLength={4} maxLength={800} value={note} onChange={e=>setNote(e.target.value)}/></label>
   <button className="primary" disabled={busy}>Resolve dispute</button></form>}
  {operator&&item.hostUserId&&!item.hostOnHold&&<form className="stack" onSubmit={e=>{e.preventDefault();run(()=>api(`/operator/hosts/${item.hostUserId}/hold`,"POST",{hold:true,reason:holdReason}));}}>
   <label>Suspected host fraud? Reason<input required minLength={4} maxLength={400} value={holdReason} onChange={e=>setHoldReason(e.target.value)}/></label>
   <button className="secondary" disabled={busy}>Put host on hold (blocks new games and deposits)</button></form>}
  {error&&<p className="alert" role="alert">{error}</p>}</div>;
}

export default function DepositHistory(){
 const [data,setData]=useState(null),[reviews,setReviews]=useState([]),[venues,setVenues]=useState([]),[disputes,setDisputes]=useState({disputes:[],canReview:false}),[error,setError]=useState(""),[version,setVersion]=useState(0);
 const refresh=()=>setVersion(v=>v+1);
 useEffect(()=>{const c=new AbortController(),o={signal:c.signal};setError("");
  Promise.all([api("/me/deposits","GET",undefined,o),api("/disputes","GET",undefined,o)]).then(async([result,d])=>{setData(result);setDisputes(d);if(result.canReview){const [r,v]=await Promise.all([api("/deposits/reviews","GET",undefined,o),api("/operator/venues","GET",undefined,o)]);setReviews(r);setVenues(v);}}).catch(e=>{if(e.name!=="AbortError")setError(e.message);});
  return()=>c.abort();},[version]);
 return <section className="payment-history"><h2>Commitment deposits</h2><p className="muted">Your place is confirmed only after GameOn verifies your transfer. The $1 is refunded if the host cancels, or after you attend and the host's report matches yours.</p><button className="secondary" onClick={refresh}>Refresh</button>
 {error&&<p className="alert" role="alert">{error}</p>}{!data&&!error&&<p className="muted">Loading…</p>}{data?.deposits.length===0&&<p>No deposits yet. They appear here when you join a game.</p>}
 {data?.deposits.map(d=><details className="panel payment-record" key={d.depositId}><summary>{d.sport} at {d.venue} · {depositLabel(d.depositStatus)}{d.hasOpenDispute?" · dispute open":""}</summary>
  {d.refundReference&&<p className="success">Refund recorded {d.refundedAt?new Date(d.refundedAt).toLocaleDateString():""} · Whish reference {d.refundReference}</p>}
  <DepositTransfer key={`${d.depositId}:${d.depositStatus}`} booking={d} onUpdate={updated=>setData(old=>({...old,deposits:old.deposits.map(row=>row.depositId===updated.depositId?{...row,...updated}:row)}))}/></details>)}
 {disputes.disputes.length>0&&<><h2>{disputes.canReview?"Open disputes":"Your disputes"}</h2>{disputes.disputes.map(x=><Dispute key={`${x.disputeId}:${x.status}`} item={x} operator={disputes.canReview} refresh={refresh}/>)}</>}
 {data?.canReview&&<><h2>Operator: deposits to handle</h2><p className="payment-note">Manual process. GameOn is not connected to a Whish merchant API, so check every transfer and refund in the Whish account yourself. You cannot review your own bookings or games.</p>
  {reviews.length===0&&<p>Nothing to handle right now.</p>}{reviews.map(d=><Review key={`${d.depositId}:${d.depositStatus}`} item={d} refresh={refresh}/>)}
  <details><summary>Venue directory: correct and verify listings ({venues.length})</summary>{venues.map(v=><VenueEditor key={`${v.venueId}:${v.lastAuditAt}`} venue={v} refresh={refresh}/>)}</details></>}
 </section>;
}
