// Schaltet die SSH-Schlüssel der Chain-Konten für den aktuellen Server-Benutzer frei
// (mit sudo: für den Benutzer, der sudo aufgerufen hat). Aufruf über: gibb-ssh-keys
import { execFileSync } from "node:child_process";
import { chmodSync, chownSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { userInfo } from "node:os";
import { join } from "node:path";
import { mergeAuthorizedKeys } from "../blockchain-node/ssh-keys.mjs";

const file = process.argv[2];
let entries = [];
try { entries = JSON.parse(readFileSync(file, "utf8")).keys ?? []; } catch (error) {
  console.error(`Schlüssel-Datei nicht lesbar (${file}): ${error.message}`);
  process.exit(1);
}

const asRoot = process.getuid?.() === 0;
const name = asRoot ? process.env.SUDO_USER : userInfo().username;
if (!name || name === "root") { console.error("Bitte als normaler Server-Benutzer ausführen (nicht als root)."); process.exit(1); }
const [, , uid, gid, , home] = execFileSync("getent", ["passwd", name], { encoding: "utf8" }).trim().split(":");
const dir = join(home, ".ssh");
const target = join(dir, "authorized_keys");

if (!existsSync(dir)) mkdirSync(dir, { mode: 0o700 });
const before = existsSync(target) ? readFileSync(target, "utf8") : "";
const after = mergeAuthorizedKeys(before, entries);
if (after === before) {
  console.log(`Nichts zu tun – ${entries.length} Schlüssel sind schon freigeschaltet.`);
} else {
  const tmp = `${target}.gibb-tmp`;
  writeFileSync(tmp, after, { mode: 0o600 });
  if (asRoot) chownSync(tmp, Number(uid), Number(gid));
  renameSync(tmp, target);
  console.log(`Freigeschaltet für ${name}: ${entries.length} Schlüssel.`);
}
if (asRoot) chownSync(dir, Number(uid), Number(gid));
chmodSync(dir, 0o700);
for (const e of entries) console.log(`  ✔ ${e.name}`);
console.log("Diese Konten können sich jetzt ohne Passwort verbinden (mit dem Schlüssel aus „Windows einrichten“).");
