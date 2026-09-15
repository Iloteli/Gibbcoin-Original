import assert from "node:assert/strict";
import test from "node:test";
import { Blockchain } from "./chain.mjs";

// Stubt die Supabase-REST-Antworten, um die Spiegelung ohne echtes Projekt zu prüfen.
function withStub(profiles, wallets, run) {
  const realFetch = globalThis.fetch;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  process.env.SUPABASE_URL = "https://demo.supabase.co";
  process.env.SUPABASE_SERVICE_ROLE_KEY = "demo-key";
  globalThis.fetch = async (u) => {
    const path = String(u).split("/rest/v1/")[1];
    return { ok: true, json: async () => (path.startsWith("profiles") ? profiles : wallets) };
  };
  return (async () => run())().finally(() => {
    globalThis.fetch = realFetch;
    if (url === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = url;
    if (key === undefined) delete process.env.SUPABASE_SERVICE_ROLE_KEY; else process.env.SUPABASE_SERVICE_ROLE_KEY = key;
  });
}

test("spiegelt Supabase-Profile als Blockchain-Konten mit Guthaben und Startgeld", async () => {
  const { syncSupabaseAccounts } = await import("./supabase-sync.mjs");
  const chain = new Blockchain(null);
  await withStub(
    [{ id: "aaa", username: "lea", display_name: "Lea", email: "lea@x" }, { id: "bbb", username: null, display_name: "Tim", email: "tim@x" }],
    [{ user_id: "aaa", balance: 340 }, { user_id: "bbb", balance: 12 }],
    async () => {
      const r = await syncSupabaseAccounts(chain);
      assert.equal(r.added, 2);
      assert.equal(chain.accounts["sb_aaa"].name, "lea");
      assert.equal(chain.accounts["sb_aaa"].balance, 340);
      assert.equal(chain.accounts["sb_aaa"].cash, chain.settings.startingCash);
      assert.equal(chain.accounts["sb_bbb"].name, "Tim");
      assert.equal(chain.accounts["sb_aaa"].source, "supabase");
    },
  );
});

test("aktualisiert Guthaben und ist bei unveränderten Daten idempotent", async () => {
  const { syncSupabaseAccounts } = await import("./supabase-sync.mjs");
  const chain = new Blockchain(null);
  await withStub([{ id: "aaa", username: "lea", display_name: "Lea", email: "l@x" }], [{ user_id: "aaa", balance: 100 }], async () => {
    await syncSupabaseAccounts(chain);
    const second = await syncSupabaseAccounts(chain);
    assert.equal(second.added, 0);
    assert.equal(second.updated, 0);
  });
  await withStub([{ id: "aaa", username: "lea", display_name: "Lea", email: "l@x" }], [{ user_id: "aaa", balance: 500 }], async () => {
    const r = await syncSupabaseAccounts(chain);
    assert.equal(r.updated, 1);
    assert.equal(chain.accounts["sb_aaa"].balance, 500);
  });
});

test("meldet fehlende Konfiguration statt zu spiegeln", async () => {
  const { loadSupabaseConfig } = await import("./supabase-sync.mjs");
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  try {
    assert.equal(loadSupabaseConfig().configured, false);
  } finally {
    if (url !== undefined) process.env.SUPABASE_URL = url;
    if (key !== undefined) process.env.SUPABASE_SERVICE_ROLE_KEY = key;
  }
});
