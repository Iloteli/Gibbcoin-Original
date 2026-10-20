import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CODE_WINDOW_MS, createOwnerCodes } from "./owner-code.mjs";

test("Code wechselt alle 5 Minuten, ist pro Konto verschieden und gilt noch ein Fenster lang", () => {
  const file = join(mkdtempSync(join(tmpdir(), "gibb-code-")), "secret");
  let t = 10 * CODE_WINDOW_MS + 1000;
  const codes = createOwnerCodes({ file, now: () => t });
  const a = codes.current("user-a");
  assert.match(a.code, /^\d{6}$/);
  assert.equal(a.validUntil, 11 * CODE_WINDOW_MS);
  assert.notEqual(codes.current("user-b").code, a.code);
  assert.ok(codes.check("user-a", a.code));
  assert.ok(!codes.check("user-b", a.code), "Code gilt nur für das eigene Konto");
  t += CODE_WINDOW_MS; // nächstes Fenster: neuer Code, alter noch gültig
  assert.notEqual(codes.current("user-a").code, a.code);
  assert.ok(codes.check("user-a", a.code));
  t += CODE_WINDOW_MS; // danach abgelaufen
  assert.ok(!codes.check("user-a", a.code));
  assert.ok(!codes.check("user-a", "12345"));
  // Schlüssel bleibt nach Neustart gleich
  assert.equal(createOwnerCodes({ file, now: () => t }).current("user-a").code, codes.current("user-a").code);
  assert.match(readFileSync(file, "utf8"), /^[0-9a-f]{64}$/);
});
