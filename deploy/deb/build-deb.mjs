#!/usr/bin/env node
// Baut ein installierbares .deb ohne dpkg-deb: eigener ustar-tar- und ar-Writer.
// Aufruf:  node deploy/deb/build-deb.mjs  ->  deploy/gibbcoin_<version>_all.deb
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PAYLOAD = join(HERE, "payload");
const CONTROLDIR = join(HERE, "control");
const OUTDIR = resolve(HERE, "..");

const control = readFileSync(join(CONTROLDIR, "control"), "utf8");
const version = (control.match(/^Version:\s*(.+)$/m) || [])[1].trim();
const pkg = (control.match(/^Package:\s*(.+)$/m) || [])[1].trim();

// ---- ustar tar writer ------------------------------------------------------
function padOctal(n, width) {
  return n.toString(8).padStart(width - 1, "0") + "\0";
}
function tarHeader({ name, mode, size, type }) {
  const h = Buffer.alloc(512, 0);
  h.write(name, 0, "utf8");                       // name[100]
  h.write(padOctal(mode, 8), 100);                // mode[8]
  h.write(padOctal(0, 8), 108);                   // uid[8]
  h.write(padOctal(0, 8), 116);                   // gid[8]
  h.write(padOctal(size, 12), 124);               // size[12]
  h.write(padOctal(Math.floor(Date.now() / 1000), 12), 136); // mtime[12]
  h.write("        ", 148);                        // chksum placeholder (spaces)
  h.write(type, 156);                              // typeflag
  h.write("ustar\0", 257);                         // magic
  h.write("00", 263);                              // version
  h.write("root", 265); h.write("root", 297);      // uname/gname
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, "0") + "\0 ", 148); // chksum
  return h;
}
function buildTar(entries) {
  const chunks = [];
  for (const e of entries) {
    const content = e.content || Buffer.alloc(0);
    chunks.push(tarHeader({ name: e.name, mode: e.mode, size: content.length, type: e.type }));
    if (content.length) {
      chunks.push(content);
      const pad = (512 - (content.length % 512)) % 512;
      if (pad) chunks.push(Buffer.alloc(pad, 0));
    }
  }
  chunks.push(Buffer.alloc(1024, 0)); // zwei Null-Blöcke = Ende
  return Buffer.concat(chunks);
}

// ---- Payload einsammeln ----------------------------------------------------
function walk(dir, base = "") {
  const out = [];
  for (const name of readdirSync(dir)) {
    const abs = join(dir, name);
    const rel = base ? `${base}/${name}` : name;
    if (statSync(abs).isDirectory()) out.push(...walk(abs, rel));
    else out.push(rel);
  }
  return out;
}
function isExec(rel) {
  return rel.startsWith("usr/bin/") || rel.endsWith(".sh");
}
function withDirs(files) {
  // Erzeugt ./ und alle Elternverzeichnisse als eigene Einträge (Debian-Konvention).
  const dirs = new Set(["."]);
  for (const f of files) {
    const parts = f.split("/");
    for (let i = 1; i < parts.length; i++) dirs.add("." + "/" + parts.slice(0, i).join("/"));
  }
  return [...dirs].sort();
}

const files = walk(PAYLOAD).map((f) => f.replace(/\\/g, "/"));
const dataEntries = [];
for (const d of withDirs(files)) {
  dataEntries.push({ name: d.endsWith("/") ? d : d + "/", mode: 0o755, type: "5" });
}
const md5lines = [];
for (const f of files) {
  let content = readFileSync(join(PAYLOAD, f));
  if (isExec(f) || f === "etc/default/gibbcoin") content = Buffer.from(content.toString("utf8").replace(/\r\n/g, "\n"), "utf8"); // LF erzwingen
  const mode = isExec(f) ? 0o755 : 0o644;
  dataEntries.push({ name: "./" + f, mode, type: "0", content });
  md5lines.push(`${createHash("md5").update(content).digest("hex")}  ${f}`);
}
const dataTarGz = gzipSync(buildTar(dataEntries));

// ---- control.tar -----------------------------------------------------------
const installedKb = Math.max(1, Math.round(dataEntries.reduce((n, e) => n + (e.content?.length || 0), 0) / 1024));
const controlText = control.replace(/\n?$/, "\n") + `Installed-Size: ${installedKb}\n`;
const controlEntries = [{ name: "./", mode: 0o755, type: "5" }];
const maint = { control: controlText, md5sums: md5lines.join("\n") + "\n" };
for (const s of ["conffiles", "postinst", "prerm", "postrm"]) {
  try { maint[s] = readFileSync(join(CONTROLDIR, s), "utf8"); } catch { /* optional */ }
}
for (const [name, text] of Object.entries(maint)) {
  const mode = ["postinst", "prerm", "postrm"].includes(name) ? 0o755 : 0o644;
  controlEntries.push({ name: "./" + name, mode, type: "0", content: Buffer.from(text.replace(/\r\n/g, "\n"), "utf8") });
}
const controlTarGz = gzipSync(buildTar(controlEntries));

// ---- ar-Archiv (.deb) ------------------------------------------------------
function arMember(name, data) {
  const h = Buffer.alloc(60, 0x20);
  h.write(name.padEnd(16), 0);
  h.write("0".padEnd(12), 16);          // mtime
  h.write("0".padEnd(6), 28);           // uid
  h.write("0".padEnd(6), 34);           // gid
  h.write("100644".padEnd(8), 40);      // mode
  h.write(String(data.length).padEnd(10), 48);
  h.write("`\n", 58);                    // magic 0x60 0x0A
  const parts = [h, data];
  if (data.length % 2 === 1) parts.push(Buffer.from("\n"));
  return Buffer.concat(parts);
}
const deb = Buffer.concat([
  Buffer.from("!<arch>\n"),
  arMember("debian-binary", Buffer.from("2.0\n")),
  arMember("control.tar.gz", controlTarGz),
  arMember("data.tar.gz", dataTarGz),
]);

mkdirSync(OUTDIR, { recursive: true });
const outFile = join(OUTDIR, `${pkg}_${version}_all.deb`);
writeFileSync(outFile, deb);
console.log(`OK  ${outFile}  (${(deb.length / 1024).toFixed(1)} KB, ${files.length} Dateien, Installed-Size ${installedKb} KB)`);
