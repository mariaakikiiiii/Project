let csrf;
export async function refreshCsrf() {
  const r = await fetch('/api/csrf', {credentials:'same-origin'});
  if (!r.ok) throw new Error('Cannot connect to API.');
  csrf = (await r.json()).token;
}
export async function api(path, method='GET', body) {
  if (method !== 'GET' && !csrf) await refreshCsrf();
  const r = await fetch(`/api${path}`, {method, credentials:'same-origin',
    headers:{...(body ? {'Content-Type':'application/json'} : {}),
      ...(method !== 'GET' ? {'X-CSRF-TOKEN':csrf} : {})},
    body:body ? JSON.stringify(body) : undefined});
  if (!r.ok) {
    const error = await r.json().catch(()=>({}));
    throw new Error(error.error || (r.status === 401 ? 'Sign in to continue.' : `Request failed (${r.status}).`));
  }
  return r.status === 204 ? null : r.json();
}
