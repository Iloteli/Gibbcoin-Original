import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";

import {
  ZERO_HASH, blockHash, blockHeaderString, expectedAttempts, leadingZeroBits,
  meetsDifficulty, merkleRoot, minerWorkerSource, sha256Hex,
} from "../app/lib/blockchain-core.js";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");
const nodeSha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

test("sha256Hex matches Node's crypto for ASCII, UTF-8 and block-boundary lengths", () => {
  const cases = ["", "abc", "GIBB Coin", "ä ö ü € 😀", "x".repeat(55), "x".repeat(56), "x".repeat(63), "x".repeat(64), "x".repeat(65), "y".repeat(1000)];
  for (const value of cases) assert.equal(sha256Hex(value), nodeSha256(value));
});

test("leadingZeroBits counts the proof-of-work measure per nibble", () => {
  assert.equal(leadingZeroBits("ffff"), 0);
  assert.equal(leadingZeroBits("8"), 0);
  assert.equal(leadingZeroBits("4"), 1);
  assert.equal(leadingZeroBits("2"), 2);
  assert.equal(leadingZeroBits("1"), 3);
  assert.equal(leadingZeroBits("0f"), 4);
  assert.equal(leadingZeroBits("0001"), 15);
  assert.equal(leadingZeroBits("0".repeat(64)), 256);
  assert.throws(() => leadingZeroBits("zz"), /invalid_hex/);
  assert.equal(meetsDifficulty("000abc", 12), true);
  assert.equal(meetsDifficulty("000abc", 13), false);
});

test("merkleRoot follows the SQL algorithm (pairwise SHA-256, duplicate odd tail)", () => {
  assert.equal(merkleRoot([]), ZERO_HASH);
  const a = nodeSha256("a"), b = nodeSha256("b"), c = nodeSha256("c");
  assert.equal(merkleRoot([a]), a);
  assert.equal(merkleRoot([a, b]), nodeSha256(a + b));
  assert.equal(merkleRoot([a, b, c]), nodeSha256(nodeSha256(a + b) + nodeSha256(c + c)));
  const many = Array.from({ length: 7 }, (_, index) => nodeSha256(String(index)));
  assert.match(merkleRoot(many), /^[0-9a-f]{64}$/);
  assert.notEqual(merkleRoot(many), merkleRoot(many.slice().reverse()));
});

test("block header and hash use the pipe-separated layout shared with private.block_header", () => {
  const header = {
    height: 7, previous_hash: "a".repeat(64), merkle_root: "b".repeat(64), timestamp: 1_760_000_000,
    difficulty_bits: 20, miner_user_id: "8b0c9d6e-1234-5678-9abc-def012345678", nonce: 42,
  };
  const expected = `7|${"a".repeat(64)}|${"b".repeat(64)}|1760000000|20|8b0c9d6e-1234-5678-9abc-def012345678|42`;
  assert.equal(blockHeaderString(header), expected);
  assert.equal(blockHash(header), nodeSha256(expected));
  assert.equal(blockHeaderString({ ...header, miner_user_id: null }), expected.replace("8b0c9d6e-1234-5678-9abc-def012345678", ""));
  assert.equal(expectedAttempts(16), 65_536);
});

test("the miner worker finds a nonce that the reference implementation accepts", async () => {
  const prefix = `3|${"c".repeat(64)}|${"d".repeat(64)}|1760000000|10|8b0c9d6e-1234-5678-9abc-def012345678|`;
  const messages = [];
  const sandbox = {
    self: {},
    setTimeout: (callback) => { callback(); },
  };
  sandbox.self.postMessage = (message) => messages.push(message);
  runInNewContext(minerWorkerSource(), sandbox);
  sandbox.self.onmessage({ data: { type: "start", prefix, difficultyBits: 10, startNonce: 0 } });
  const found = messages.find((message) => message.type === "found");
  assert.ok(found, "worker reports a found nonce");
  assert.equal(found.hash, nodeSha256(prefix + found.nonce));
  assert.ok(leadingZeroBits(found.hash) >= 10);
  assert.ok(messages.some((message) => message.type === "progress") || found.nonce < 2000);
});

test("ships the blockchain migration, explorer and dashboard wiring", async () => {
  const [migration, explorer, dashboard, types, css] = await Promise.all([
    read("supabase/migrations/20260915090000_add_gibb_blockchain.sql"),
    read("app/components/BlockchainExplorer.tsx"),
    read("app/components/Dashboard.tsx"),
    read("app/lib/types.ts"),
    read("app/globals.css"),
  ]);
  assert.match(migration, /create table if not exists public\.blocks/);
  assert.match(migration, /'MINING_REWARD'/);
  assert.match(migration, /create or replace function private\.merkle_root\(p_hashes text\[\]\)/);
  assert.match(migration, /create or replace function private\.leading_zero_bits\(p_hex text\)/);
  assert.match(migration, /create or replace function public\.get_block_template\(\)/);
  assert.match(migration, /create or replace function public\.submit_mined_block\(/);
  assert.match(migration, /create or replace function public\.verify_blockchain\(\)/);
  assert.match(migration, /create or replace function public\.admin_update_blockchain_settings\(p_value jsonb, p_pin text\)/);
  assert.match(migration, /pg_advisory_xact_lock\(pg_catalog\.hashtext\('gibb_coin_transfer_chain'\)\)/);
  assert.match(migration, /private\.append_transaction\(null, v_user_id, v_reward, 'MINING_REWARD'/);
  assert.match(migration, /revoke all on function public\.submit_mined_block/);
  assert.match(migration, /'BLOCKCHAIN_SETTING_CHANGED'/);
  assert.match(explorer, /supabase\.rpc\("get_block_template"\)/);
  assert.match(explorer, /supabase\.rpc\("submit_mined_block"/);
  assert.match(explorer, /supabase\.rpc\("verify_blockchain"\)/);
  assert.match(explorer, /new Worker\(url\)/);
  assert.match(dashboard, /<BlockchainExplorer/);
  assert.match(dashboard, /key: "chain", label: "Blockchain"/);
  assert.match(dashboard, /MINING_REWARD/);
  assert.match(types, /export type Block = \{/);
  assert.match(css, /\.blockchain-block-head \{/);
});
