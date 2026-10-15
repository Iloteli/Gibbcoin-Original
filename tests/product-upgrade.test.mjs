import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("ships profiles, rewards, shop, seasons and friends-facing community tools", async () => {
  const [dashboard, profile, rewards, payments, migration] = await Promise.all([
    read("app/components/Dashboard.tsx"), read("app/components/ProfileEditor.tsx"),
    read("app/components/RewardsHub.tsx"), read("app/components/PaymentsHub.tsx"),
    read("supabase/migrations/20260908063951_community_rewards_safety_upgrade.sql"),
  ]);
  assert.match(dashboard, /<ProfileEditor/); assert.match(dashboard, /<RewardsHub/);
  assert.match(profile, /update_my_profile/); assert.match(profile, /storage\.from\("avatars"\)/);
  assert.match(payments, /list_contacts/); assert.match(rewards, /claim_daily_task/);
  assert.match(rewards, /claim_challenge/); assert.doesNotMatch(rewards, /Campus-Shop/);
  assert.match(rewards, /get_season_state/); assert.match(migration, /create table if not exists public\.daily_tasks/);
  assert.match(migration, /create table if not exists public\.daily_rewards/);
  assert.match(migration, /create table if not exists public\.challenges/);
  assert.match(migration, /create table if not exists public\.user_challenges/);
  assert.match(migration, /create table if not exists public\.marketplace_items/);
  assert.match(migration, /create table if not exists public\.purchases/);
  assert.match(migration, /create or replace function public\.claim_daily_reward\(\)/);
  assert.match(migration, /create table if not exists public\.seasons/);
});

test("enforces transparent games, personal protection and period leaderboards", async () => {
  const [game, safety, migration] = await Promise.all([
    read("app/components/GameCenter.tsx"),
    read("app/components/PlayerSafetyPanel.tsx"),
    read("supabase/migrations/20260908063951_community_rewards_safety_upgrade.sql"),
  ]);
  assert.doesNotMatch(game, /play_visual_prank_game|get_effective_visual_pranks/);
  assert.match(game, /Regeln, Chancen &amp; Fairness/); assert.match(game, /fairness_hash/);
  assert.match(game, /p_period: leaderboardPeriod/); assert.match(safety, /update_my_player_safety/);
  assert.match(safety, /start_my_game_break/); assert.match(migration, /daily_loss_limit/);
  assert.match(migration, /revoke all on function public\.play_visual_prank_game/);
});

test("enforces global game limits and opens privacy-safe public user profiles", async () => {
  const [safety, game, dashboard, profileModal, groups, payments, migration] = await Promise.all([
    read("app/components/PlayerSafetyPanel.tsx"),
    read("app/components/GameCenter.tsx"),
    read("app/components/Dashboard.tsx"),
    read("app/components/UserProfileModal.tsx"),
    read("app/components/GroupWallets.tsx"),
    read("app/components/PaymentsHub.tsx"),
    read("supabase/migrations/20260909081539_admin_global_game_limits_and_public_profiles.sql"),
  ]);
  assert.match(safety, /global_max_wager/);
  assert.match(game, /global_wager_limit/);
  assert.match(migration, /create table if not exists private\.global_game_limits/);
  assert.match(migration, /create or replace function private\.enforce_session_safety/);
  assert.match(migration, /create or replace function public\.get_public_user_profile\(p_user_id uuid\)/);
  assert.match(migration, /grant execute on function public\.get_public_user_profile\(uuid\) to authenticated/);
  assert.match(profileModal, /gibb:open-profile/);
  assert.match(profileModal, /Es werden nur öffentliche Profildaten angezeigt/);
  assert.doesNotMatch(profileModal, /\.email|password|admin_pin/);
  assert.match(dashboard, /<UserProfileModal/);
  assert.match(`${game}\n${groups}\n${payments}`, /openUserProfile/);
});

test("ships audit, timed bans, hardened group codes, offline snapshot and transaction exports", async () => {
  const [dashboard, groups, sw, edge, migration, readme, layout, staging] = await Promise.all([
    read("app/components/Dashboard.tsx"),
    read("app/components/GroupWallets.tsx"),
    read("public/sw.js"),
    read("supabase/functions/admin-account-status/index.ts"),
    read("supabase/migrations/20260908063951_community_rewards_safety_upgrade.sql"),
    read("README.md"),
    read("app/layout.tsx"),
    read(".github/workflows/staging-supabase.yml"),
  ]);
  assert.match(dashboard, /gibb-offline-snapshot/); assert.match(dashboard, /CSV exportieren/);
  assert.match(dashboard, /downloadReceipt/);
  assert.match(edge, /duration_minutes/);
  assert.match(groups, /32-stelligen Code/); assert.match(migration, /\^\[A-F0-9\]\{32\}\$/);
  assert.match(migration, /revoke all on function public\.transfer_gibb/);
  assert.match(migration, /auth\.jwt\(\) ->> 'aal'/); assert.match(sw, /request\.mode === "navigate"/);
  assert.doesNotMatch(`${readme}\n${layout}`, /workers\.dev/);
  assert.match(staging, /Production project refused/);
  assert.match(staging, /SUPABASE_DB_PASSWORD/);
});
