let csrf;
export async function refreshCsrf() {
  const response = await fetch("/api/csrf", {
    credentials: "same-origin",
    cache: "no-store",
  });
  if (!response.ok) throw new Error("Cannot reach GameOn. Please try again.");
  csrf = (await response.json()).token;
}
export async function api(path, method = "GET", body, options = {}) {
  if (!["GET", "HEAD"].includes(method) && !csrf) await refreshCsrf();
  const response = await fetch(`/api${path}`, {
    method,
    credentials: "same-origin",
    cache: "no-store",
    signal: options.signal,
    headers: {
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(!["GET", "HEAD"].includes(method) ? { "X-CSRF-TOKEN": csrf } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    const error = new Error(
      detail.error ||
        (response.status === 401
          ? "Sign in to continue."
          : response.status === 429
            ? "Too many attempts. Please wait a minute."
            : "Something went wrong. Please try again."),
    );
    error.status = response.status;
    throw error;
  }
  return response.status === 204 ? null : response.json();
}
