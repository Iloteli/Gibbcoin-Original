import { test } from "node:test";
import assert from "node:assert/strict";
import { BLOCK_END, BLOCK_START, keyLabel, mergeAuthorizedKeys, parsePublicKey } from "./ssh-keys.mjs";

const KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzJ3m9pD7c8m1x6fWq0lQe4yq9qk1S8b9F2bXo0n4pZ";

test("parsePublicKey nimmt nur Typ und Schlüssel (ohne Kommentar)", () => {
  assert.equal(parsePublicKey(`${KEY} gibb-PC`), KEY);
  assert.equal(parsePublicKey(`  ${KEY}\r\nzweite Zeile`), KEY);
});

test("parsePublicKey lehnt Unsinn, Optionen und falschen Typ ab", () => {
  assert.throws(() => parsePublicKey(""), /invalid_ssh_key/);
  assert.throws(() => parsePublicKey("-----BEGIN OPENSSH PRIVATE KEY-----"), /invalid_ssh_key/);
  assert.throws(() => parsePublicKey(`command="rm -rf /" ${KEY}`), /invalid_ssh_key/);
  // Typ passt nicht zum Inhalt des Schlüssels
  assert.throws(() => parsePublicKey(KEY.replace("ssh-ed25519", "ssh-rsa")), /invalid_ssh_key/);
});

test("keyLabel lässt nur harmlose Zeichen", () => {
  assert.equal(keyLabel("Lea Muster\n#x"), "leamusterx");
  assert.equal(keyLabel(""), "konto");
});

test("mergeAuthorizedKeys ersetzt nur den gibb-Block", () => {
  const own = "ssh-rsa AAAAeigener owner@pc";
  const once = mergeAuthorizedKeys(`${own}\n`, [{ name: "lea", key: KEY }, { name: "bad", key: "kaputt" }]);
  assert.equal(once, `${own}\n${BLOCK_START}\n${KEY} gibb:lea\n${BLOCK_END}\n`);
  assert.equal(mergeAuthorizedKeys(once, [{ name: "lea", key: KEY }]), once);
  assert.equal(mergeAuthorizedKeys(once, []), `${own}\n`);
  assert.equal(mergeAuthorizedKeys("", []), "");
});
