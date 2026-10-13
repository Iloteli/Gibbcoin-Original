// Erkennt Owner der GibbCoin-Website: Die Website schickt ihr Login-Token (supabaseToken)
// mit; der Node prüft es bei Supabase und liest die Rolle aus.
//   - Eigene Instanz: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
//   - Supabase-Cloud: SUPABASE_URL + SUPABASE_ANON_KEY (öffentlicher Schlüssel). Die Rolle wird dann
//     mit dem Login-Token des Nutzers gelesen – RLS erlaubt jedem, das eigene Profil zu lesen.
export function createWebsiteOwnerCheck({ fetchImpl = globalThis.fetch, env = process.env } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY ?? "";
  const anonKey = env.SUPABASE_ANON_KEY ?? "";
  const apiKey = serviceKey || anonKey;
  const enabled = Boolean(url && apiKey);
  const cache = new Map(); // token -> { session, until }

  return async function websiteOwnerSession(token) {
    if (!enabled || typeof token !== "string" || token.length < 20) return null;
    const cached = cache.get(token);
    if (cached && cached.until > Date.now()) return cached.session;
    let session = null;
    try {
      const userRes = await fetchImpl(`${url}/auth/v1/user`, { headers: { apikey: apiKey, authorization: `Bearer ${token}` } });
      if (userRes.ok) {
        const user = await userRes.json();
        const profRes = await fetchImpl(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=role,username,display_name`, {
          headers: { apikey: apiKey, authorization: `Bearer ${serviceKey || token}` },
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
