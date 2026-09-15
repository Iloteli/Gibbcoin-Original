import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("renders admin control tools once instead of once per operation", async () => {
  const adminOperations = await source("app/components/AdminOperations.tsx");
  assert.equal((adminOperations.match(/className="admin-control-tools"/g) ?? []).length, 1);
  assert.match(adminOperations, /\{operations\.map\(/);
});

test("does not offer an MFA bypass", async () => {
  const [app, challenge] = await Promise.all([
    source("app/components/GibbCoinApp.tsx"),
    source("app/components/MfaChallengePage.tsx"),
  ]);
  assert.doesNotMatch(app, /onSkip/);
  assert.doesNotMatch(challenge, /Ohne Zwei-Faktor-Code fortfahren/);
});

test("reserves session wagers and checks immediate game loss before payout", async () => {
  const migration = await source("supabase/migrations/20260915090000_repair_admin_limits_and_mfa.sql");
  assert.match(migration, /create table if not exists private\.game_loss_reservations/);
  assert.match(migration, /v_daily_loss \+ v_reserved_loss \+ new\.wager/);
  assert.match(migration, /v_loss_increment bigint := greatest\(new\.wager, 0\)/);
  assert.match(migration, /release_game_loss_reservation/);
});

test("shows Dino milestone thresholds in points", async () => {
  const runner = await source("app/components/DinoRunner.tsx");
  assert.match(runner, /\(\(Math\.floor\(score \/ 1000\) \+ 1\) \* 1000\)/);
});
