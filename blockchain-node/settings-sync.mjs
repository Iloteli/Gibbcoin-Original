// Überträgt die Einstellungen der Chain-Seite auf die Hauptseite (Supabase).
// Nur die Chain-Seite hat Einstellungen; die Hauptseite übernimmt sie über
// public.node_push_settings(key, blockchain, market). Der Schlüssel (NODE_SETTINGS_KEY) wird mit
// "sudo gibb-chain-key" erzeugt und einmal in Supabase hinterlegt.

// Chain-Einstellungen -> Format der Hauptseite. Der Kurs wird nur mitgeschickt, wenn er gesetzt werden soll.
export function buildPushPayload(settings, { price } = {}) {
  const w = settings.website ?? {};
  const blockchain = {
    enabled: w.miningEnabled ?? true,
    reward: settings.reward,
    target_seconds: settings.targetSeconds,
    min_bits: settings.minBits,
    max_bits: settings.maxBits,
    max_tx_per_block: settings.maxTxPerBlock,
    cooldown_seconds: w.cooldownSeconds,
    halving_blocks: w.halvingBlocks,
    max_blocks_per_day: w.maxBlocksPerDay,
    require_real_tx: w.requireRealTx,
  };
  const market = {
    enabled: settings.marketEnabled,
    sell_fee: Number(settings.tradingFeePercent) / 100,
    step: Number(w.marketStepPercent) / 100,
    min_price: w.minPrice,
    max_price: w.maxPrice,
    max_trade: w.maxTrade,
    buy_enabled: w.buyEnabled,
    sell_enabled: w.sellEnabled,
    daily_sell_limit: w.dailySellLimit,
  };
  if (price !== undefined && price !== null && price !== "" && Number.isFinite(Number(price))) market.price = Number(price);
  return { blockchain, market };
}

