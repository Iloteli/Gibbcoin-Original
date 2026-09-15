// Eigenständiger GIBB-Blockchain-Node (Testumgebung).
// Nutzt dieselben Formeln wie die App (Header, Merkle-Root, Nullbits),
// hält aber Konten, Mempool und Blöcke lokal in einer JSON-Datei.
// Der Server mined NICHT selbst: Er gibt Blockvorlagen heraus und prüft
// Blöcke, deren Nonce im Browser der Miner gefunden wurde.

import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { ZERO_HASH, blockHeaderString, leadingZeroBits, merkleRoot } from "../app/lib/blockchain-core.js";

const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

export const COINBASE = "COINBASE";

const defaultSettings = {
  reward: 10,
  difficultyBits: 16,
  minBits: 8,
  maxBits: 26,
  targetSeconds: 30,
  autoAdjust: true,
  maxTxPerBlock: 50,
};

export function transactionHash(tx) {
  return sha256(`${tx.id}|${tx.from}|${tx.to}|${tx.amount}|${tx.note}|${tx.timestamp}`);
}

export class Blockchain {
  constructor(file) {
    this.file = file;
    this.blocks = [];
    this.mempool = [];
    this.accounts = {}; // address -> { name, balance, createdAt }
    this.settings = { ...defaultSettings };
    this.templates = new Map(); // ausgegebene Vorlagen (id -> Vorlage), nicht persistiert
    this.load();
  }

  // ---------- Persistenz ----------
  load() {
    if (this.file && existsSync(this.file)) {
      const raw = JSON.parse(readFileSync(this.file, "utf8"));
      this.blocks = raw.blocks ?? [];
      this.mempool = raw.mempool ?? [];
      this.accounts = raw.accounts ?? {};
      this.settings = { ...defaultSettings, ...(raw.settings ?? {}) };
    }
    if (this.blocks.length === 0) this.createGenesis();
  }

