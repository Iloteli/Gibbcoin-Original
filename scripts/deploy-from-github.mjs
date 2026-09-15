// Holt den aktuellen Stand von Iloteli/Gibbcoin-Original (main) und baut die
// GibbCoin-Website neu, damit sowohl die Website (app/) als auch die
// Blockchain-Website (blockchain-node/) exakt die Version auf GitHub laufen.
//
//   pnpm deploy            # von GitHub holen + bauen
//   pnpm deploy -- --run   # zusätzlich beide Server starten (Website + Node)
//
// Danach laufen:  Website  http://localhost:3000   Blockchain  http://localhost:8787

import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const REMOTE = "https://github.com/Iloteli/Gibbcoin-Original";
const BRANCH = "main";
const run = process.argv.includes("--run");

function sh(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { cwd: repo, stdio: "inherit", shell: process.platform === "win32", ...opts });
  if (r.status !== 0) { console.error(`\nFehlgeschlagen: ${cmd} ${args.join(" ")}`); process.exit(r.status ?? 1); }
}
function capture(cmd, args) {
  return spawnSync(cmd, args, { cwd: repo, encoding: "utf8", shell: process.platform === "win32" }).stdout.trim();
}

console.log(`Hole ${REMOTE} (${BRANCH}) …`);
sh("git", ["fetch", REMOTE, BRANCH]);
const before = capture("git", ["rev-parse", "HEAD"]);
// Genau auf den GitHub-Stand setzen (nur diese Version zählt).
sh("git", ["reset", "--hard", "FETCH_HEAD"]);
const after = capture("git", ["rev-parse", "HEAD"]);

if (before === after) {
  console.log(`Bereits aktuell (${after.slice(0, 7)}).`);
} else {
  console.log(`Aktualisiert: ${before.slice(0, 7)} -> ${after.slice(0, 7)}`);
}

// Abhängigkeiten nur bei Bedarf neu installieren.
const lockChanged = before !== after && capture("git", ["diff", "--name-only", before, after]).includes("pnpm-lock.yaml");
if (lockChanged || !existsSync(join(repo, "node_modules"))) {
  console.log("Installiere Abhängigkeiten …");
  sh("pnpm", ["install", "--frozen-lockfile"]);
}

console.log("Baue die Website …");
sh("pnpm", ["run", "build"], { env: { ...process.env, NODE_OPTIONS: "--max-old-space-size=3072" } });

console.log(`\n✔ Beide Websites sind auf der GitHub-Version ${after.slice(0, 7)}.`);

if (run) {
  console.log("\nStarte Server … (mit Strg+C beenden)");
  const website = spawn("pnpm", ["start"], { cwd: repo, stdio: "inherit", shell: process.platform === "win32" });
  const node = spawn("node", ["blockchain-node/server.mjs"], { cwd: repo, stdio: "inherit", shell: process.platform === "win32" });
  const stop = () => { website.kill(); node.kill(); process.exit(0); };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
} else {
  console.log("Starten:  pnpm start   (Website)   und   pnpm chain   (Blockchain-Node)");
  console.log("Oder alles zusammen:  pnpm deploy -- --run");
}
