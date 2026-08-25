import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request("http://localhost/", { headers: { accept: "text/html" } }), { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } }, { waitUntil() {}, passThroughOnException() {} });
}

test("renders the GIBB Coin application shell", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<title>GIBB Coin/);
  assert.match(html, /GIBB Coin/);
  assert.match(html, /manifest\.json/);
  assert.doesNotMatch(html, /codex-preview/);
});

test("starts transactions and notifications minimized", async () => {
  const [dashboard, notifications] = await Promise.all([
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/NotificationCenter.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(dashboard, /\[transactionsCollapsed, setTransactionsCollapsed\] = useState\(true\)/);
  assert.match(notifications, /\[collapsed, setCollapsed\] = useState\(true\)/);
});

test("ships a server-authoritative wallet Game Center with live admin controls", async () => {
  const [dashboard, gameCenter, migration, oneCoinMigration, completeMigration, maxWagerMigration] = await Promise.all([
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/GameCenter.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260822170000_add_wallet_game_center.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260822180000_allow_one_gibb_game_entry.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824122242_complete_admin_controls_and_poker.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825125502_allow_ten_thousand_gibb_game_wagers.sql", import.meta.url), "utf8"),
  ]);
  assert.match(dashboard, /<GameCenter/);
  assert.match(gameCenter, /Roulette/);
  assert.match(gameCenter, /Münzwurf/);
  assert.match(gameCenter, /Blackjack/);
  assert.match(gameCenter, /Würfelduell/);
  assert.match(gameCenter, /High Card/);
  assert.match(gameCenter, /5-Karten-Poker/);
  assert.match(gameCenter, /poker_draw/);
  assert.match(gameCenter, /HALTEN/);
  assert.match(gameCenter, /admin_set_game_enabled/);
  assert.match(gameCenter, /postgres_changes/);
  assert.match(gameCenter, /activeRoundRef/);
  assert.match(gameCenter, /visibleGames\.map/);
  assert.match(gameCenter, /pendingLiveRefreshRef/);
  assert.match(gameCenter, /Aktuell sind keine Spiele aktiv/);
  assert.match(gameCenter, /Einziges GIBB Wallet/);
  assert.match(gameCenter, /kein separates Spielkonto/i);
  assert.match(gameCenter, /const MAX_GAME_WAGER = 10_000/);
  assert.match(gameCenter, /const wagers = \[1,/);
  assert.match(gameCenter, /Math\.min\(Math\.max\(Math\.floor\(currentBalance\), 0\), MAX_GAME_WAGER\)/);
  assert.match(gameCenter, /All-in · \{allInWager\.toLocaleString\("de-CH"\)\}/);
  assert.doesNotMatch(gameCenter, /currentBalance < wager\}/);
  assert.match(gameCenter, /Eigener Eintritt · 1 bis 10’000/);
  assert.match(gameCenter, /type="number" inputMode="numeric" min=\{1\} max=\{MAX_GAME_WAGER\}/);
  assert.match(gameCenter, /game-ambient/);
  assert.match(gameCenter, /game-marquee/);
  assert.match(gameCenter, /stage-particles/);
  assert.match(gameCenter, /holdAnimation\(1150\)/);
  assert.match(migration, /private\.game_random/);
  assert.match(migration, /for update/);
  assert.match(migration, /GAME_ENTRY/);
  assert.match(migration, /GAME_REWARD/);
  assert.match(migration, /private\.check_admin_pin/);
  assert.match(oneCoinMigration, /wager between 1 and 1000/);
  assert.match(completeMigration, /private\.poker_hand/);
  assert.match(completeMigration, /create table if not exists public\.poker_sessions/);
  assert.match(completeMigration, /GAME_ENTRY/);
  assert.match(completeMigration, /GAME_REWARD/);
  assert.match(maxWagerMigration, /wager between 0 and 10000/);
  assert.match(maxWagerMigration, /wager between 1 and 10000/);
  assert.match(maxWagerMigration, /p_wager > 10000/);
  assert.match(maxWagerMigration, /payout between 0 and 2500000/);
  assert.doesNotMatch(gameCenter, /Math\.random/);
});

test("ships Dino Run with a 150 GIBB entry and one server-paid reward per milestone", async () => {
  const [gameCenter, runner, migration, entryMigration, startingBalance, login] = await Promise.all([
    readFile(new URL("../app/components/GameCenter.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/DinoRunner.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824125717_add_dino_run_rewards.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825063808_charge_dino_run_entry.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824125832_set_starting_balance_to_ten.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/components/LoginPage.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(gameCenter, /Dino Run/);
  assert.match(gameCenter, /1’000 Punkte = 100 GIBB/);
  assert.match(gameCenter, /const DINO_ENTRY_COST = 150/);
  assert.match(gameCenter, /Dino Run starten · \$\{DINO_ENTRY_COST\} GIBB/);
  assert.match(gameCenter, /start_dino_run/);
  assert.match(gameCenter, /sync_dino_run/);
  assert.match(runner, /<canvas/);
  assert.match(runner, /playedSeconds \* 50/);
  assert.match(runner, /Math\.floor\(currentScore \/ 1000\)/);
  assert.match(runner, /const BASE_SPEED = 280/);
  assert.match(runner, /const JUMP_VELOCITY = -615/);
  assert.match(runner, /currentScore \/ SPEED_SCORE_DIVISOR/);
  assert.match(runner, /Math\.max\(235, 305 - Math\.floor\(currentScore \/ 35\)\)/);
  assert.match(runner, /const clustered = nextRandom\(\) > 0\.68/);
  assert.match(runner, /Schwierigkeit: Stufe/);
  assert.match(runner, /Space/);
  assert.doesNotMatch(runner, /Math\.random/);
  assert.match(migration, /create table public\.dino_run_sessions/);
  assert.match(migration, /v_milestones := p_score \/ 1000/);
  assert.match(migration, /v_reward := v_new_milestones::bigint \* 100/);
  assert.match(migration, /dino_run_reward_matches_milestones/);
  assert.match(migration, /dino_score_too_fast/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /GAME_REWARD/);
  assert.match(migration, /enable row level security/);
  assert.match(entryMigration, /v_entry_cost constant bigint := 150/);
  assert.match(entryMigration, /balance = balance - v_entry_cost/);
  assert.match(entryMigration, /'GAME_ENTRY'/);
  assert.match(entryMigration, /'wager', v_session\.wager/);
  assert.match(entryMigration, /'dino_run', 'run', v_session\.wager/);
  assert.match(startingBalance, /values \(new\.id, 10\)/);
  assert.match(login, /Einmalig 10 GIBB Startguthaben/);
});

test("allows protected self-removal, Admin deletion, and resettable personal coin stats", async () => {
  const [adminPanel, migration, deletionFunction] = await Promise.all([
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824122242_complete_admin_controls_and_poker.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/functions/owner-delete-account/index.ts", import.meta.url), "utf8"),
  ]);
  assert.match(adminPanel, /item\.user_id === currentUserId \|\| item\.role !== "super_admin"/);
  assert.match(adminPanel, /admin_coin_stats/);
  assert.match(adminPanel, /admin_reset_coin_stats/);
  assert.match(adminPanel, /Guthaben und Transaktionsverlauf blieben unverändert/);
  assert.match(migration, /create or replace function public\.admin_authorize_account_deletion/);
  assert.match(migration, /create or replace function public\.admin_finalize_account_deletion/);
  assert.match(migration, /'STATS_RESET'/);
  assert.match(migration, /ledger_preserved/);
  assert.doesNotMatch(migration, /cannot_remove_own_coins/);
  assert.match(deletionFunction, /admin_authorize_account_deletion/);
});

test("prevents normal Admins from self-credit while preserving Owner self-credit", async () => {
  const [adminPanel, migration] = await Promise.all([
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825075432_prevent_admin_self_credit.sql", import.meta.url), "utf8"),
  ]);
  assert.match(migration, /p_amount > 0[\s\S]*p_target_user_id = v_admin_user_id[\s\S]*v_admin_role = 'admin'/);
  assert.match(migration, /cannot_credit_own_coins/);
  assert.match(migration, /set search_path = ''/);
  assert.match(migration, /revoke all on function public\.admin_adjust_balance_secure/);
  assert.match(adminPanel, /currentRole === "super_admin" \? filteredUsers : filteredUsers\.filter/);
  assert.match(adminPanel, /Admins dürfen ihrem eigenen Konto keine Coins gutschreiben/);
  assert.match(adminPanel, /Eigengutschriften sind serverseitig gesperrt/);
  assert.match(adminPanel, /currentRole === "super_admin" \? <button[\s\S]*Mir selbst Coins geben/);
  assert.match(adminPanel, /Als Owner darfst du auch deinem eigenen Konto Coins gutschreiben/);
});

test("lets every group member withdraw shared coins only into their own wallet", async () => {
  const [groupWallets, migration] = await Promise.all([
    readFile(new URL("../app/components/GroupWallets.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825104648_allow_group_member_withdrawals.sql", import.meta.url), "utf8"),
  ]);
  assert.match(groupWallets, /withdraw_group_coins/);
  assert.match(groupWallets, /Ins eigene Wallet nehmen/);
  assert.match(groupWallets, /Coins wurden in dein persönliches Wallet gelegt/);
  assert.match(migration, /private\.require_active_user/);
  assert.match(migration, /group_membership_required/);
  assert.match(migration, /for key share/);
  assert.match(migration, /for update/);
  assert.match(migration, /v_group_balance < p_amount/);
  assert.match(migration, /recipient_user_id[\s\S]*v_user_id/);
  assert.match(migration, /revoke all on function public\.withdraw_group_coins/);
  assert.match(migration, /grant execute on function public\.withdraw_group_coins[\s\S]*to authenticated/);
});

test("organizes every feature into a Home-first dashboard without removing sections", async () => {
  const dashboard = await readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8");
  assert.match(dashboard, /type DashboardView = "home"/);
  assert.match(dashboard, /Wallet-Bereiche/);
  assert.match(dashboard, /Was möchtest du machen\?/);
  assert.match(dashboard, /activeView !== "home"/);
  assert.match(dashboard, /activeView !== "send"/);
  assert.match(dashboard, /activeView !== "games"/);
  assert.match(dashboard, /activeView !== "community"/);
  assert.match(dashboard, /activeView !== "activity"/);
  assert.match(dashboard, /activeView !== "account"/);
  assert.match(dashboard, /<QrWallet/);
  assert.match(dashboard, /<PaymentsHub/);
  assert.match(dashboard, /<GroupWallets/);
  assert.match(dashboard, /<AbuseReports/);
  assert.match(dashboard, /<NotificationCenter/);
  assert.match(dashboard, /<PwaInstallCard/);
});

test("closed admin tickets disappear immediately and stay filtered", async () => {
  const reports = await readFile(new URL("../app/components/AbuseReports.tsx", import.meta.url), "utf8");
  assert.match(reports, /visibleAdminReports = adminReports\.filter\(\(report\) => report\.status !== "dismissed"\)/);
  assert.match(reports, /setAdminReports\(\(current\) => current\.filter/);
  assert.match(reports, /Ticket wurde geschlossen und aus der Liste entfernt/);
});

test("keeps the installable app assets available", async () => {
  const [manifest, worker] = await Promise.all([
    readFile(new URL("../public/manifest.json", import.meta.url), "utf8"),
    readFile(new URL("../public/sw.js", import.meta.url), "utf8"),
  ]);
  const parsed = JSON.parse(manifest);
  assert.equal(parsed.display, "standalone");
  assert.match(worker, /CACHE_NAME/);
});

test("hard-deletes accounts so their email can be registered again", async () => {
  const [login, adminPanel, deletionFunction] = await Promise.all([
    readFile(new URL("../app/components/LoginPage.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/functions/owner-delete-account/index.ts", import.meta.url), "utf8"),
  ]);
  assert.match(deletionFunction, /deleteUser\(body\.target_user_id, false\)/);
  assert.match(deletionFunction, /email_reusable: true/);
  assert.match(adminPanel, /E-Mail-Adresse ist sofort wieder/);
  assert.match(login, /Auch nach einer Kontolöschung darfst du dieselbe E-Mail wiederverwenden/);
  assert.match(login, /EMAIL_RATE_LIMIT_COOLDOWN_MS/);
  assert.match(login, /Supabase hat nur sein Bestätigungs-E-Mail-Limit erreicht/);
});

test("creates every new account with a valid unique username and ten starting coins", async () => {
  const migration = await readFile(
    new URL("../supabase/migrations/20260825065459_fix_new_account_username.sql", import.meta.url),
    "utf8",
  );
  assert.match(migration, /insert into public\.profiles \(id, username, display_name, email, avatar_url\)/);
  assert.match(migration, /profiles_username_format_check/);
  assert.match(migration, /profiles_username_lower_unique/);
  assert.match(migration, /when unique_violation then/);
  assert.match(migration, /values \(new\.id, 10\)/);
});

test("persists auth without competing manual refresh calls", async () => {
  const [supabaseClient, login, mfa, app, dashboard, adminSecurity, worker] = await Promise.all([
    readFile(new URL("../app/lib/supabase.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/components/LoginPage.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/MfaChallengePage.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/GibbCoinApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/AdminSecurityCenter.tsx", import.meta.url), "utf8"),
    readFile(new URL("../public/sw.js", import.meta.url), "utf8"),
  ]);
  assert.match(supabaseClient, /persistSession: true/);
  assert.match(supabaseClient, /autoRefreshToken: true/);
  assert.match(supabaseClient, /storageKey: AUTH_STORAGE_KEY/);
  assert.doesNotMatch(supabaseClient, /activeAccessToken|createAuthenticatedFetch|synchronizeSupabaseSession/);
  assert.doesNotMatch(supabaseClient, /global:\s*\{\s*fetch:/);
  assert.doesNotMatch(supabaseClient, /session-diagnostic/);
  assert.match(supabaseClient, /PGRST303/);
  assert.match(`${app}\n${dashboard}`, /waitForSupabaseAuthRetry/);
  assert.match(dashboard, /attempt < 3/);
  assert.doesNotMatch(`${supabaseClient}\n${adminSecurity}`, /auth\.refreshSession\(/);
  assert.doesNotMatch(`${app}\n${dashboard}`, /auth\.signOut\(\)/);
  assert.equal((`${app}\n${dashboard}`.match(/auth\.signOut\(\{ scope: "local" \}\)/g) ?? []).length, 5);
  assert.doesNotMatch(app, /DELETED_NOTICE/);
  assert.match(worker, /client\.navigate\(client\.url\)/);
  assert.match(login, /Angemeldet bleiben ist aktiv/);
  assert.match(mfa, /bleibt die sichere Sitzung in diesem Browser gespeichert/);
});

test("service worker replaces every legacy tab without blocking activation", async () => {
  const workerSource = await readFile(new URL("../public/sw.js", import.meta.url), "utf8");
  const listeners = new Map();
  const deletedCaches = [];
  const navigatedUrls = [];
  let claimed = false;

  runInNewContext(workerSource, {
    URL,
    caches: {
      keys: async () => ["gibb-coin-static-v29", "gibb-coin-static-v30", "gibb-coin-static-v31", "gibb-coin-static-v32"],
      delete: async (key) => { deletedCaches.push(key); return true; },
      open: async () => ({ addAll: async () => undefined, put: async () => undefined }),
      match: async () => undefined,
    },
    self: {
      addEventListener: (type, listener) => listeners.set(type, listener),
      skipWaiting: async () => undefined,
      clients: {
        claim: async () => { claimed = true; },
        matchAll: async () => [
          { url: "https://example.test/", navigate: async (url) => { navigatedUrls.push(url); } },
          { url: "https://example.test/old", navigate: async () => { throw new Error("closed tab"); } },
        ],
      },
      location: { origin: "https://example.test" },
    },
  });

  let activation;
  listeners.get("activate")({ waitUntil: (promise) => { activation = promise; } });
  await activation;

  assert.deepEqual(deletedCaches, ["gibb-coin-static-v29", "gibb-coin-static-v30", "gibb-coin-static-v31", "gibb-coin-static-v32"]);
  assert.equal(claimed, true);
  assert.deepEqual(navigatedUrls, ["https://example.test/"]);
});
