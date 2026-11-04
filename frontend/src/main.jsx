import React, {useEffect, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {api, refreshCsrf} from './api';
import './style.css';
const when = v => new Date(v + (v.endsWith('Z') ? '' : 'Z')).toLocaleString();

function GameCards({games,onSelect}) {
  return games.length ? <div className="cards">{games.map(g=><article key={g.gameId}>
    <h3>{g.sport} · {g.area}</h3><p>{g.venue}</p><p>{when(g.startsAt)}</p>
    <p>{g.playerCount}/{g.capacity} players{g.status && ` · ${g.status}`}
      {g.status === 'Waitlisted' && ` · Queue #${g.queuePosition}`}</p>
    <button onClick={()=>onSelect(g.gameId)}>View details</button>
  </article>)}</div> : <p>No games found.</p>;
}
function Discovery({lookups,onSelect}) {
  const [filters,setFilters]=useState({sportId:'',date:'',area:''});
  const [games,setGames]=useState([]), [error,setError]=useState(''), [busy,setBusy]=useState(false);
  async function search(e) {
    e?.preventDefault(); setError(''); setBusy(true);
    try { setGames(await api('/games?'+new URLSearchParams(Object.entries(filters).filter(([,v])=>v)))); }
    catch(e){setError(e.message);} finally {setBusy(false);}
  }
  useEffect(()=>{search();},[]);
  return <section><h2>Discover your next game</h2><form onSubmit={search}>
    <label>Sport<select value={filters.sportId} onChange={e=>setFilters({...filters,sportId:e.target.value})}>
      <option value="">All sports</option>{lookups.sports.map(s=><option key={s.sportId} value={s.sportId}>{s.name}</option>)}
    </select></label>
    <label>Date (UTC)<input type="date" value={filters.date} onChange={e=>setFilters({...filters,date:e.target.value})}/></label>
    <label>Area<select value={filters.area} onChange={e=>setFilters({...filters,area:e.target.value})}>
      <option value="">All areas</option>{[...new Set(lookups.venues.map(v=>v.area))].map(a=><option key={a}>{a}</option>)}
    </select></label><button disabled={busy}>{busy?'Searching…':'Find games'}</button>
  </form><p role="alert">{error}</p><GameCards games={games} onSelect={onSelect}/></section>;
}
function GameDetails({id,onBack}) {
  const [data,setData]=useState(null),[error,setError]=useState(''),[message,setMessage]=useState(''),[busy,setBusy]=useState(false);
  async function load(){setData(await api(`/games/${id}`));}
  useEffect(()=>{load().catch(e=>setError(e.message));},[id]);
  async function act(method,path){setBusy(true);setError('');setMessage('');try {
    const r=await api(`/games/${id}${path}`,method);setMessage(r.status);await load();
  }catch(e){setError(e.message);}finally{setBusy(false);}}
  return <section><button onClick={onBack}>← Back</button><p role="alert">{error}</p><p role="status">{message}</p>{data && <>
    <h2>{data.game.sport} at {data.game.venue}</h2><p>{when(data.game.startsAt)} · {data.game.area}</p>
    <p>{data.game.playerCount}/{data.game.capacity} players (host included)</p>
    <button disabled={busy} onClick={()=>act('POST','/join')}>Join / enter waitlist</button>{' '}
    <button disabled={busy} onClick={()=>act('DELETE','/participation')}>Leave game / waitlist</button>
    <h3>Roster</h3><ul>{data.roster.map(p=><li key={p.userId}>{p.displayName}{p.userId===data.game.hostUserId?' · Host':''}</li>)}</ul>
  </>}</section>;
}
function HostForm({lookups,onSelect}) {
  const [error,setError]=useState(''),[busy,setBusy]=useState(false);
  async function submit(e){e.preventDefault(); const f=new FormData(e.currentTarget);setError('');setBusy(true);
    try{const g=await api('/games','POST',{sportId:Number(f.get('sport')),venueId:Number(f.get('venue')),
      startsAt:new Date(f.get('start')).toISOString(),capacity:Number(f.get('capacity'))});onSelect(g.gameId);}
    catch(e){setError(e.message);}finally{setBusy(false);}}
  return <section><h2>Host a game</h2><p>Capacity includes you. Start time uses your local timezone.</p><form onSubmit={submit}>
    <label>Sport<select required name="sport"><option value="">Choose sport</option>{lookups.sports.map(s=><option key={s.sportId} value={s.sportId}>{s.name}</option>)}</select></label>
    <label>Venue<select required name="venue"><option value="">Choose venue</option>{lookups.venues.map(v=><option key={v.venueId} value={v.venueId}>{v.name} · {v.area}</option>)}</select></label>
    <label>Start<input required type="datetime-local" name="start"/></label>
    <label>Total capacity<input required type="number" name="capacity" min="2" max="100" defaultValue="10"/></label>
    <button disabled={busy}>{busy?'Creating…':'Create game'}</button>
  </form><p role="alert">{error}</p></section>;
}
function MyGames({onSelect}) {
  const [games,setGames]=useState([]),[error,setError]=useState('');
  useEffect(()=>{api('/me/games').then(setGames).catch(e=>setError(e.message));},[]);
  return <section><h2>My games & waitlists</h2><p role="alert">{error}</p><GameCards games={games} onSelect={onSelect}/></section>;
}
function Auth({onLogin}) {
  const [register,setRegister]=useState(false),[message,setMessage]=useState(''),[busy,setBusy]=useState(false);
  async function submit(e){e.preventDefault();setMessage('');setBusy(true);const f=new FormData(e.currentTarget);
    try{const body={email:f.get('email'),password:f.get('password'),displayName:f.get('name')};
      const r=await api(`/auth/${register?'register':'login'}`,'POST',body);
      if(register){setRegister(false);setMessage(r.message);}else {await refreshCsrf();onLogin(r.name);}
    }catch(e){setMessage(e.message);}finally{setBusy(false);}}
  return <section><h2>{register?'Create account':'Sign in'}</h2><form onSubmit={submit}>
    {register && <label>Display name<input required maxLength="80" name="name" autoComplete="nickname"/></label>}
    <label>Email<input required type="email" maxLength="254" name="email" autoComplete="email"/></label>
    <label>Password<input required type="password" name="password" minLength={register?12:1} maxLength="128" autoComplete={register?'new-password':'current-password'}/></label>
    <button disabled={busy}>Continue</button></form><p role="status">{message}</p>
    <button onClick={()=>{setRegister(!register);setMessage('');}}>{register?'Already registered? Sign in':'Create account'}</button></section>;
}
function App(){
  const [page,setPage]=useState('discover'),[id,setId]=useState(null),[name,setName]=useState(null);
  const [lookups,setLookups]=useState({sports:[],venues:[]}),[error,setError]=useState('');
  useEffect(()=>{api('/lookups').then(setLookups).catch(e=>setError(e.message));
    api('/auth/me').then(u=>setName(u.name)).catch(()=>{});},[]);
  function select(id){setId(id);setPage('details');}
  async function logout(){try{await api('/auth/logout','POST');await refreshCsrf();setName(null);setPage('discover');}catch(e){setError(e.message);}}
  return <><header><h1>GameOn</h1><p>Find your people. Play your game.</p><nav>
    <button onClick={()=>setPage('discover')}>Discover</button><button onClick={()=>setPage('host')}>Host a game</button>
    <button onClick={()=>setPage('mine')}>My games</button>{name?<><span>{name}</span><button onClick={logout}>Sign out</button></>:<button onClick={()=>setPage('auth')}>Sign in</button>}
  </nav></header><main><p role="alert">{error}</p>
    {page==='discover' && <Discovery lookups={lookups} onSelect={select}/>}
    {page==='details' && <GameDetails key={id} id={id} onBack={()=>setPage('discover')}/>}
    {page==='host' && <HostForm lookups={lookups} onSelect={select}/>}
    {page==='mine' && <MyGames onSelect={select}/>}
    {page==='auth' && <Auth onLogin={n=>{setName(n);setPage('discover');}}/>}
  </main></>;
}
createRoot(document.getElementById('root')).render(<App/>);
