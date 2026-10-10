// Erkennt Owner der GibbCoin-Website: Die Website schickt ihr Login-Token (supabaseToken)
// mit; der Node prüft es bei der eigenen Supabase-Instanz und liest die Rolle aus.
// Nur aktiv, wenn SUPABASE_URL und SUPABASE_SERVICE_ROLE_KEY gesetzt sind.
export function createWebsiteOwnerCheck({ fetchImpl = globalThis.fetch, env = process.env } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const key = env.SUPABASE_SERVICE_ROLE_KEY ?? "";
  const enabled = Boolean(url && key);
  const cache = new Map(); // token -> { session, until }

  return async function websiteOwnerSession(token) {
    if (!enabled || typeof token !== "string" || token.length < 20) return null;
    const cached = cache.get(token);
    if (cached && cached.until > Date.now()) return cached.session;
    let session = null;
    try {
      const userRes = await fetchImpl(`${url}/auth/v1/user`, { headers: { apikey: key, authorization: `Bearer ${token}` } });
      if (userRes.ok) {
        const user = await userRes.json();
        const profRes = await fetchImpl(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=role,username,display_name`, {
          headers: { apikey: key, authorization: `Bearer ${key}` },
        });
        const [profile] = profRes.ok ? await profRes.json() : [];
        if (profile?.role === "super_admin") {
          session = { address: `sb_${user.id}`, username: profile.username || profile.display_name || "Owner", role: "super_admin" };
        }
      }
    } catch { session = null; }
    cache.set(token, { session, until: Date.now() + 60_000 });
    if (cache.size > 500) cache.delete(cache.keys().next().value);
    return session;
  };
}
