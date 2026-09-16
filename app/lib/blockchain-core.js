// Reine, abhängigkeitsfreie Blockchain-Bausteine für Browser und Tests.
// Header-Format, Merkle-Root und Proof-of-Work-Mass müssen exakt den SQL-Funktionen
// private.block_header / private.merkle_root / private.leading_zero_bits entsprechen.

export const ZERO_HASH = "0".repeat(64);

/**
 * Synchrones SHA-256 (hex) für kurze ASCII-/UTF-8-Strings. Bewusst ohne WebCrypto,
 * damit der Mining-Worker Millionen Hashes ohne Promise-Overhead rechnen kann.
 * Die Funktion ist vollständig eigenständig, damit sie per toString() in den Worker kopiert werden kann.
 * @param {string} message
 * @returns {string}
 */
export function sha256Hex(message) {
  const K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const bytes = [];
  for (let i = 0; i < message.length; i += 1) {
    let code = message.charCodeAt(i);
    if (code < 0x80) bytes.push(code);
    else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    else if (code >= 0xd800 && code < 0xdc00 && i + 1 < message.length) {
      code = 0x10000 + ((code - 0xd800) << 10) + (message.charCodeAt(i + 1) - 0xdc00);
      i += 1;
      bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
  }
  const bitLength = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (let shift = 56; shift >= 0; shift -= 8) bytes.push(shift >= 32 ? 0 : (bitLength / 2 ** shift) & 0xff);

  let h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  let h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  const w = new Array(64);
  for (let offset = 0; offset < bytes.length; offset += 64) {
    for (let i = 0; i < 16; i += 1) {
      const j = offset + i * 4;
      w[i] = ((bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i += 1) {
      const x = w[i - 15], y = w[i - 2];
      const s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
      const s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (let i = 0; i < 64; i += 1) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0; h5 = (h5 + f) >>> 0; h6 = (h6 + g) >>> 0; h7 = (h7 + h) >>> 0;
  }
  let out = "";
  for (const v of [h0, h1, h2, h3, h4, h5, h6, h7]) out += ("00000000" + v.toString(16)).slice(-8);
  return out;
}

/**
 * Führende Nullbits eines Hex-Hashes – das Proof-of-Work-Mass.
 * Eigenständig, damit die Funktion in den Worker kopiert werden kann.
 * @param {string} hex
 * @returns {number}
 */
export function leadingZeroBits(hex) {
  let bits = 0;
  for (let i = 0; i < hex.length; i += 1) {
    const nibble = parseInt(hex[i], 16);
    if (Number.isNaN(nibble)) throw new Error("invalid_hex");
    if (nibble === 0) { bits += 4; continue; }
    return bits + (nibble < 2 ? 3 : nibble < 4 ? 2 : nibble < 8 ? 1 : 0);
  }
  return bits;
}

/**
 * Merkle-Root über Transaktions-Hashes (letztes Element wird bei ungerader Anzahl verdoppelt).
 * @param {string[]} hashes
 * @returns {string}
 */
export function merkleRoot(hashes) {
  if (!hashes || hashes.length === 0) return ZERO_HASH;
  let level = hashes.slice();
  while (level.length > 1) {
    if (level.length % 2 === 1) level.push(level[level.length - 1]);
    const next = [];
    for (let i = 0; i < level.length; i += 2) next.push(sha256Hex(level[i] + level[i + 1]));
    level = next;
  }
  return level[0];
}

/**
 * @typedef {object} BlockHeader
 * @property {number} height
 * @property {string} previous_hash
 * @property {string} merkle_root
 * @property {number} timestamp Unix-Sekunden
 * @property {number} difficulty_bits
 * @property {string | null} miner_user_id
 * @property {number} nonce
 */

/** @param {BlockHeader} header */
export function blockHeaderString(header) {
  return `${header.height}|${header.previous_hash}|${header.merkle_root}|${header.timestamp}|${header.difficulty_bits}|${header.miner_user_id ?? ""}|${header.nonce}`;
}

/** @param {BlockHeader} header */
export function blockHash(header) {
  return sha256Hex(blockHeaderString(header));
}

/** @param {string} hash @param {number} difficultyBits */
export function meetsDifficulty(hash, difficultyBits) {
  return leadingZeroBits(hash) >= difficultyBits;
}

/**
 * Erwartete Hash-Versuche für eine Schwierigkeit (2^bits).
 * @param {number} difficultyBits
 */
export function expectedAttempts(difficultyBits) {
  return 2 ** difficultyBits;
}

/**
 * Quelltext eines Web Workers, der die Nonce-Suche ausführt. Er kennt nur den
 * Header-Präfix (alles vor der Nonce) und meldet Fortschritt sowie Treffer.
 * Nachrichten an den Worker: { type: "start", prefix, difficultyBits, startNonce, nonceStep } | { type: "stop" }
 * Mit nonceStep > 1 durchsuchen mehrere Worker versetzte Nonce-Bereiche (ein Worker pro Prozessorkern).
 * Nachrichten vom Worker: { type: "progress", nonce, hashes } | { type: "found", nonce, hash }
 */
export function minerWorkerSource() {
  return `
const sha256Hex = ${sha256Hex.toString()};
const leadingZeroBits = ${leadingZeroBits.toString()};
let running = false;
self.onmessage = (event) => {
  const message = event.data || {};
  if (message.type === "stop") { running = false; return; }
  if (message.type !== "start") return;
  running = true;
  const prefix = String(message.prefix);
  const difficultyBits = Number(message.difficultyBits);
  const nonceStep = Number(message.nonceStep) || 1;
  let nonce = Number(message.startNonce) || 0;
  const batch = 40000; // grosse Batches = mehr CPU-Auslastung pro Kern (Worker blockiert die UI nicht)
  const tick = () => {
    if (!running) return;
    for (let i = 0; i < batch; i += 1) {
      const hash = sha256Hex(prefix + nonce);
      if (leadingZeroBits(hash) >= difficultyBits) {
        running = false;
        self.postMessage({ type: "found", nonce, hash });
        return;
      }
      nonce += nonceStep;
    }
    self.postMessage({ type: "progress", nonce, hashes: batch });
    setTimeout(tick, 0);
  };
  tick();
};
`;
}
