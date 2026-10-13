// Erkennt angemeldete Nutzer der GibbCoin-Website: Die Website schickt ihr Login-Token
// (supabaseToken) mit; der Node prüft es bei Supabase und liest die Rolle aus.
//   - Eigene Instanz: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY
//   - Supabase-Cloud: SUPABASE_URL + SUPABASE_ANON_KEY (öffentlicher Schlüssel). Die Rolle wird dann
//     mit dem Login-Token des Nutzers gelesen – RLS erlaubt jedem, das eigene Profil zu lesen.
export function createWebsiteUserCheck({ fetchImpl = globalThis.fetch, env = process.env } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY ?? "";
  const anonKey = env.SUPABASE_ANON_KEY ?? "";
  const apiKey = serviceKey || anonKey;
  const enabled = Boolean(url && apiKey);
  const cache = new Map(); // token -> { user, until }

  async function websiteUser(token) {
    if (!enabled || typeof token !== "string" || token.length < 20) return null;
    const cached = cache.get(token);
    if (cached && cached.until > Date.now()) return cached.user;
    let result = null;
    try {
      const userRes = await fetchImpl(`${url}/auth/v1/user`, { headers: { apikey: apiKey, authorization: `Bearer ${token}` } });
      if (userRes.ok) {
        const user = await userRes.json();
        const profRes = await fetchImpl(`${url}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=role,username,display_name`, {
          headers: { apikey: apiKey, authorization: `Bearer ${serviceKey || token}` },
        });
        const [profile] = profRes.ok ? await profRes.json() : [];
        if (user?.id) {
          result = { userId: user.id, email: String(user.email ?? "").toLowerCase(), role: profile?.role ?? "user", username: profile?.username || profile?.display_name || "Nutzer" };
        }
      }
    } catch { result = null; }
    cache.set(token, { user: result, until: Date.now() + 60_000 });
    if (cache.size > 500) cache.delete(cache.keys().next().value);
    return result;
  }
  websiteUser.enabled = enabled; // false = Node kennt keine Supabase-Verbindung
  return websiteUser;
}

// Owner-Bereich des Nodes: nur der konfigurierte Owner (Standard: Ilja), und nur mit Rolle super_admin.
export function createWebsiteOwnerCheck(options = {}) {
  const websiteUser = createWebsiteUserCheck(options);
  const ownerEmail = String((options.env ?? process.env).NODE_OWNER_EMAIL ?? "ilja.podorieszach@icloud.com").toLowerCase();
  return async function websiteOwnerSession(token) {
    const user = await websiteUser(token);
    if (user?.role !== "super_admin") return null;
    if (ownerEmail && user.email !== ownerEmail) return null;
    return { address: `sb_${user.userId}`, username: user.username === "Nutzer" ? "Owner" : user.username, role: "super_admin" };
  };
}
