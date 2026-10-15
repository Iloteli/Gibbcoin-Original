import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("does not offer an MFA bypass", async () => {
  const [app, challenge] = await Promise.all([
    source("app/components/GibbCoinApp.tsx"),
    source("app/components/MfaChallengePage.tsx"),
  ]);
  assert.doesNotMatch(app, /onSkip/);
  assert.doesNotMatch(challenge, /Ohne Zwei-Faktor-Code fortfahren/);
});

test("reserves session wagers and checks immediate game loss before payout", async () => {
  const migration = await source("supabase/migrations/20260915090100_repair_admin_limits_and_mfa.sql");
  assert.match(migration, /create table if not exists private\.game_loss_reservations/);
  assert.match(migration, /v_daily_loss \+ v_reserved_loss \+ new\.wager/);
  assert.match(migration, /v_loss_increment bigint := greatest\(new\.wager, 0\)/);
  assert.match(migration, /release_game_loss_reservation/);
});

test("shows Dino milestone thresholds in points", async () => {
  const runner = await source("app/components/DinoRunner.tsx");
  assert.match(runner, /\(\(Math\.floor\(score \/ 1000\) \+ 1\) \* 1000\)/);
});

test("releases reservations for terminal blackjack deals", async () => {
  const migration = await source(
    "supabase/migrations/20260915100500_release_terminal_blackjack_reservation.sql",
  );
  assert.match(migration, /drop trigger if exists release_terminal_blackjack_loss_reservation/);
  assert.match(migration, /after insert on public\.blackjack_sessions/);
  assert.match(migration, /for each row when \(new\.status <> 'active'\)/);
  assert.match(
    migration,
    /execute function private\.release_game_loss_reservation\(\);/,
  );
});

test("routes casino games through their authoritative RPC and validates choices", async () => {
  const gameCenter = await source("GameCenter.tsx");
  assert.match(gameCenter, /casinoGameKeys: GameKey\[\] = \["slots", "baccarat", "keno", "wheel", "mines", "bingo", "crash"\]/);
  assert.match(gameCenter, /play_casino_game/);
  assert.match(gameCenter, /picks\.length !== 5/);
  assert.match(gameCenter, /pick < 1 \|\| pick > 40/);
  assert.match(gameCenter, /crashTarget < 1\.1 \|\| crashTarget > 10/);
});