  save() {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify({ blocks: this.blocks, mempool: this.mempool, accounts: this.accounts, settings: this.settings }, null, 2));
    renameSync(tmp, this.file);
  }

  reset() {
    this.blocks = [];
    this.mempool = [];
    this.accounts = {};
    this.settings = { ...defaultSettings };
    this.createGenesis();
    this.save();
  }

  // ---------- Blöcke ----------
  createGenesis() {
    const timestamp = Math.floor(Date.now() / 1000);
    const header = { height: 0, previous_hash: ZERO_HASH, merkle_root: ZERO_HASH, timestamp, difficulty_bits: 0, miner_user_id: null, nonce: 0 };
    this.blocks.push({ ...header, hash: sha256(blockHeaderString(header)), transactions: [], miner: null, reward: 0, miner_label: "Genesis" });
  }

  tip() {
    return this.blocks[this.blocks.length - 1];
  }

  currentDifficulty() {
    const s = this.settings;
    if (!s.autoAdjust) return clamp(s.difficultyBits, s.minBits, s.maxBits);
    const mined = this.blocks.filter((b) => b.height > 0).slice(-10);
    let bits = this.tip().height === 0 ? s.difficultyBits : this.tip().difficulty_bits;
    if (mined.length >= 2) {
      const avg = (mined[mined.length - 1].timestamp - mined[0].timestamp) / (mined.length - 1);
      if (avg < s.targetSeconds / 2) bits += 1;
      else if (avg > s.targetSeconds * 2) bits -= 1;
    }
    const stalled = Math.floor((Date.now() / 1000 - this.tip().timestamp) / (s.targetSeconds * 4));
    if (stalled > 0) bits -= stalled;
    return clamp(bits, s.minBits, s.maxBits);
  }

  // Blockvorlage für einen Miner: Belohnung (Coinbase) zuerst, dann Mempool in Eingangsreihenfolge.
  // Die Vorlage bleibt 10 Minuten gültig; der Browser sucht dazu die Nonce.
  issueTemplate(minerAddress) {
    if (!this.accounts[minerAddress]) throw new Error("unknown_miner");
    const tipBlock = this.tip();
    const timestamp = Math.max(Math.floor(Date.now() / 1000), tipBlock.timestamp);
    const coinbase = this.buildTransaction(COINBASE, minerAddress, this.settings.reward, `Block #${tipBlock.height + 1} Belohnung`, timestamp);
    const transactions = [coinbase, ...this.mempool.slice(0, this.settings.maxTxPerBlock)];
    const template = {
      id: randomBytes(8).toString("hex"),
      height: tipBlock.height + 1,
      previous_hash: tipBlock.hash,
      merkle_root: merkleRoot(transactions.map((tx) => tx.hash)),
      timestamp,
      difficulty_bits: this.currentDifficulty(),
      miner_user_id: minerAddress,
      transactions,
      issuedAt: Date.now(),
    };
    template.header_prefix = blockHeaderString({ ...template, nonce: 0 }).slice(0, -1);
    for (const [id, t] of this.templates) if (Date.now() - t.issuedAt > 600_000) this.templates.delete(id);
    this.templates.set(template.id, template);
    return template;
  }

  // Ein Browser meldet eine gefundene Nonce zu einer ausgegebenen Vorlage.
  submit(templateId, nonce, hash, meta = {}) {
    const template = this.templates.get(templateId);
    if (!template) throw new Error("unknown_template");
    nonce = Number(nonce);
    if (!Number.isInteger(nonce) || nonce < 0) throw new Error("invalid_nonce");
    if (typeof hash !== "string" || !/^[0-9a-f]{64}$/.test(hash)) throw new Error("invalid_hash");
    const block = this.acceptBlock({ ...template, nonce, hash }, meta);
    this.templates.delete(templateId);
    return block;
  }

  // Ein gefundener Block wird wie beim Server-Pfad der App vollständig nachgeprüft.
  acceptBlock(candidate, meta = {}) {
    const tipBlock = this.tip();
    if (candidate.height !== tipBlock.height + 1 || candidate.previous_hash !== tipBlock.hash) throw new Error("stale_block");
    const txs = candidate.transactions;
    if (txs.length === 0 || txs[0].from !== COINBASE) throw new Error("missing_coinbase");
    if (txs[0].amount !== this.settings.reward) throw new Error("wrong_reward");
    if (merkleRoot(txs.map((tx) => tx.hash)) !== candidate.merkle_root) throw new Error("merkle_root_mismatch");
    const header = { height: candidate.height, previous_hash: candidate.previous_hash, merkle_root: candidate.merkle_root, timestamp: candidate.timestamp, difficulty_bits: candidate.difficulty_bits, miner_user_id: candidate.miner_user_id, nonce: candidate.nonce };
    if (sha256(blockHeaderString(header)) !== candidate.hash) throw new Error("hash_mismatch");
    if (candidate.difficulty_bits < this.currentDifficulty()) throw new Error("difficulty_too_low");
    if (leadingZeroBits(candidate.hash) < candidate.difficulty_bits) throw new Error("insufficient_work");

    // Kontostände anwenden (Coinbase zuerst, dann alle Transfers).
    for (const tx of txs) {
      if (tx.from !== COINBASE) {
        if ((this.accounts[tx.from]?.balance ?? 0) < tx.amount) throw new Error(`insufficient_funds:${tx.id}`);
        this.accounts[tx.from].balance -= tx.amount;
      }
      this.accounts[tx.to].balance += tx.amount;
    }
    const ids = new Set(txs.map((tx) => tx.id));
    this.mempool = this.mempool.filter((tx) => !ids.has(tx.id));
    const block = { ...header, hash: candidate.hash, transactions: txs, miner: candidate.miner_user_id, miner_label: this.accounts[candidate.miner_user_id]?.name ?? candidate.miner_user_id, reward: this.settings.reward, attempts: Number.isFinite(meta.attempts) ? Math.round(meta.attempts) : null, mining_ms: Number.isFinite(meta.ms) ? Math.round(meta.ms) : null, hashrate: Number.isFinite(meta.hashrate) ? Math.round(meta.hashrate) : null };
    this.blocks.push(block);
    this.save();
    return block;
  }

  // ---------- Konten & Transaktionen ----------
  createWallet(name) {
    const clean = String(name ?? "").trim().slice(0, 40) || `Wallet ${Object.keys(this.accounts).length + 1}`;
    let address;
    do address = `G${randomBytes(6).toString("hex")}`; while (this.accounts[address]);
    this.accounts[address] = { name: clean, balance: 0, createdAt: Date.now() };
    this.save();
    return { address, ...this.accounts[address] };
  }

  buildTransaction(from, to, amount, note = "", timestamp = Math.floor(Date.now() / 1000)) {
    const tx = { id: randomBytes(8).toString("hex"), from, to, amount, note: String(note ?? "").slice(0, 120), timestamp };
    tx.hash = transactionHash(tx);
    return tx;
  }

  // Guthaben abzüglich bereits im Mempool wartender Ausgaben.
  availableBalance(address) {
    const pending = this.mempool.filter((tx) => tx.from === address).reduce((sum, tx) => sum + tx.amount, 0);
    return (this.accounts[address]?.balance ?? 0) - pending;
  }

  addTransaction(from, to, amount, note) {
    amount = Number(amount);
    if (!Number.isInteger(amount) || amount <= 0) throw new Error("invalid_amount");
    if (!this.accounts[from]) throw new Error("unknown_sender");
    if (!this.accounts[to]) throw new Error("unknown_recipient");
    if (from === to) throw new Error("same_account");
    if (this.availableBalance(from) < amount) throw new Error("insufficient_funds");
    const tx = this.buildTransaction(from, to, amount, note);
    this.mempool.push(tx);
    this.save();
    return tx;
  }

  // ---------- Prüfung & Demo ----------
  verify() {
    let expectedPrevious = ZERO_HASH;
    const balances = {};
    for (const block of this.blocks) {
      const fail = (reason) => ({ valid: false, height: block.height, reason });
      if (block.previous_hash !== expectedPrevious) return fail("previous_hash_mismatch");
      const header = { height: block.height, previous_hash: block.previous_hash, merkle_root: block.merkle_root, timestamp: block.timestamp, difficulty_bits: block.difficulty_bits, miner_user_id: block.miner_user_id, nonce: block.nonce };
      if (sha256(blockHeaderString(header)) !== block.hash) return fail("block_hash_mismatch");
      if (leadingZeroBits(block.hash) < block.difficulty_bits) return fail("insufficient_work");
      const expectedMerkle = merkleRoot(block.transactions.map((tx) => tx.hash));
      if (expectedMerkle !== block.merkle_root) return fail("merkle_root_mismatch");
      for (const tx of block.transactions) {
        if (transactionHash(tx) !== tx.hash) return fail(`transaction_hash_mismatch:${tx.id}`);
        if (tx.from !== COINBASE) {
          if ((balances[tx.from] ?? 0) < tx.amount) return fail(`overspend:${tx.id}`);
          balances[tx.from] -= tx.amount;
        }
        balances[tx.to] = (balances[tx.to] ?? 0) + tx.amount;
      }
      expectedPrevious = block.hash;
    }
    for (const [address, account] of Object.entries(this.accounts)) {
      if ((balances[address] ?? 0) !== account.balance) return { valid: false, height: null, reason: `balance_mismatch:${address}` };
    }
    return { valid: true, blocks: this.blocks.length, checkedAt: Date.now() };
  }

  // Für die Demo: einen Betrag in einem alten Block fälschen – die Prüfung muss das erkennen.
  tamper(height) {
    const block = this.blocks.find((b) => b.height === Number(height));
    if (!block) throw new Error("unknown_block");
    const tx = block.transactions.find((t) => t.from !== COINBASE) ?? block.transactions[0];
    if (!tx) throw new Error("block_has_no_transactions");
    tx.amount += 1000;
    this.save();
    return { height: block.height, transaction: tx.id };
  }

  updateSettings(patch) {
    const next = { ...this.settings };
    for (const key of ["reward", "difficultyBits", "minBits", "maxBits", "targetSeconds", "maxTxPerBlock"]) {
      if (patch[key] !== undefined) {
        const value = Number(patch[key]);
        if (!Number.isFinite(value)) throw new Error(`invalid_${key}`);
        next[key] = Math.round(value);
      }
    }
    if (patch.autoAdjust !== undefined) next.autoAdjust = Boolean(patch.autoAdjust);
    next.reward = clamp(next.reward, 0, 10_000);
    next.minBits = clamp(next.minBits, 1, 40);
    next.maxBits = clamp(next.maxBits, next.minBits, 40);
    next.difficultyBits = clamp(next.difficultyBits, next.minBits, next.maxBits);
    next.targetSeconds = clamp(next.targetSeconds, 1, 3600);
    next.maxTxPerBlock = clamp(next.maxTxPerBlock, 1, 1000);
    this.settings = next;
    this.save();
    return next;
  }

  stats() {
    const mined = this.blocks.filter((b) => b.height > 0);
    const last = mined.slice(-10);
    const avg = last.length >= 2 ? (last[last.length - 1].timestamp - last[0].timestamp) / (last.length - 1) : null;
    const supply = Object.values(this.accounts).reduce((sum, a) => sum + a.balance, 0);
    return {
      height: this.tip().height,
      tipHash: this.tip().hash,
      blocks: this.blocks.length,
      transactions: this.blocks.reduce((sum, b) => sum + b.transactions.length, 0),
      mempool: this.mempool.length,
      accounts: Object.keys(this.accounts).length,
      supply,
      difficultyBits: this.currentDifficulty(),
      averageBlockSeconds: avg,
      settings: this.settings,
    };
  }
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}
