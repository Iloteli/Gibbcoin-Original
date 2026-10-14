import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createNotifier } from "./notify.mjs";

const setup = () => {
  const sent = [];
  const fetchImpl = async (url, init) => { sent.push({ url, ...JSON.parse(init.body) }); return { ok: true, status: 200 }; };
  const file = join(mkdtempSync(join(tmpdir(), "gibb-notify-")), "notify.json");
  return { sent, file, notifier: createNotifier({ file, fetchImpl }) };
};

test("notifications stay off until enabled and get a secret topic", async () => {
  const { sent, file, notifier } = setup();
  assert.equal((await notifier.send("test", "x", "y")).skipped, true);
  const c = notifier.set({ enabled: true });
  assert.match(c.topic, /^gibb-[0-9a-f]{24}$/);
  assert.equal(JSON.parse(readFileSync(file, "utf8")).topic, c.topic, "gespeichert");
  assert.equal((await notifier.send("test", "Titel ü", "Text")).ok, true);
  assert.deepEqual([sent[0].url, sent[0].topic, sent[0].title], ["https://ntfy.sh", c.topic, "Titel ü"]);
  assert.throws(() => notifier.set({ topic: "kurz" }), /invalid_notify_topic/);
  assert.throws(() => notifier.set({ server: "http://unsicher.ch" }), /invalid_notify_server/);
  assert.notEqual(notifier.set({ newTopic: true }).topic, c.topic);
});

test("single kinds can be switched off", async () => {
  const { sent, notifier } = setup();
  notifier.set({ enabled: true, bank: false });
  assert.equal((await notifier.send("bank", "a", "b")).skipped, true);
  assert.equal((await notifier.send("start", "a", "b")).ok, true);
  assert.equal(sent.length, 1);
});

test("watch reports only items that are new after the first look", async () => {
  const { sent, notifier } = setup();
  notifier.set({ enabled: true });
  let items = [{ id: 1 }];
  const w = notifier.watch(async () => items, { kind: "bank", intervalMs: 1e9, format: (o) => ({ title: "Neu", message: `#${o.id}` }) });
  await w.tick();
  assert.equal(sent.length, 0, "bestehende nicht melden");
  items = [{ id: 1 }, { id: 2 }];
  await w.tick();
  await w.tick();
  assert.deepEqual(sent.map((s) => s.message), ["#2"]);
  w.stop();
});
