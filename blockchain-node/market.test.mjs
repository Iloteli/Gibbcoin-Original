import assert from "node:assert/strict";
import test from "node:test";
import { Blockchain } from "./chain.mjs";

function seed() {
  const c = new Blockchain(null);
  const a = c.createWallet("Anna").address;
  const b = c.createWallet("Ben").address;
  c.accounts[a].balance = 100; // GIBB aus dem Mining
  return { c, a, b };
}

test("startet bei 1 Rappen und gibt jedem faires, gleiches Startguthaben", () => {
  const { c, a, b } = seed();
  assert.equal(c.marketPrice(), 1);
  assert.equal(c.accounts[a].cash, c.accounts[b].cash);
  assert.equal(c.accounts[a].cash, c.settings.startingCash);
});

test("ein echter Handel setzt den Kurs auf den Ausführungspreis", () => {
  const { c, a, b } = seed();
  c.placeOrder(a, "sell", 2, 50);
  const r = c.placeOrder(b, "buy", 2, 30);
  assert.equal(r.fills.length, 1);
  assert.equal(c.marketPrice(), 2);
  assert.equal(c.accounts[a].balance, 70);
  assert.equal(c.accounts[b].balance, 30);
  assert.equal(c.accounts[b].cash, c.settings.startingCash - 60);
  assert.equal(c.accounts[a].cash, c.settings.startingCash + 60);
});

test("Preis fällt, wenn Angebot billiger wird und gekauft wird (echte Angebot/Nachfrage)", () => {
  const { c, a, b } = seed();
  c.placeOrder(a, "sell", 5, 10);
  c.placeOrder(b, "buy", 5, 10);
  assert.equal(c.marketPrice(), 5);
  c.placeOrder(a, "sell", 2, 10);
  c.placeOrder(b, "buy", 2, 10);
  assert.equal(c.marketPrice(), 2);
});

test("Ausführung geschieht zum Preis der ruhenden Order, Rest bleibt im Buch", () => {
  const { c, a, b } = seed();
  c.placeOrder(a, "sell", 2, 20); // ruht
  const r = c.placeOrder(b, "buy", 3, 30); // matcht 20@2, 10 ruhen @3
  assert.equal(r.fills[0].price, 2);
  const m = c.market();
  assert.equal(m.bestBid, 3);
  assert.equal(m.bestAsk, null);
  assert.equal(c.accounts[b].balance, 20);
});

test("sperrt Guthaben und schützt vor Überziehung", () => {
  const { c, a, b } = seed();
  assert.throws(() => c.placeOrder(b, "buy", 100, 100000), /insufficient_cash/);
  assert.throws(() => c.placeOrder(a, "sell", 1, 1000), /insufficient_funds/);
  c.placeOrder(a, "sell", 2, 100); // alle GIBB gesperrt
  assert.equal(c.availableBalance(a), 0);
  assert.throws(() => c.addTransaction(a, b, 1), /insufficient_funds/);
});

test("Storno gibt gesperrtes Guthaben wieder frei", () => {
  const { c, a } = seed();
  const r = c.placeOrder(a, "sell", 2, 40);
  assert.equal(c.accounts[a].lockedGibb, 40);
  c.cancelOrder(a, r.resting.id);
  assert.equal(c.accounts[a].lockedGibb, 0);
  assert.equal(c.availableBalance(a), 100);
});

test("erhält die Gesamtmengen an GIBB und Guthaben über viele Trades", () => {
  const { c, a, b } = seed();
  const g0 = c.accounts[a].balance + c.accounts[b].balance;
  const k0 = c.accounts[a].cash + c.accounts[b].cash;
  c.placeOrder(a, "sell", 2, 50);
  c.placeOrder(b, "buy", 2, 30);
  c.placeOrder(b, "sell", 1, 10);
  c.placeOrder(a, "buy", 1, 10);
  assert.equal(c.accounts[a].balance + c.accounts[b].balance, g0);
  assert.equal(c.accounts[a].cash + c.accounts[b].cash, k0);
});

test("upsertWebsiteAccount legt Website-Konten an und aktualisiert Guthaben", () => {
  const c = new Blockchain(null);
  const a = c.upsertWebsiteAccount("abc-123", "Ilja", 250);
  assert.equal(a.address, "sb_abc-123");
  assert.equal(c.accounts["sb_abc-123"].balance, 250);
  assert.equal(c.accounts["sb_abc-123"].cash, c.settings.startingCash);
  assert.equal(c.accounts["sb_abc-123"].source, "supabase");
  c.upsertWebsiteAccount("abc-123", "Ilja P.", 999);
  assert.equal(c.accounts["sb_abc-123"].name, "Ilja P.");
  assert.equal(c.accounts["sb_abc-123"].balance, 250); // ohne overwriteBalance bleibt das Guthaben (Mining-Schutz)
  c.upsertWebsiteAccount("abc-123", "Ilja P.", 999, { overwriteBalance: true });
  assert.equal(c.accounts["sb_abc-123"].balance, 999);
  assert.throws(() => c.upsertWebsiteAccount("", "X", 1), /invalid_supabase_id/);
});
