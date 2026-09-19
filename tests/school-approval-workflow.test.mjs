import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("keeps student approval server-authoritative at the inclusive threshold", async () => {
  const migration = await read("supabase/migrations/20260919220000_school_guardian_transfer_approvals.sql");
  assert.match(migration, /p_amount >= v_threshold/);
  assert.match(migration, /create or replace function public\.transfer_coins\([\s\S]*returns uuid/);
  assert.match(migration, /transfer_coins_with_guardian_approval/);
  assert.match(migration, /role = 'user'/);
  assert.match(migration, /status', 'pending'/);
  assert.match(migration, /update public\.wallets set balance = balance - p_amount/);
  assert.match(migration, /private\.append_transaction\(v_sender, p_receiver_user_id/);
});

test("protects guardian approval authorization and rollback paths", async () => {
  const migration = await read("supabase/migrations/20260919220000_school_guardian_transfer_approvals.sql");
  assert.match(migration, /r\.guardian_user_id = v_guardian and r\.status = 'active'/);
  assert.match(migration, /approval_not_found_or_unauthorized/);
  assert.match(migration, /insufficient_balance/);
  assert.match(migration, /status = 'cancelled'/);
  assert.match(migration, /transfer_approval_audit/);
  assert.match(migration, /alter table public\.transfer_approvals force row level security/);
});

test("wires pending, approval, decline, and admin threshold status into the UI", async () => {
  const [dashboard, center, admin] = await Promise.all([
    read("app/components/Dashboard.tsx"),
    read("app/components/TransferApprovalCenter.tsx"),
    read("app/components/AdminOperations.tsx"),
  ]);
  assert.match(dashboard, /TransferApprovalCenter/);
  assert.match(center, /decide_transfer_approval/);
  assert.match(center, /create_guardian_invitation/);
  assert.match(center, /accept_guardian_invitation/);
  assert.match(admin, /admin_set_transfer_threshold/);
});
