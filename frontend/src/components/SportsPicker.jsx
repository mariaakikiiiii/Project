import React from "react";
export default function SportsPicker({sports,value,onChange}) {
 const options=sports.filter(s=>s.categorySlug==="sports");
 return <fieldset className="sports-picker"><legend>Sports preferences <span>Choose 1–3</span></legend><p className="muted" id="sports-selection-help">{value.length}/3 selected · choose at least one sport</p><div className="preference-sports">{options.map(s=><label className={`checkbox ${value.includes(s.sportId)?"selected":""}`} key={s.sportId}><input type="checkbox" name="sports" value={s.sportId} checked={value.includes(s.sportId)} disabled={!value.includes(s.sportId)&&value.length>=3} onChange={e=>onChange(e.target.checked?[...value,s.sportId]:value.filter(id=>id!==s.sportId))}/><span>{s.name}</span></label>)}</div></fieldset>;
}
export const genderOptions=[ ["Male","Male"],["Female","Female"],["NonBinary","Non-binary"],["PreferNotToSay","Prefer not to say"] ];
export const todayInput=()=>new Date().toISOString().slice(0,10);
