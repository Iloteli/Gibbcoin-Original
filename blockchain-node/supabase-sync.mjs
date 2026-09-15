// Spiegelt die Konten der echten GibbCoin-Website (Supabase) automatisch in den
// Blockchain-Node. Braucht den Service-Role-Key des Supabase-Projekts, weil die
// Row-Level-Security das Auflisten aller Nutzer mit dem öffentlichen Schlüssel
// verhindert. Der Key ist ein Geheimnis und wird NICHT im Repository gespeichert.
//
// Konfiguration (eine davon):
//   - Umgebungsvariablen SUPABASE_URL und SUPABASE_SERVICE_ROLE_KEY
//   - Datei blockchain-node/supabase.local.json  (gitignored):
//       { "url": "https://xxxx.supabase.co", "serviceRoleKey": "..." }

import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

export function loadSupabaseConfig() {
  let url = process.env.SUPABASE_URL || "";
  let serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
  const file = join(here, "supabase.local.json");
  if ((!url || !serviceRoleKey) && existsSync(file)) {
    try {
      const raw = JSON.parse(readFileSync(file, "utf8"));
      url = url || raw.url || "";
      serviceRoleKey = serviceRoleKey || raw.serviceRoleKey || raw.service_role_key || "";
    } catch { /* ungültige Datei ignorieren */ }
  }
  return { url: url.replace(/\/$/, ""), serviceRoleKey, configured: Boolean(url && serviceRoleKey) };
}

async function rest(config, path) {
  const res = await fetch(`${config.url}/rest/v1/${path}`, {
    headers: { apikey: config.serviceRoleKey, authorization: `Bearer ${config.serviceRoleKey}`, accept: "application/json" },
  });
  if (!res.ok) throw new Error(`supabase_${res.status}`);
  return res.json();
}

// Holt alle Profile + Wallet-Guthaben und schreibt sie als Blockchain-Konten.
// Rückgabe: { added, updated, total }. Der Node speichert danach (chain.save()).
export async function syncSupabaseAccounts(chain) {
  const config = loadSupabaseConfig();
  if (!config.configured) throw new Error("supabase_not_configured");

  const [profiles, wallets] = await Promise.all([
    rest(config, "profiles?select=id,username,display_name,email"),
    rest(config, "wallets?select=user_id,balance"),
  ]);
  const balanceOf = new Map(wallets.map((w) => [w.user_id, Number(w.balance) || 0]));

  let added = 0;
  let updated = 0;
  for (const profile of profiles) {
    const address = `sb_${profile.id}`; // stabile Adresse = Supabase-Benutzer-ID
    const name = String(profile.username || profile.display_name || profile.email || "Nutzer").slice(0, 40);
    const balance = balanceOf.get(profile.id) ?? 0;
    const existing = chain.accounts[address];
    if (!existing) {
      chain.accounts[address] = {
        name, balance, cash: chain.settings.startingCash, lockedGibb: 0, lockedCash: 0,
        createdAt: Date.now(), source: "supabase", supabaseId: profile.id,
      };
      added += 1;
    } else {
      if (existing.name !== name || existing.balance !== balance) updated += 1;
      existing.name = name;
      existing.balance = balance; // Supabase ist die Wahrheit für gespiegelte Konten
      existing.source = "supabase";
      existing.supabaseId = profile.id;
    }
  }
  chain.save();
  return { added, updated, total: profiles.length, at: Date.now() };
}
