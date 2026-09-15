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

test("ships a server-authoritative wallet Game Center with centralized admin controls", async () => {
  const [dashboard, gameCenter, gameAdminControls, adminPanel, styles, migration, oneCoinMigration, completeMigration, maxWagerMigration, unlimitedWagerMigration, coinLossModeMigration, extrasMigration, plinkoMigration, casinoMigration, upgradeMigration] = await Promise.all([
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/GameCenter.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/GameAdminControls.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260822170000_add_wallet_game_center.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260822180000_allow_one_gibb_game_entry.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824122242_complete_admin_controls_and_poker.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825125502_allow_ten_thousand_gibb_game_wagers.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825130944_remove_game_wager_limit.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825135211_add_visible_coin_flip_loss_mode.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825145050_expand_visual_pranks_and_dino_controls.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260826121128_add_plinko_game.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260827185502_add_casino_games_leaderboards.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260908063951_community_rewards_safety_upgrade.sql", import.meta.url), "utf8"),
  ]);
  assert.match(dashboard, /<GameCenter/);
  assert.match(gameCenter, /Roulette/);
  assert.match(gameCenter, /Münzwurf/);
  assert.match(gameCenter, /Blackjack/);
  assert.match(gameCenter, /Würfelduell/);
  assert.match(gameCenter, /High Card/);
  assert.match(gameCenter, /5-Karten-Poker/);
  assert.match(gameCenter, /title: "Plinko"/);
  assert.match(gameCenter, /function PlinkoBoard/);
  assert.match(gameCenter, /plinko-peg-row/);
  assert.match(gameCenter, /plinkoMultipliers = \[3, 1, 0, 0, 0, 0, 0, 1, 3\]/);
  for (const title of ["Slot Machine", "Baccarat", "Keno", "Glücksrad", "Mines", "Bingo", "Crash"]) assert.match(gameCenter, new RegExp(title));
  assert.match(gameCenter, /play_casino_game/);
  assert.match(gameCenter, /get_game_leaderboard/);
  assert.match(gameCenter, /poker_draw/);
  assert.match(gameCenter, /HALTEN/);
  assert.match(adminPanel, /<GameAdminControls/);
  assert.match(gameAdminControls, /admin_set_game_enabled/);
  assert.match(gameAdminControls, /SPIELVERWALTUNG · NUR ADMINPANEL/);
  assert.doesNotMatch(gameCenter, /admin_set_game_enabled|admin_set_game_visual_prank|admin_set_dino_game_settings|ADMIN-STEUERUNG/);
  assert.match(gameCenter, /postgres_changes/);
  assert.match(gameCenter, /activeRoundRef/);
  assert.match(gameCenter, /visibleGames\.map/);
  assert.match(gameCenter, /pendingLiveRefreshRef/);
  assert.match(gameCenter, /Aktuell sind keine Spiele aktiv/);
  assert.match(gameCenter, /Einziges GIBB Wallet/);
  assert.match(gameCenter, /kein separates Spielkonto/i);
  assert.doesNotMatch(gameCenter, /MAX_GAME_WAGER/);
  assert.match(gameCenter, /const wagers = \[1,/);
  assert.match(gameCenter, /Math\.max\(Math\.floor\(currentBalance\), 0\)/);
  assert.match(gameCenter, /All-in · \{allInWager\.toLocaleString\("de-CH"\)\}/);
  assert.doesNotMatch(gameCenter, /currentBalance < wager\}/);
  assert.match(gameCenter, /Eigener Einsatz · persönliche Limits gelten/);
  assert.doesNotMatch(gameCenter, /1%-GEWINNMODUS AKTIV/);
  assert.match(gameAdminControls, /Gewinnchancen bleiben fest und für alle gleich/);
  assert.match(gameAdminControls, /get_dino_admin_state/);
  assert.doesNotMatch(gameAdminControls, /prank|Nur eine Person|admin_set_game_visual_prank/i);
  assert.doesNotMatch(gameCenter, /get_effective_visual_pranks|play_visual_prank_game|visual_prank/i);
  assert.match(gameCenter, /type="number" inputMode="numeric" min=\{1\} step=\{1\}/);
  assert.doesNotMatch(gameCenter, /id="game-wager"[^>]* max=/);
  assert.match(gameCenter, /game-ambient/);
  assert.match(gameCenter, /game-marquee/);
  assert.match(gameCenter, /stage-particles/);
  assert.match(gameCenter, /stage-energy/);
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
  assert.match(unlimitedWagerMigration, /check \(wager >= 0\)/);
  assert.match(unlimitedWagerMigration, /check \(wager > 0\)/);
  assert.match(unlimitedWagerMigration, /check \(payout >= 0\)/);
  assert.match(unlimitedWagerMigration, /replace\(v_definition, ' or p_wager > 10000', ''\)/);
  assert.match(coinLossModeMigration, /create table if not exists private\.coin_flip_prank_settings/);
  assert.match(coinLossModeMigration, /private\.game_random\(100\) < v_prank_win_chance/);
  assert.match(coinLossModeMigration, /case p_choice when 'kopf' then 'zahl' else 'kopf' end/);
  assert.match(coinLossModeMigration, /case private\.game_random\(2\) when 0 then 'kopf' else 'zahl' end/);
  assert.match(coinLossModeMigration, /'balance', v_wallet\.balance/);
  assert.match(coinLossModeMigration, /'entry_transaction_id', null, 'reward_transaction_id', null/);
  assert.match(coinLossModeMigration, /create or replace function public\.admin_set_coin_flip_prank/);
  assert.match(coinLossModeMigration, /private\.require_admin\(\)/);
  assert.match(coinLossModeMigration, /private\.check_admin_pin/);
  assert.match(extrasMigration, /create table private\.game_prank_settings/);
  for (const gameKey of ["roulette", "coin_flip", "blackjack", "dice_duel", "high_card", "poker"]) {
    assert.match(extrasMigration, new RegExp(`'${gameKey}'`));
  }
  assert.doesNotMatch(extrasMigration.match(/create table private\.game_prank_settings[\s\S]*?\);/)?.[0] ?? "", /dino_run/);
  assert.match(extrasMigration, /p_scope is null or p_scope not in \('all', 'user'\)/);
  assert.match(extrasMigration, /target_user_not_found/);
  assert.match(extrasMigration, /create or replace function public\.play_visual_prank_game/);
  const visualFunction = extrasMigration.match(/create or replace function public\.play_visual_prank_game[\s\S]*?\$\$;/)?.[0] ?? "";
  assert.match(visualFunction, /'visual_only', true/);
  assert.doesNotMatch(visualFunction, /update public\.wallets|private\.append_transaction|insert into public\.game_rounds/);
  assert.match(plinkoMigration, /insert into public\.game_settings[\s\S]*'plinko', 'Plinko', true, 70/);
  assert.match(plinkoMigration, /v_plinko_slot := private\.game_random\(9\)/);
  assert.match(plinkoMigration, /v_payout := p_wager \* v_plinko_multiplier/);
  assert.match(plinkoMigration, /Game Center · ' \|\| v_label \|\| ' · Einsatz/);
  assert.match(plinkoMigration, /grant execute on function public\.play_instant_game/);
  const plinkoVisualFunction = plinkoMigration.match(/create or replace function public\.play_visual_prank_game[\s\S]*?\$\$;/)?.[0] ?? "";
  assert.match(plinkoVisualFunction, /'visual_only', true/);
  assert.doesNotMatch(plinkoVisualFunction, /update public\.wallets|private\.append_transaction|insert into public\.game_rounds/);
  assert.match(styles, /\.game-theme-plinko/);
  assert.match(styles, /@keyframes plinko-drop/);
  assert.match(styles, /@keyframes stage-charge/);
  assert.match(styles, /@keyframes loss-reveal/);
  assert.match(styles, /prefers-reduced-motion[\s\S]*\.plinko-ball/);
  assert.match(styles, /\.game-leaderboard/);
  assert.match(styles, /\.slot-reels/);
  assert.match(casinoMigration, /create table if not exists public\.game_leaderboard/);
  assert.match(casinoMigration, /create or replace function public\.get_game_leaderboard/);
  assert.match(casinoMigration, /create or replace function public\.play_casino_game/);
  for (const gameKey of ["slots", "baccarat", "keno", "wheel", "mines", "bingo", "crash"]) assert.match(casinoMigration, new RegExp(`'${gameKey}'`));
  assert.doesNotMatch(gameCenter, /Math\.random/);
  assert.match(upgradeMigration, /update private\.coin_flip_prank_settings set enabled = false/);
  assert.match(upgradeMigration, /revoke all on function public\.play_visual_prank_game/);
  assert.match(upgradeMigration, /create or replace function public\.get_my_player_safety/);
});