export function createSettingsSync({ chain, note = () => {}, fetchImpl = globalThis.fetch, env = process.env, intervalMs = 10 * 60_000, accountSyncMs = 30_000, onAccountRemoved = () => {} } = {}) {
  const url = (env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const apiKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_ANON_KEY || "";
  const secret = env.NODE_SETTINGS_KEY ?? "";
  const enabled = Boolean(url && apiKey && secret);
  const state = { enabled, configured: Boolean(url && apiKey), lastPush: null, lastError: enabled ? null : (url && apiKey ? "no_key" : null), lastAccountSync: null, accountSyncError: null, websiteUsers: 0 };

  async function push(options = {}) {
    if (!enabled) return { ok: false, error: state.lastError ?? "not_configured" };
    try {
      const payload = buildPushPayload(chain.settings, options);
      const res = await fetchImpl(`${url}/rest/v1/rpc/node_push_settings`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_blockchain: payload.blockchain, p_market: payload.market }),
      });
      if (!res.ok) throw new Error(`http_${res.status}`);
      const result = await res.json();
      if (!result?.ok) throw new Error(result?.error ?? "push_failed");
      const features = await fetchImpl(`${url}/rest/v1/rpc/node_set_admin_features`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_features: { coin_grants: Boolean(chain.settings.website?.adminCoinGrants) } }),
      });
      if (!features.ok) throw new Error(`admin_features_http_${features.status}`);
      const w = chain.settings.website ?? {};
      const tabs = await fetchImpl(`${url}/rest/v1/rpc/node_set_site_tabs`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_disabled: Array.isArray(w.disabledTabs) ? w.disabledTabs : [] }),
      });
      if (!tabs.ok && tabs.status !== 404) throw new Error(`tabs_http_${tabs.status}`);
      const bank = await fetchImpl(`${url}/rest/v1/rpc/node_set_bank_settings`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_enabled: Boolean(w.bankEnabled), p_iban: w.bankIban ?? "", p_holder: w.bankHolder ?? "" }),
      });
      const card = await fetchImpl(`${url}/rest/v1/rpc/node_set_payment_methods`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_card: Boolean(w.cardEnabled), p_credits: w.creditsEnabled !== false }),
      });
      if (!card.ok && card.status !== 404) throw new Error(`card_http_${card.status}`);
      const design = await fetchImpl(`${url}/rest/v1/rpc/node_set_site_design`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_accent: w.siteAccent ?? "neon", p_mode: w.siteMode ?? "dark", p_motion: w.siteMotion ?? "full", p_style: w.siteStyle ?? "new" }),
      });
      if (!design.ok && design.status !== 404) throw new Error(`design_http_${design.status}`);
      const footer = await fetchImpl(`${url}/rest/v1/rpc/node_set_footer`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_text: typeof w.madeBy === "string" ? w.madeBy : "Made by Ilja" }),
      });
      if (!footer.ok && footer.status !== 404) throw new Error(`footer_http_${footer.status}`);
      const registration = await fetchImpl(`${url}/rest/v1/rpc/node_set_registration`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_enabled: w.registrationEnabled === true }),
      });
      if (!registration.ok && registration.status !== 404) throw new Error(`registration_http_${registration.status}`);
      const address = await fetchImpl(`${url}/rest/v1/rpc/node_set_bank_address`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_street: w.bankStreet ?? "", p_zip: w.bankZip ?? "", p_city: w.bankCity ?? "" }),
      });
      if (address.ok) {
        const addressResult = await address.json();
        if (!addressResult?.ok) throw new Error(addressResult?.error ?? "address_failed");
      } else if (address.status !== 404) throw new Error(`address_http_${address.status}`);
      const levels = await fetchImpl(`${url}/rest/v1/rpc/node_set_owner_levels`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_full: Object.entries(chain.ownerLevels ?? {}).filter(([, level]) => level === "full").map(([id]) => id) }),
      });
      if (!levels.ok && levels.status !== 404) throw new Error(`owner_levels_http_${levels.status}`);
      if (bank.ok) {
        const bankResult = await bank.json();
        if (!bankResult?.ok) throw new Error(bankResult?.error ?? "bank_failed");
      } else if (bank.status !== 404) {
        throw new Error(`bank_http_${bank.status}`);
      }
      if (state.lastError) note("settings", "Einstellungen werden wieder an die Hauptseite übertragen");
      state.lastPush = Date.now();
      state.lastError = null;
      return { ok: true };
    } catch (error) {
      if (state.lastError !== error.message) note("error", `Einstellungen konnten nicht an die Hauptseite übertragen werden: ${error.message}`);
      state.lastError = error.message;
      return { ok: false, error: error.message };
    }
  }

  // Website-Konten 1:1 übernehmen: Name und Guthaben von der Hauptseite, neue Konten anlegen,
  // gelöschte Konten entfernen. Die Hauptseite ist für Website-Konten führend.
  let syncing = false;
  // Benutzernamen der Hauptseite (für eindeutige Namen über beide Websites)
  let websiteNames = new Set();
  const isWebsiteUsername = (name) => websiteNames.has(String(name ?? "").trim().toLowerCase());
  const pushReservedNames = () => rpc("node_set_reserved_usernames", { p_names: Object.keys(chain.users ?? {}) }).catch(() => null);
  async function syncAccounts() {
    if (!enabled || syncing) return { ok: false, removed: 0, updated: 0 };
    syncing = true;
    try {
      const users = await listWebsiteUsers();
      websiteNames = new Set(users.map((u) => String(u.username ?? "").toLowerCase()).filter(Boolean));
      void pushReservedNames();
      const ids = new Set();
      let updated = 0;
      for (const u of users) {
        const id = String(u.id ?? "").toLowerCase();
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) continue;
        ids.add(id);
        const name = String(u.username || u.display_name || "Nutzer");
        const balance = Math.max(0, Math.round(Number(u.balance) || 0));
        const before = chain.accounts[`sb_${id}`];
        if (!before || before.name !== name || before.balance !== balance) {
          chain.upsertWebsiteAccount(id, name, balance, { overwriteBalance: true });
          updated += 1;
        }
        if (chain.setWebsiteLook?.(id, u.avatar_url, u.profile_color, u.avatar_blocked === true)) updated += 1;
      }
      let removed = 0;
      for (const address of Object.keys(chain.accounts)) {
        if (!address.startsWith("sb_") || chain.accounts[address]?.source !== "supabase") continue;
        if (ids.has(address.slice(3).toLowerCase())) continue;
        const name = chain.accounts[address]?.name ?? address;
        if (chain.removeWebsiteAccount(address)) { removed += 1; onAccountRemoved(address); note("wallet", `Gelöschtes Website-Konto entfernt: ${name}`); }
      }
      state.lastAccountSync = Date.now();
      state.accountSyncError = null;
      state.websiteUsers = ids.size;
      return { ok: true, removed, updated };
    } catch (error) {
      if (state.accountSyncError !== error.message) note("error", `Konten-Abgleich mit der Hauptseite fehlgeschlagen: ${error.message}`);
      state.accountSyncError = error.message;
      return { ok: false, removed: 0, updated: 0, error: error.message };
    } finally {
      syncing = false;
    }
  }

  // Gelöschte Website-Konten auch hier entfernen (ältere, schmalere Abfrage).
  async function cleanupAccounts() {
    if (!enabled) return { ok: false, removed: 0 };
    const ids = Object.keys(chain.accounts)
      .filter((a) => a.startsWith("sb_") && chain.accounts[a]?.source === "supabase")
      .map((a) => a.slice(3))
      .filter((id) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id));
    if (!ids.length) return { ok: true, removed: 0 };
    try {
      const res = await fetchImpl(`${url}/rest/v1/rpc/node_existing_users`, {
        method: "POST",
        headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ p_key: secret, p_ids: ids }),
      });
      if (!res.ok) throw new Error(`http_${res.status}`);
      const result = await res.json();
      if (!result?.ok || !Array.isArray(result.existing)) throw new Error(result?.error ?? "invalid_response");
      const existing = new Set(result.existing.map((id) => String(id).toLowerCase()));
      let removed = 0;
      for (const id of ids) {
        if (existing.has(id.toLowerCase())) continue;
        const address = `sb_${id}`;
        const name = chain.accounts[address]?.name ?? id;
        if (chain.removeWebsiteAccount(address)) { removed += 1; onAccountRemoved(address); note("wallet", `Gelöschtes Website-Konto entfernt: ${name}`); }
      }
      return { ok: true, removed };
    } catch (error) {
      note("error", `Abgleich gelöschter Konten fehlgeschlagen: ${error.message}`);
      return { ok: false, removed: 0, error: error.message };
    }
  }


  // Coins der Website-Benutzer verwalten (nur über die Chain-Seite).
  async function rpc(name, body) {
    if (!enabled) throw new Error(state.lastError === "no_key" ? "no_key" : "not_configured");
    const res = await fetchImpl(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ p_key: secret, ...body }),
    });
    if (!res.ok) throw new Error(`http_${res.status}`);
    const result = await res.json();
    if (!result?.ok) throw new Error(result?.error ?? "failed");
    return result;
  }
  const listWebsiteUsers = async () => (await rpc("node_list_users", {})).users ?? [];
  const adjustWebsiteBalance = async (userId, amount, reason) => rpc("node_adjust_balance", { p_user: userId, p_amount: amount, p_reason: reason });
  // Admin-Funktionen der Hauptseite als Owner aufrufen (Ergebnis wie bei supabase.rpc)
  const ownerCall = async (fn, args = {}) => {
    const result = await rpc("node_owner_call", { p_fn: fn, p_args: args });
    const rows = Array.isArray(result.rows) ? result.rows : [];
    // Einfacher Rückgabewert (z. B. jsonb) -> Wert; Tabellen-Funktion -> Liste von Zeilen (wie supabase.rpc)
    return result.table === false ? rows[0] ?? null : rows;
  };
  const setAccountStatus = (userId, status, minutes, reason) => rpc("node_set_account_status", { p_user: userId, p_status: status, p_minutes: minutes ?? null, p_reason: reason ?? null });
  // Profil der Hauptseite (nur das eigene Konto, siehe /api/profile)
  const getProfile = async (userId) => (await rpc("node_get_profile", { p_user: userId })).profile;
  const updateProfile = async (userId, p) => (await rpc("node_update_profile", { p_user: userId, p_username: p.username, p_display_name: p.display_name, p_bio: p.bio, p_profile_color: p.profile_color, p_remove_avatar: p.remove_avatar === true })).profile;
  // E-Mail eines Owners der Hauptseite zu seinem Benutzernamen (für die Anmeldung mit Benutzername)
  const ownerLoginEmail = async (username) => { try { return (await rpc("node_owner_login_email", { p_username: username })).email ?? null; } catch { return null; } };
  const deleteSupportCase = (caseId, pin) => rpc("node_delete_support_case", { p_case: caseId, p_pin: pin });
  const setAvatarBlocked = (userId, blocked) => rpc("node_set_avatar_blocked", { p_user: userId, p_blocked: blocked === true });
  const deleteAccount = (userId, pin) => rpc("node_delete_account", { p_user: userId, p_pin: pin });
  // Alle Sitzungen des Kontos auf der Hauptseite beenden
  const logoutUser = (userId) => rpc("node_logout_user", { p_user: userId });
  async function sendPasswordReset(userId) {
    const auth = await rpc("node_password_reset", { p_user: userId });
    const res = await fetchImpl(`${url}/auth/v1/recover`, {
      method: "POST",
      headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ email: auth.email }),
    });
    if (!res.ok) throw new Error("email_delivery_failed");
    await rpc("node_password_reset", { p_user: userId, p_sent: true });
    return { ok: true, display_name: auth.display_name };
  }
  // Neues Website-Konto anlegen: E-Mail freigeben, dann bei Supabase registrieren (Bestätigungs-E-Mail)
  async function createWebsiteAccount(email, username, password) {
    const allowed = await rpc("node_allow_signup", { p_email: email, p_username: username });
    const res = await fetchImpl(`${url}/auth/v1/signup`, {
      method: "POST",
      headers: { apikey: apiKey, authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ email: allowed.email, password, data: { username: allowed.username, full_name: allowed.username } }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error_code || body?.msg || `signup_http_${res.status}`);
    void syncAccounts();
    return { ok: true, email: allowed.email, username: allowed.username, confirmationSent: !body?.access_token };
  }
  const listVerifiedBuyers = async () => (await rpc("node_list_verified_buyers", {})).ids ?? [];
  const setBuyerVerified = (userId, verified) => rpc("node_set_buyer_verified", { p_user: userId, p_verified: Boolean(verified) });
  const listBankOrders = async () => (await rpc("node_list_bank_orders", {})).orders ?? [];
  const ownerStats = async (days) => rpc("node_owner_stats", { p_days: days });
  const bulkAdjust = async (amount, reason) => rpc("node_bulk_adjust", { p_amount: amount, p_reason: reason });
  const getAnnouncement = async () => (await rpc("node_get_announcement", {})).announcement ?? { enabled: false };
  const setAnnouncement = async (a) => rpc("node_set_announcement", { p_enabled: a.enabled, p_title: a.title, p_message: a.message, p_until: a.until, p_tone: a.tone });
  const getWagerLimits = async () => (await rpc("node_get_game_wager_limits", {})).limits ?? {};
  const setWagerLimits = async (limits) => (await rpc("node_set_game_wager_limits", { p_limits: limits })).limits ?? {};
  const getGameOdds = async () => (await rpc("node_get_game_odds", {})).odds ?? {};
  const setGameOdds = async (odds) => (await rpc("node_set_game_odds", { p_odds: odds })).odds ?? {};
  const deleteBankOrders = async (id) => rpc("node_delete_bank_orders", { p_id: id || null });
  const decideBankOrder = async (id, paid) => rpc("node_decide_bank_order", { p_id: id, p_paid: Boolean(paid) });

  if (enabled) {
    setTimeout(() => { void push(); void syncAccounts(); }, 3000).unref();
    setInterval(() => { void push(); }, intervalMs).unref();
    setInterval(() => { void syncAccounts(); }, accountSyncMs).unref();
  }

  return { isWebsiteUsername, pushReservedNames, ownerLoginEmail, deleteSupportCase, setAvatarBlocked, getProfile, updateProfile, enabled, push, syncAccounts, cleanupAccounts, listWebsiteUsers, adjustWebsiteBalance, listBankOrders, decideBankOrder, deleteBankOrders, getGameOdds, setGameOdds, getWagerLimits, setWagerLimits, ownerStats, bulkAdjust, getAnnouncement, setAnnouncement, ownerCall, setAccountStatus, deleteAccount, logoutUser, sendPasswordReset, createWebsiteAccount, listVerifiedBuyers, setBuyerVerified, status: () => ({ ...state }) };
}
