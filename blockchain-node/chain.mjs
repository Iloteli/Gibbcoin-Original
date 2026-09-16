// Eigenständiger GIBB-Blockchain-Node (Testumgebung).
// Nutzt dieselben Formeln wie die App (Header, Merkle-Root, Nullbits),
// hält aber Konten, Mempool und Blöcke lokal in einer JSON-Datei.
// Der Server mined NICHT selbst: Er gibt Blockvorlagen heraus und prüft
// Blöcke, deren Nonce im Browser der Miner gefunden wurde.

import { createHash, randomBytes, scryptSync, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { ZERO_HASH, blockHeaderString, leadingZeroBits, merkleRoot } from "../app/lib/blockchain-core.js";

const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");

export const COINBASE = "COINBASE";

const defaultSettings = {
  reward: 10,
  difficultyBits: 18,   // Start moderat; die Auto-Regelung passt an die Rechenleistung an
  minBits: 15,          // Untergrenze, damit Blöcke auch auf schwachen Geräten zügig kommen
  maxBits: 30,          // Obergrenze für starke Miner
  targetSeconds: 15,    // Ziel: etwa alle 15 s ein Block -> Transaktionen werden zügig verarbeitet
  autoAdjust: true,
  maxTxPerBlock: 50,
  // Markt (Orderbuch). Preis in Rappen pro GIBB; Start bei 1 Rappen = 0.01 CHF.
  marketEnabled: true,
  startPrice: 1,        // Referenzpreis, bis der erste echte Handel stattfindet
  startingCash: 100,    // Rappen, die jedes neue Wallet fair als Startguthaben bekommt (= 1 CHF)
  tradingFeePercent: 0, // fair: standardmässig keine Gebühr
  minOrderAmount: 1,    // kleinste handelbare GIBB-Menge
  // Reserve-Miner: springt nur ein, wenn die Kette stillsteht (kein anderer Miner).
  fallbackMinerEnabled: true,
  fallbackDelaySeconds: 60,
  browserMinerThreads: 0,  // Standard-Kernzahl des Browser-Miners (0 = alle Kerne des Geräts)
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
    this.users = {};   // benutzername (klein) -> { address, salt, hash, role, username, createdAt }
    this.orders = [];  // offene Kauf-/Verkaufsaufträge (Orderbuch)
    this.trades = [];  // ausgeführte Handel (Kurshistorie), neueste zuletzt
    this.lastPrice = null;
    this.load();
  }

  // ---------- Persistenz ----------
  load() {
    if (this.file && existsSync(this.file)) {
      const raw = JSON.parse(readFileSync(this.file, "utf8"));
      this.blocks = raw.blocks ?? [];
      this.mempool = raw.mempool ?? [];
      this.accounts = raw.accounts ?? {};
      this.users = raw.users ?? {};
      this.settings = { ...defaultSettings, ...(raw.settings ?? {}) };
      this.orders = raw.orders ?? [];
      this.trades = raw.trades ?? [];
      this.lastPrice = raw.lastPrice ?? null;
    }
    // Bestehende Konten fair mit Startguthaben und Sperr-Feldern nachrüsten.
    for (const a of Object.values(this.accounts)) {
      if (typeof a.cash !== "number") a.cash = this.settings.startingCash;
      if (typeof a.lockedGibb !== "number") a.lockedGibb = 0;
      if (typeof a.lockedCash !== "number") a.lockedCash = 0;
    }
    if (this.blocks.length === 0) this.createGenesis();
  }

  save() {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify({ blocks: this.blocks, mempool: this.mempool, accounts: this.accounts, users: this.users, settings: this.settings, orders: this.orders, trades: this.trades, lastPrice: this.lastPrice }, null, 2));
    renameSync(tmp, this.file);
  }

  reset() {
    this.blocks = [];
    this.mempool = [];
    this.accounts = {};
    this.users = {};
    this.settings = { ...defaultSettings };
    this.orders = [];
    this.trades = [];
    this.lastPrice = null;
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
// ---------- Benutzer & Anmeldung (lokal, ohne Cloud) ----------
  hashPassword(password, salt) {
    return scryptSync(String(password), salt, 64).toString("hex");
  }

  // Registriert einen Benutzer mit Passwort und legt sein Wallet an. Der erste
  // Benutzer wird automatisch Owner (super_admin); alle weiteren sind normale Nutzer.
  registerUser(username, password) {
    const key = String(username ?? "").trim().toLowerCase();
    const name = String(username ?? "").trim().slice(0, 40);
    if (key.length < 3 || key.length > 40 || !/^[a-z0-9_.-]+$/.test(key)) throw new Error("invalid_username");
    if (String(password ?? "").length < 6) throw new Error("weak_password");
    if (this.users[key]) throw new Error("username_taken");
    const { address } = this.createWallet(name);
    const salt = randomBytes(16).toString("hex");
    const hasOwner = Object.values(this.users).some((u) => u.role === "super_admin");
    this.users[key] = { address, salt, hash: this.hashPassword(password, salt), role: hasOwner ? "user" : "super_admin", username: name, createdAt: Date.now() };
    this.save();
    return { address, username: name, role: this.users[key].role };
  }

  verifyUser(username, password) {
    const key = String(username ?? "").trim().toLowerCase();
    const u = this.users[key];
    if (!u) throw new Error("invalid_login");
    const got = Buffer.from(this.hashPassword(password, u.salt), "hex");
    const want = Buffer.from(u.hash, "hex");
    if (got.length !== want.length || !timingSafeEqual(got, want)) throw new Error("invalid_login");
    return { address: u.address, username: u.username, role: u.role };
  }

  userByAddress(address) {
    return Object.values(this.users).find((u) => u.address === address) || null;
  }

  createWallet(name) {
    const clean = String(name ?? "").trim().slice(0, 40) || `Wallet ${Object.keys(this.accounts).length + 1}`;
    let address;
    do address = `G${randomBytes(6).toString("hex")}`; while (this.accounts[address]);
    this.accounts[address] = { name: clean, balance: 0, cash: this.settings.startingCash, lockedGibb: 0, lockedCash: 0, createdAt: Date.now() };
    this.save();
    return { address, ...this.accounts[address] };
  }

  // Konto der echten Website (Supabase-Nutzer) anlegen oder aktualisieren.
  // Adresse = sb_<supabaseId>, damit es mit der Massen-Synchronisierung zusammenpasst.
  // WICHTIG: overwriteBalance nur beim ausdrücklichen Admin-Sync setzen. Die laufende
  // Auto-Registrierung (alle paar Sekunden) darf das Guthaben NICHT überschreiben,
  // sonst würden gerade gefundene Mining-Belohnungen sofort wieder gelöscht.
  upsertWebsiteAccount(supabaseId, name, balance, { overwriteBalance = false } = {}) {
    if (!supabaseId || typeof supabaseId !== "string") throw new Error("invalid_supabase_id");
    const address = `sb_${supabaseId}`;
    const cleanName = String(name ?? "").trim().slice(0, 40) || "Nutzer";
    const existing = this.accounts[address];
    if (!existing) {
      this.accounts[address] = {
        name: cleanName, balance: Number.isFinite(balance) ? Math.max(0, Math.round(balance)) : 0,
        cash: this.settings.startingCash, lockedGibb: 0, lockedCash: 0,
        createdAt: Date.now(), source: "supabase", supabaseId,
      };
    } else {
      existing.name = cleanName;
      if (overwriteBalance && Number.isFinite(balance)) existing.balance = Math.max(0, Math.round(balance));
      existing.source = "supabase";
      existing.supabaseId = supabaseId;
    }
    this.save();
    return { address, ...this.accounts[address] };
  }

  buildTransaction(from, to, amount, note = "", timestamp = Math.floor(Date.now() / 1000)) {
    const tx = { id: randomBytes(8).toString("hex"), from, to, amount, note: String(note ?? "").slice(0, 120), timestamp };
    tx.hash = transactionHash(tx);
    return tx;
  }

  // Frei verfügbare GIBB: Guthaben minus Mempool-Sendungen minus in Verkaufsorders gesperrte GIBB.
  availableBalance(address) {
    const pending = this.mempool.filter((tx) => tx.from === address).reduce((sum, tx) => sum + tx.amount, 0);
    const a = this.accounts[address];
    return (a?.balance ?? 0) - pending - (a?.lockedGibb ?? 0);
  }

  // Frei verfügbares Guthaben (Rappen) minus in Kauforders gesperrtes Geld.
  availableCash(address) {
    const a = this.accounts[address];
    return (a?.cash ?? 0) - (a?.lockedCash ?? 0);
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
  // Prüft die Integrität der Block-Kette: Verkettung, Block-Hash, Proof of Work,
  // Merkle-Root und Transaktions-Hashes. Kontostände werden hier NICHT gegengerechnet,
  // weil gespiegelte Website-Konten (Supabase) ihr Guthaben von aussen bekommen – die
  // Kette ist ein Proof-of-Work-Nachweis, kein geschlossenes Kassenbuch. Doppelausgabe
  // wird nur unter reinen Node-Wallets geprüft.
  verify() {
    let expectedPrevious = ZERO_HASH;
    const nativeBalances = {};
    const isNative = (addr) => addr !== COINBASE && this.accounts[addr] && !this.accounts[addr].source;
    for (const block of this.blocks) {
      const fail = (reason) => ({ valid: false, height: block.height, reason });
      if (block.previous_hash !== expectedPrevious) return fail("previous_hash_mismatch");
      const header = { height: block.height, previous_hash: block.previous_hash, merkle_root: block.merkle_root, timestamp: block.timestamp, difficulty_bits: block.difficulty_bits, miner_user_id: block.miner_user_id, nonce: block.nonce };
      if (sha256(blockHeaderString(header)) !== block.hash) return fail("block_hash_mismatch");
      if (leadingZeroBits(block.hash) < block.difficulty_bits) return fail("insufficient_work");
      if (merkleRoot(block.transactions.map((tx) => tx.hash)) !== block.merkle_root) return fail("merkle_root_mismatch");
      for (const tx of block.transactions) {
        if (transactionHash(tx) !== tx.hash) return fail(`transaction_hash_mismatch:${tx.id}`);
        if (isNative(tx.from)) {
          if ((nativeBalances[tx.from] ?? 0) < tx.amount) return fail(`overspend:${tx.id}`);
          nativeBalances[tx.from] -= tx.amount;
        }
        if (isNative(tx.to)) nativeBalances[tx.to] = (nativeBalances[tx.to] ?? 0) + tx.amount;
      }
      expectedPrevious = block.hash;
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

  // ---------- Markt (Orderbuch) ----------
  // Aktueller Kurs: Preis des letzten echten Handels, sonst der Referenz-Startpreis.
  marketPrice() {
    return this.lastPrice ?? this.settings.startPrice;
  }

  // Order platzieren. side: "buy" | "sell". price in Rappen/GIBB, amount in GIBB (ganzzahlig).
  // Sofort passende Gegenorders ausführen (Taker), Rest als offene Order ins Buch (Maker).
  placeOrder(address, side, price, amount) {
    if (!this.settings.marketEnabled) throw new Error("market_disabled");
    if (side !== "buy" && side !== "sell") throw new Error("invalid_side");
    if (!this.accounts[address]) throw new Error("unknown_account");
    price = Number(price);
    amount = Number(amount);
    if (!Number.isFinite(price) || price <= 0) throw new Error("invalid_price");
    if (!Number.isInteger(amount) || amount < this.settings.minOrderAmount) throw new Error("invalid_amount");

    // Deckung prüfen (Kauf: Geld zum Limitpreis; Verkauf: GIBB).
    if (side === "buy") {
      if (this.availableCash(address) < Math.round(price * amount)) throw new Error("insufficient_cash");
    } else if (this.availableBalance(address) < amount) {
      throw new Error("insufficient_funds");
    }

    const taker = this.accounts[address];
    const fee = this.settings.tradingFeePercent / 100;
    let remaining = amount;
    const fills = [];

    // Passende Gegenseite nach Preis-/Zeit-Priorität.
    const opposite = () => this.orders
      .filter((o) => o.side !== side && o.address !== address && (side === "buy" ? o.price <= price : o.price >= price))
      .sort((a, b) => (side === "buy" ? a.price - b.price : b.price - a.price) || a.createdAt - b.createdAt);

    for (const maker of opposite()) {
      if (remaining <= 0) break;
      const execAmount = Math.min(remaining, maker.remaining);
      const execPrice = maker.price; // Ausführung immer zum Preis der ruhenden Order
      const value = Math.round(execPrice * execAmount);
      const makerAcc = this.accounts[maker.address];
      const buyer = side === "buy" ? taker : makerAcc;
      const seller = side === "buy" ? makerAcc : taker;

      // GIBB vom Verkäufer zum Käufer.
      seller.balance -= execAmount;
      if (side === "buy") makerAcc.lockedGibb -= execAmount; // Maker war Verkäufer: Sperre lösen
      buyer.balance += execAmount;

      // Geld vom Käufer zum Verkäufer (abzüglich Gebühr beim Verkäufer).
      buyer.cash -= value;
      if (side === "sell") makerAcc.lockedCash -= value; // Maker war Käufer: Sperre lösen
      seller.cash += value - Math.round(value * fee);

      maker.remaining -= execAmount;
      maker.filled += execAmount;
      remaining -= execAmount;
      this.lastPrice = execPrice;
      const trade = { id: randomBytes(6).toString("hex"), price: execPrice, amount: execAmount, value, buyer: buyer === taker ? address : maker.address, seller: seller === taker ? address : maker.address, takerSide: side, at: Date.now() };
      this.trades.push(trade);
      fills.push(trade);
    }
    this.orders = this.orders.filter((o) => o.remaining > 0);
    if (this.trades.length > 2000) this.trades = this.trades.slice(-2000);

    // Rest als offene Order (Maker): Deckung sperren.
    let resting = null;
    if (remaining > 0) {
      if (side === "buy") taker.lockedCash += Math.round(price * remaining);
      else taker.lockedGibb += remaining;
      resting = { id: randomBytes(6).toString("hex"), address, side, price, amount: remaining, remaining, filled: 0, createdAt: Date.now() };
      this.orders.push(resting);
    }
    this.save();
    return { fills, resting, price: this.marketPrice() };
  }

  cancelOrder(address, orderId) {
    const order = this.orders.find((o) => o.id === orderId);
    if (!order) throw new Error("unknown_order");
    if (order.address !== address) throw new Error("not_your_order");
    const acc = this.accounts[address];
    if (order.side === "buy") acc.lockedCash -= Math.round(order.price * order.remaining);
    else acc.lockedGibb -= order.remaining;
    this.orders = this.orders.filter((o) => o.id !== orderId);
    this.save();
    return { cancelled: order.id };
  }

  // Aggregiertes Orderbuch (nach Preis zusammengefasst) + Kurskennzahlen.
  market(address = null) {
    const agg = (side, dir) => {
      const map = new Map();
      for (const o of this.orders.filter((x) => x.side === side)) map.set(o.price, (map.get(o.price) ?? 0) + o.remaining);
      return [...map.entries()].map(([price, amount]) => ({ price, amount })).sort((a, b) => dir * (a.price - b.price));
    };
    const bids = agg("buy", -1);   // höchste Kaufpreise zuerst
    const asks = agg("sell", 1);   // tiefste Verkaufspreise zuerst
    const dayAgo = Date.now() - 86_400_000;
    const recent = this.trades.filter((t) => t.at >= dayAgo);
    const price = this.marketPrice();
    const openFor = address ? this.orders.filter((o) => o.address === address).map((o) => ({ ...o })) : [];
    return {
      enabled: this.settings.marketEnabled,
      price,
      startPrice: this.settings.startPrice,
      lastTradedPrice: this.lastPrice,
      bestBid: bids[0]?.price ?? null,
      bestAsk: asks[0]?.price ?? null,
      spread: bids[0] && asks[0] ? asks[0].price - bids[0].price : null,
      volume24h: recent.reduce((sum, t) => sum + t.amount, 0),
      high24h: recent.length ? Math.max(...recent.map((t) => t.price)) : null,
      low24h: recent.length ? Math.min(...recent.map((t) => t.price)) : null,
      change24h: recent.length ? price - recent[0].price : 0,
      fee: this.settings.tradingFeePercent,
      minOrder: this.settings.minOrderAmount,
      bids: bids.slice(0, 20),
      asks: asks.slice(0, 20),
      trades: this.trades.slice(-40).reverse(),
      history: this.trades.slice(-120).map((t) => ({ at: t.at, price: t.price })),
      myOrders: openFor,
    };
  }

  updateSettings(patch) {
    const next = { ...this.settings };
    for (const key of ["reward", "difficultyBits", "minBits", "maxBits", "targetSeconds", "maxTxPerBlock", "startingCash", "minOrderAmount", "fallbackDelaySeconds", "browserMinerThreads"]) {
      if (patch[key] !== undefined) {
        const value = Number(patch[key]);
        if (!Number.isFinite(value)) throw new Error(`invalid_${key}`);
        next[key] = Math.round(value);
      }
    }
    for (const key of ["startPrice", "tradingFeePercent"]) {
      if (patch[key] !== undefined) {
        const value = Number(patch[key]);
        if (!Number.isFinite(value) || value < 0) throw new Error(`invalid_${key}`);
        next[key] = value;
      }
    }
    if (patch.autoAdjust !== undefined) next.autoAdjust = Boolean(patch.autoAdjust);
    if (patch.marketEnabled !== undefined) next.marketEnabled = Boolean(patch.marketEnabled);
    if (patch.fallbackMinerEnabled !== undefined) next.fallbackMinerEnabled = Boolean(patch.fallbackMinerEnabled);
    next.reward = clamp(next.reward, 0, 10_000);
    next.minBits = clamp(next.minBits, 1, 40);
    next.maxBits = clamp(next.maxBits, next.minBits, 40);
    next.difficultyBits = clamp(next.difficultyBits, next.minBits, next.maxBits);
    next.targetSeconds = clamp(next.targetSeconds, 1, 3600);
    next.maxTxPerBlock = clamp(next.maxTxPerBlock, 1, 1000);
    next.startPrice = clamp(next.startPrice, 0.0001, 1_000_000);
    next.startingCash = clamp(next.startingCash, 0, 100_000_000);
    next.tradingFeePercent = clamp(next.tradingFeePercent, 0, 20);
    next.minOrderAmount = clamp(next.minOrderAmount, 1, 1_000_000);
    next.fallbackDelaySeconds = clamp(next.fallbackDelaySeconds, 5, 3600);
    next.browserMinerThreads = clamp(next.browserMinerThreads, 0, 64);
    this.settings = next;
    this.save();
    return next;
  }

  stats() {
    const mined = this.blocks.filter((b) => b.height > 0);
    const last = mined.slice(-10);
    const avg = last.length >= 2 ? (last[last.length - 1].timestamp - last[0].timestamp) / (last.length - 1) : null;
    const supply = Object.values(this.accounts).reduce((sum, a) => sum + a.balance, 0);
    const price = this.marketPrice();
    return {
      price,
      marketCapRappen: Math.round(supply * price),
      volume24h: this.trades.filter((t) => t.at >= Date.now() - 86_400_000).reduce((sum, t) => sum + t.amount, 0),
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