test("ships Dino Run with a 150 GIBB entry, server-paid milestones, and a verified leaderboard", async () => {
  const [gameCenter, gameAdminControls, runner, migration, entryMigration, startingBalance, login, extrasMigration, leaderboardMigration, styles] = await Promise.all([
    readFile(new URL("../app/components/GameCenter.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/GameAdminControls.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/DinoRunner.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824125717_add_dino_run_rewards.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825063808_charge_dino_run_entry.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260824125832_set_starting_balance_to_ten.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/components/LoginPage.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825145050_expand_visual_pranks_and_dino_controls.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260827132028_add_dino_run_leaderboard.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
  ]);
  assert.match(gameCenter, /Dino Run/);
  assert.match(gameCenter, /1’000 Punkte = 100 GIBB/);
  assert.match(gameCenter, /const DINO_ENTRY_COST = 150/);
  assert.match(gameCenter, /Dino Run starten · \$\{DINO_ENTRY_COST\} GIBB/);
  assert.match(gameCenter, /start_dino_run/);
  assert.match(gameCenter, /sync_dino_run/);
  assert.match(gameCenter, /get_dino_leaderboard/);
  assert.match(gameCenter, /Dino Run Leaderboard/);
  assert.match(gameCenter, /Pro Person zählt der beste serverbestätigte Lauf/);
  assert.match(runner, /<canvas/);
  assert.match(runner, /playedSeconds \* 50/);
  assert.match(runner, /Math\.floor\(currentScore \/ 1000\)/);
  assert.match(runner, /const BASE_SPEED = 280/);
  assert.match(runner, /const JUMP_VELOCITY = -615/);
  assert.match(runner, /currentScore \/ SPEED_SCORE_DIVISOR/);
  assert.match(runner, /const speedMultiplier = 1 \+ \(safeSpeedLevel - 1\) \* 0\.16/);
  assert.match(runner, /Math\.max\(175, 305 - difficultyBonus - Math\.floor\(currentScore \/ 35\)\)/);
  assert.match(runner, /safeDifficultyLevel - 1/);
  assert.match(runner, /Schwierigkeit: \{Math\.max/);
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
  assert.match(gameAdminControls, /admin_set_dino_game_settings/);
  assert.match(gameAdminControls, /Geschwindigkeit <b>\{dinoSetting\.speed_level\}\/5/);
  assert.match(gameAdminControls, /Schwierigkeit <b>\{dinoSetting\.difficulty_level\}\/5/);
  assert.match(extrasMigration, /create table private\.dino_game_settings/);
  assert.match(extrasMigration, /add column speed_level/);
  assert.match(extrasMigration, /add column difficulty_level/);
  assert.match(leaderboardMigration, /create index if not exists dino_run_finished_score_idx/);
  assert.match(leaderboardMigration, /create or replace function public\.get_dino_leaderboard\(\)/);
  assert.match(leaderboardMigration, /where d\.status = 'finished'/);
  assert.match(leaderboardMigration, /row_number\(\) over \(order by b\.score desc/);
  assert.match(leaderboardMigration, /coalesce\(nullif\(p\.username, ''\)/);
  assert.match(leaderboardMigration, /revoke all on function public\.get_dino_leaderboard\(\)/);
  assert.match(leaderboardMigration, /grant execute on function public\.get_dino_leaderboard\(\) to authenticated/);
  assert.match(styles, /\.dino-leaderboard/);
  assert.match(styles, /@keyframes dino-leaderboard-in/);
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

test("reserves account bans and Owner deletion for Robyn as primary Owner", async () => {
  const [adminPanel, migration, statusFunction, deletionFunction] = await Promise.all([
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260901071439_restrict_account_management_to_primary_owner.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/functions/admin-account-status/index.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/functions/owner-delete-account/index.ts", import.meta.url), "utf8"),
  ]);
  assert.match(migration, /create or replace function private\.is_primary_owner/);
  assert.match(migration, /d465d88f-0acb-4bff-ad55-945761acaeea/);
  assert.match(migration, /primary_owner_required/);
  assert.match(migration, /target_role in \('user', 'admin', 'super_admin'\)/);
  assert.match(migration, /v_target_role = 'super_admin' and not v_actor_is_primary_owner/);
  assert.match(statusFunction, /caller\.role === "super_admin" && !callerIsPrimaryOwner/);
  assert.match(deletionFunction, /actorProfile\.role === "super_admin" && !actorIsPrimaryOwner/);
  assert.match(adminPanel, /const PRIMARY_OWNER_USER_ID = "d465d88f-0acb-4bff-ad55-945761acaeea"/);
  assert.match(adminPanel, /currentRole === "super_admin" && currentUserId === PRIMARY_OWNER_USER_ID/);
  assert.doesNotMatch(adminPanel, /get_my_admin_account_capabilities/);
  assert.match(adminPanel, /Nur Haupt-Owner Robyn darf Konten bannen/);
  assert.match(adminPanel, /isPrimaryOwner \|\| \(currentRole === "admin" && item\.role === "user"\)/);
  assert.match(adminPanel, /Haupt-Owner Robyn aktiv/);
  assert.match(adminPanel, /Jetzt bannen/);
  assert.match(adminPanel, /function openAccountStatusChange/);
  assert.match(adminPanel, /statusTarget && <div className="modal-backdrop"/);
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
  const [manifest, worker, layout, serviceWorkerRegistration] = await Promise.all([
    readFile(new URL("../public/manifest.json", import.meta.url), "utf8"),
    readFile(new URL("../public/sw.js", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ServiceWorkerRegistration.tsx", import.meta.url), "utf8"),
  ]);
  const parsed = JSON.parse(manifest);
  assert.equal(parsed.display, "standalone");
  assert.equal(parsed.prefer_related_applications, false);
  assert.ok(parsed.icons.some((icon) => icon.sizes === "192x192" && icon.type === "image/png"));
  assert.ok(parsed.icons.some((icon) => icon.sizes === "512x512" && icon.type === "image/png"));
  assert.match(worker, /CACHE_NAME/);
  assert.match(worker, /icon-192\.png/);
  assert.match(worker, /icon-512\.png/);
  assert.match(layout, /<ServiceWorkerRegistration \/>/);
  assert.match(serviceWorkerRegistration, /navigator\.serviceWorker\.register\("\/sw\.js", \{ scope: "\/" \}\)/);
});

test("ships premium layout-preserving motion with reduced-motion support", async () => {
  const styles = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  assert.match(styles, /Premium motion system — visual-only, layout-preserving/);
  assert.match(styles, /--motion-fast: 180ms/);
  assert.match(styles, /--motion-normal: 300ms/);
  assert.match(styles, /--motion-slow: 480ms/);
  assert.match(styles, /@keyframes premium-view-enter/);
  assert.match(styles, /@keyframes premium-modal-in/);
  assert.match(styles, /@keyframes premium-toast-in/);
  assert.match(styles, /@keyframes premium-error-shake/);
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\)[\s\S]*animation-duration: \.01ms !important/);
  assert.match(styles, /@keyframes wallet-scan[\s\S]*translateX\(543%\)/);
  assert.match(styles, /@keyframes play-shimmer[\s\S]*translateX\(472%\)/);

  // Jede Modal-Art wird animiert, nicht nur der PIN-Dialog.
  assert.match(styles, /\.modal-backdrop > \.public-profile-modal \{\s*\n\s*animation: premium-modal-in/);

  // Die Sektionen, die bisher ohne Auftritt erschienen.
  assert.match(styles, /\.profile-editor, \.safety-panel, \.send-card, \.rewards-hub, \.game-center, \.offline-placeholder/);

  // Gestaffelter Auftritt der Home-Kacheln statt gleichzeitigem Einblenden.
  assert.match(styles, /\.overview-grid > \.stat-card:nth-of-type\(2\) \{ animation-delay: 120ms; \}/);
  assert.match(styles, /\.overview-grid > \.stat-card:nth-of-type\(3\) \{ animation-delay: 165ms; \}/);

  // Die zuletzt ergaenzten Bedienelemente bewegen sich wie der Rest.
  assert.match(styles, /\.home-stats-reset,\n\.admin-access-actions,\n\.mfa-skip \{/);
  assert.match(styles, /\.home-stats-note \{\s*\n\s*animation: premium-success-in/);
  assert.match(styles, /\.home-stats-note\.error \{\s*\n\s*animation: premium-error-shake/);
  assert.match(styles, /\.field-hint \{\s*\n\s*animation: premium-row-enter/);
  assert.match(styles, /\.home-shortcuts button:hover,\n\s*\.home-stats-reset:hover \{/);
});

test("unlocks the Admin panel once per visit without persisting the PIN", async () => {
  const [dashboard, adminPanel, gameAdminControls, migration] = await Promise.all([
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/GameAdminControls.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260826164000_add_admin_panel_pin_session_check.sql", import.meta.url), "utf8"),
  ]);
  assert.match(dashboard, /activeView === "admin" && <AdminPanel/);
  assert.match(adminPanel, /admin_verify_pin/);
  assert.match(adminPanel, /setAdminSessionPin\(entryPin\)/);
  assert.match(adminPanel, /p_pin: adminSessionPin/);
  assert.match(adminPanel, /Die Freigabe gilt nur, solange du im Adminpanel bleibst/);
  assert.doesNotMatch(adminPanel, /id="delete-account-pin"|statsResetPin|pinPromptOpen/);
  assert.match(gameAdminControls, /adminPin: string/);
  assert.match(gameAdminControls, /Gilt bis du den Admin-Tab verlässt/);
  assert.doesNotMatch(gameAdminControls, /setAdminPin|Für jede Änderung erneut eingeben/);
  assert.match(migration, /create or replace function public\.admin_verify_pin\(p_pin text\)/);
  assert.match(migration, /private\.check_admin_pin\(v_admin_user_id, p_pin\)/);
  assert.match(migration, /private\.assert_mfa_if_enrolled/);
  assert.match(migration, /grant execute on function public\.admin_verify_pin\(text\) to authenticated/);
  assert.doesNotMatch(migration, /insert into|update public|create table/);
});

test("keeps demo admin and owner badges visual-only", async () => {
  const [adminPanel, dashboard, types, styles, migration] = await Promise.all([
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/lib/types.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260827141734_add_visual_demo_roles.sql", import.meta.url), "utf8"),
  ]);
  assert.match(adminPanel, /Fun-Ränge sind nur visuell und geben niemals Rechte/);
  assert.match(adminPanel, /admin_set_visual_role/);
  assert.match(adminPanel, /Dies ändert keine echten Rollen oder Rechte/);
  assert.match(dashboard, /get_my_visual_role/);
  assert.match(dashboard, /Owner 1 · nur Anzeige/);
  assert.match(types, /visual_role\?: "demo_admin" \| "demo_owner" \| null/);
  assert.match(styles, /\.admin-badge\.visual-role-demo/);
  assert.match(styles, /\.visual-role-badge/);
  assert.match(migration, /create table if not exists private\.visual_demo_roles/);
  assert.match(migration, /never grant permissions/);
  assert.match(migration, /private\.require_admin\(\)/);
  assert.match(migration, /revoke all on function public\.admin_set_visual_role/);
  assert.match(migration, /grant execute on function public\.admin_set_visual_role\(uuid, text, text\) to authenticated/);
  assert.doesNotMatch(migration, /update public\.profiles|insert into public\.profiles/);
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
  assert.match(login, /const EMAIL_RATE_LIMIT_COOLDOWN_MS = 60_000/);
  assert.match(login, /cooldownUntil - Date\.now\(\) > EMAIL_RATE_LIMIT_COOLDOWN_MS/);
  assert.match(login, /Der E-Mail-Versand war kurz ausgelastet/);
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
  assert.match(mfa, /Zwei-Faktor-Bestätigung ist für privilegierte Aktionen erforderlich/);
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

test("shows the admin access dialog at the top of the screen", async () => {
  const [styles, adminPanel] = await Promise.all([
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
  ]);

  // Der Dialog haengt am oberen Rand, damit die Tastatur ihn nicht verdeckt.
  assert.match(adminPanel, /className="modal-backdrop admin-access-backdrop"/);
  assert.match(styles, /\.admin-access-backdrop \{\s*\n\s*align-items: start;/);
  assert.match(styles, /\.admin-access-backdrop > \.pin-modal \{\s*\n\s*margin-top: max\(12px, env\(safe-area-inset-top\)\);/);
  assert.match(styles, /\.admin-access-backdrop > \.pin-modal[\s\S]*transform-origin: top center;/);

  // Ein zu hoher Dialog bleibt scrollbar statt abgeschnitten.
  assert.match(styles, /\.admin-access-backdrop \{[\s\S]*overflow-y: auto;/);

  // Die uebrigen Dialoge bleiben mittig.
  assert.match(styles, /\.modal-backdrop \{ position: fixed; inset: 0; z-index: 80; display: grid; place-items: center;/);
});

test("detects the device and adapts the layout for phones", async () => {
  const [layout, deviceClass, styles] = await Promise.all([
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/DeviceClass.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
  ]);

  // Ohne viewportFit bleibt env(safe-area-inset-*) auf iPhones bei 0.
  assert.match(layout, /viewportFit: "cover"/);
  assert.match(layout, /width: "device-width"/);
  assert.match(layout, /initialScale: 1/);
  assert.match(layout, /<DeviceClass \/>/);

  // Erkennung kombiniert Browser-Hinweis, Zeigegeraet und Breite.
  assert.match(deviceClass, /userAgentData\?\.mobile/);
  assert.match(deviceClass, /matchMedia\("\(pointer: coarse\)"\)/);
  assert.match(deviceClass, /navigator\.maxTouchPoints/);
  assert.match(deviceClass, /root\.dataset\.device = device/);
  assert.match(deviceClass, /display-mode: standalone/);
  assert.match(deviceClass, /orientationchange/);

  // Die Hoehe folgt dem sichtbaren Bereich statt der ausfahrenden Adressleiste.
  assert.match(styles, /\.app-shell \{ min-height: 100vh; min-height: 100dvh;/);
  assert.match(styles, /\.auth-page, \.loading-page \{ min-height: 100vh; min-height: 100dvh;/);

  // Sichere Bereiche und Fingerbedienung.
  assert.match(styles, /\.header \{ padding-top: env\(safe-area-inset-top\); \}/);
  assert.match(styles, /@media \(pointer: coarse\)[\s\S]*min-height: 44px/);
  assert.match(styles, /@media \(pointer: coarse\)[\s\S]*font-size: 16px/);
  assert.match(styles, /:root\[data-device="mobile"\]/);
  assert.match(styles, /:root\[data-standalone="true"\]/);
  assert.match(styles, /overscroll-behavior-y: contain/);
  assert.match(styles, /-webkit-tap-highlight-color: transparent/);
});

test("requires two factor confirmation for privileged actions", async () => {
  const [app, challenge, migration] = await Promise.all([
    readFile(new URL("../app/components/GibbCoinApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/MfaChallengePage.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260909180000_make_admin_mfa_optional.sql", import.meta.url), "utf8"),
  ]);

  // Die Challenge darf nicht umgangen werden.
  assert.doesNotMatch(app, /onSkip/);
  assert.doesNotMatch(challenge, /onSkip|Ohne Zwei-Faktor-Code fortfahren/);

  // Die neue additive Migration erzwingt AAL2 bei verifiziertem Faktor.
  assert.match(migration, /create or replace function private\.assert_mfa_if_enrolled/);
  assert.match(migration, /raise exception 'mfa_required'/);
  assert.doesNotMatch(migration, /values \('require_admin_mfa', false\)/);

  // Die Identitaetspruefung und die Faktor-Logik bleiben erhalten.
  assert.match(migration, /raise exception 'authentication_required'/);
  assert.match(migration, /raise exception 'mfa_required'/);
  assert.match(migration, /from auth\.mfa_factors f/);
});

test("keeps the admin panel reachable when a single admin query fails", async () => {
  const [adminPanel, styles] = await Promise.all([
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
  ]);

  // Frueher blockierte jeder Fehlschlag den Zugang: pinStatus blieb null und
  // das Lade-Modal verdeckte die Meldung dauerhaft.
  assert.doesNotMatch(adminPanel, /if \(usersError \|\| pinStatusError \|\| statsError \|\| visualRolesError \|\| accountLocksError\) \{/);
  assert.match(adminPanel, /const loadFailure = usersError \?\? pinStatusError \?\? statsError \?\? visualRolesError \?\? accountLocksError;/);
  assert.match(adminPanel, /if \(pinStatusError\) \{ setPinUnavailable\(true\); return; \}/);
  assert.match(adminPanel, /setPinUnavailable\(false\);/);

  // Scheitert die PIN-Abfrage selbst, gibt es einen Ausweg statt eines Spinners.
  assert.match(adminPanel, /adminAccessPending \? pinUnavailable \?/);
  assert.match(adminPanel, /Erneut versuchen/);
  assert.match(adminPanel, /Zurück zum Wallet/);
  assert.match(styles, /\.admin-access-actions \{/);
});

test("lets every user reset the home wallet statistics without touching the ledger", async () => {
  const [dashboard, styles, migration] = await Promise.all([
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260909120000_add_home_wallet_stats_reset.sql", import.meta.url), "utf8"),
  ]);

  // Die Home-Statistik zaehlt nur Buchungen ab dem gespeicherten Reset-Zeitpunkt.
  assert.match(dashboard, /supabase\.rpc\("my_wallet_stats_reset"\)/);
  assert.match(dashboard, /supabase\.rpc\("reset_my_wallet_stats"\)/);
  assert.match(dashboard, /\[statsResetAt, setStatsResetAt\] = useState<string \| null>\(null\)/);
  assert.match(dashboard, /const since = statsResetAt \? new Date\(statsResetAt\)\.getTime\(\) : null;/);
  assert.match(dashboard, /new Date\(tx\.created_at\)\.getTime\(\) >= since/);
  assert.match(dashboard, /Statistik zurücksetzen/);
  assert.match(dashboard, /home-stats-reset/);
  // Fehlt die Migration, wird der Button gesperrt statt eine irrefuehrende Meldung zu zeigen.
  assert.match(dashboard, /error\?\.code === "PGRST202"/);
  // Fehlt die Migration, weicht der Reset auf den Browser-Speicher aus statt zu scheitern.
  assert.match(dashboard, /const statsResetKey = \(userId: string\) => `gibb-stats-reset:\$\{userId\}`;/);
  assert.match(dashboard, /writeLocalStatsReset\(user\.id, localSince\)/);
  assert.match(dashboard, /statsRpcMissing \? readLocalStatsReset\(user\.id\) : null/);
  assert.match(dashboard, /nur in diesem Browser/);
  assert.doesNotMatch(dashboard, /Die Statistik konnte gerade nicht zurückgesetzt werden/);
  assert.doesNotMatch(dashboard, /statsResetReady/);
  assert.match(styles, /\.home-stats-reset \{/);

  // Der Reset speichert nur eine Zeitmarke pro Benutzer und bleibt damit rein visuell.
  assert.match(migration, /create table if not exists private\.wallet_stats_resets/);
  assert.match(migration, /create or replace function public\.my_wallet_stats_reset\(\)/);
  assert.match(migration, /create or replace function public\.reset_my_wallet_stats\(\)/);
  assert.match(migration, /private\.require_active_user\(\)/);
  assert.match(migration, /revoke all on table private\.wallet_stats_resets/);
  assert.match(migration, /grant execute on function public\.reset_my_wallet_stats\(\)/);
  assert.doesNotMatch(migration, /delete from public\.transactions/);
  assert.doesNotMatch(migration, /update public\.wallets/);
});

test("lets every user pick their own username in the profile tab", async () => {
  const [profileEditor, dashboard, types, migration] = await Promise.all([
    readFile(new URL("../app/components/ProfileEditor.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/Dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/lib/types.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260909140000_allow_username_change.sql", import.meta.url), "utf8"),
  ]);

  // Der Benutzername ist im Profil-Tab editierbar und wird serverseitig geprueft.
  assert.match(profileEditor, /htmlFor="profile-username"/);
  assert.match(profileEditor, /supabase\.rpc\("set_my_username", \{ p_username: nextUsername \}\)/);
  assert.match(profileEditor, /username_taken/);
  assert.match(profileEditor, /bereits vergeben/);
  assert.match(types, /username\?: string;/);
  assert.match(dashboard, /select\("id,display_name,username,email/);

  // Gleiche Regeln wie bei der Registrierung, Eindeutigkeit case-insensitiv.
  assert.match(migration, /create or replace function public\.set_my_username\(p_username text\)/);
  assert.match(migration, /\^\[a-z0-9\]\[a-z0-9\._-\]\{2,23\}\$/);
  assert.match(migration, /private\.require_active_user\(\)/);
  assert.match(migration, /pg_catalog\.lower\(p\.username\) = v_username/);
  assert.match(migration, /when unique_violation then/);
  assert.match(migration, /grant execute on function public\.set_my_username\(text\)/);
  assert.doesNotMatch(migration, /update public\.wallets/);
  assert.doesNotMatch(migration, /set role =/);
});

test("can protect single accounts from bans and deletion at the database level", async () => {
  const [migration, adminPanel] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260909160000_protect_named_accounts.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/components/AdminPanel.tsx", import.meta.url), "utf8"),
  ]);

  // Der Schutz haengt an der User-ID, nicht am aenderbaren Benutzernamen.
  assert.match(migration, /create table if not exists private\.protected_accounts/);
  assert.match(migration, /user_id uuid primary key references auth\.users\(id\)/);
  assert.doesNotMatch(migration, /profiles\.username/);

  // Bannen wird auf der Tabelle selbst verhindert, Entsperren bleibt erlaubt.
  assert.match(migration, /create trigger protect_account_from_ban\r?\nbefore update on public\.wallets/);
  assert.match(migration, /new\.status = 'locked'\r?\n\s+and old\.status is distinct from 'locked'/);

  // Loeschen wird im bestehenden auth.users-Trigger abgefangen, vor allen anderen Regeln.
  assert.match(migration, /if private\.is_protected_account\(old\.id\) then/);
  assert.match(migration, /account_is_protected/);

  // Die bestehenden Owner-Regeln bleiben erhalten.
  assert.match(migration, /owner_account_is_protected/);
  assert.match(migration, /account_deletion_not_authorized/);
  assert.match(migration, /private\.is_primary_owner\(v_actor_user_id\)/);

  // Die Oberflaeche erklaert beide Faelle.
  assert.match(adminPanel, /dauerhaft geschützt und kann nicht gebannt werden/);
  assert.match(adminPanel, /dauerhaft geschützt und kann nicht gelöscht werden/);
});

test("guards the production Supabase migration workflow behind manual confirmation", async () => {
  const [production, staging, readme, migrationRunner] = await Promise.all([
    readFile(new URL("../.github/workflows/production-supabase.yml", import.meta.url), "utf8"),
    readFile(new URL("../.github/workflows/staging-supabase.yml", import.meta.url), "utf8"),
    readFile(new URL("../README.md", import.meta.url), "utf8"),
    readFile(new URL("../scripts/supabase-management-migrations.mjs", import.meta.url), "utf8"),
  ]);

  // Eine Produktionsmigration darf nie als Nebenwirkung eines Pushes laufen.
  assert.match(production, /on:\s*\n\s*workflow_dispatch:/);
  assert.doesNotMatch(production, /^\s{2}push:/m);
  assert.match(production, /inputs\.confirm \}\}" != "MIGRATE"/);
  assert.match(production, /inputs\.backup_done \}\}" != "true"/);
  assert.match(production, /inputs\.mode \}\}" = "APPLY"/);
  assert.match(production, /inputs\.expected_pending_count/);
  assert.match(production, /environment:\s*\n\s*name: production/);

  // Erst testen, dann per Management API vorschauen, dann mit der bestaetigten
  // Anzahl ausstehender Migrationen anwenden.
  assert.match(production, /pnpm install --frozen-lockfile/);
  assert.match(production, /pnpm lint/);
  assert.match(production, /pnpm test/);
  assert.match(production, /--mode=preview/);
  assert.match(production, /--mode=apply --expected-pending=/);
  assert.match(migrationRunner, /\/database\/migrations/);
  assert.match(migrationRunner, /\/database\/query/);
  assert.match(migrationRunner, /Pending migration count changed/);

  // Der projektgebundene PAT kommt ausschliesslich aus GitHub-Secrets. Weder ein
  // Datenbankpasswort noch API-Schluessel werden fuer die Migration benoetigt.
  assert.match(production, /SUPABASE_ACCESS_TOKEN: \$\{\{ secrets\.SUPABASE_ACCESS_TOKEN \}\}/);
  assert.match(production, /SUPABASE_PROJECT_ID: \$\{\{ secrets\.SUPABASE_PROJECT_ID \}\}/);
  assert.doesNotMatch(production, /SUPABASE_DB_PASSWORD/);
  assert.doesNotMatch(production, /supabase link|supabase@.* link --project-ref/);
  assert.doesNotMatch(production, /--password/);
  assert.doesNotMatch(production, /laduzigqgvvnrqcgfgab/);
  assert.doesNotMatch(migrationRunner, /laduzigqgvvnrqcgfgab/);

  // Der Staging-Workflow bleibt unangetastet und verweigert weiterhin die Produktion.
  assert.match(staging, /Production project refused/);
  assert.match(readme, /production-supabase\.yml/);
});
