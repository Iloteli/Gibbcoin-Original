"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { blockHash, expectedAttempts, meetsDifficulty, merkleRoot, minerWorkerSource } from "../lib/blockchain-core";
import { getSupabase } from "../lib/supabase";
import type { Block } from "../lib/types";
import { BlockchainCharts, MinerLeaderboard } from "./BlockchainCharts";

type Overview = {
  enabled: boolean;
  reward: number;
  target_seconds: number;
  cooldown_seconds: number;
  max_tx_per_block: number;
  min_bits: number;
  max_bits: number;
  height: number | null;
  tip_hash: string | null;
  tip_mined_at: string | null;
  difficulty_bits: number;
  block_count: number;
  minted_reward: number;
  pending_count: number;
  average_block_seconds: number | null;
  my_blocks: number;
  my_next_mining_at: string | null;
  top_miners: Array<{ user_id: string; label: string; blocks: number; reward: number }>;
  server_time: string;
};

type Template = {
  height: number;
  previous_hash: string;
  merkle_root: string;
  first_chain_index: number;
  last_chain_index: number;
  tx_count: number;
  tx_hashes: string[];
  timestamp: number;
  difficulty_bits: number;
  miner_user_id: string;
  reward: number;
  header_prefix: string;
};

type BlockTransaction = { chain_index: number; hash: string; previous_hash: string; type: string; created_at: string };
type Verification = { valid: boolean; blocks_checked: number; invalid_height?: number; reason?: string; checked_at?: string };
type MiningStatus = "idle" | "preparing" | "mining" | "submitting" | "cooldown";
type Settings = { enabled: boolean; reward: number; target_seconds: number; min_bits: number; max_bits: number; cooldown_seconds: number; max_tx_per_block: number };

const TEMPLATE_REFRESH_MS = 45_000;
const OVERVIEW_REFRESH_MS = 30_000;

const errorMessages: Record<string, string> = {
  mining_disabled: "Mining ist zurzeit vom Admin deaktiviert.",
  mining_cooldown: "Du hast gerade einen Block gefunden – kurze Pause, bevor du weiter minen darfst.",
  no_pending_transactions: "Es gibt keine unbestätigten Transaktionen. Sobald jemand Coins bewegt, kann der nächste Block gebaut werden.",
  stale_block: "Jemand war schneller: Die Kette hat sich verändert. Neue Vorlage wird geladen …",
  invalid_timestamp: "Die Blockvorlage war zu alt. Neue Vorlage wird geladen …",
  difficulty_too_low: "Die Schwierigkeit ist inzwischen gestiegen. Neue Vorlage wird geladen …",
  insufficient_work: "Der Proof of Work reicht nicht aus. Neue Vorlage wird geladen …",
  hash_mismatch: "Der Block-Hash stimmt nicht mit dem Server überein.",
  invalid_transaction_range: "Die Transaktionsauswahl ist nicht mehr gültig. Neue Vorlage wird geladen …",
  wallet_locked: "Dein Wallet ist gesperrt. Mining ist nicht möglich.",
  account_locked: "Dein Konto ist gesperrt. Mining ist nicht möglich.",
  authentication_required: "Bitte melde dich erneut an.",
};
const retryCodes = new Set(["stale_block", "invalid_timestamp", "difficulty_too_low", "insufficient_work", "invalid_transaction_range"]);

function codeOf(error: unknown): string {
  const message = typeof error === "object" && error && "message" in error ? String((error as { message: unknown }).message) : String(error ?? "");
  return message.trim().split(/\s+/)[0] ?? "";
}
function describe(error: unknown): string {
  const code = codeOf(error);
  return errorMessages[code] ?? "Die Blockchain-Aktion ist fehlgeschlagen. Bitte versuche es später erneut.";
}
function shortHash(hash: string | null | undefined, length = 10): string {
  if (!hash) return "–";
  return `${hash.slice(0, length)}…${hash.slice(-4)}`;
}
function formatDate(value: string | null | undefined): string {
  if (!value) return "–";
  const date = new Date(value);
  return `${date.toLocaleDateString("de-CH", { day: "2-digit", month: "short" })} · ${date.toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}`;
}
function formatSeconds(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "–";
  if (value < 90) return `${Math.round(value)} s`;
  if (value < 5400) return `${(value / 60).toFixed(1)} min`;
  return `${(value / 3600).toFixed(1)} h`;
}
function formatHashrate(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)} MH/s`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)} kH/s`;
  return `${Math.round(value)} H/s`;
}
function formatCount(value: number): string {
  return value.toLocaleString("de-CH");
}

export function BlockchainExplorer({ userId, isAdmin, onChanged }: { userId: string; isAdmin: boolean; onChanged: () => void }) {
  const [overview, setOverview] = useState<Overview | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [expanded, setExpanded] = useState<number | null>(null);
  const [blockTransactions, setBlockTransactions] = useState<Record<number, BlockTransaction[]>>({});
  const [verification, setVerification] = useState<Verification | null>(null);
  const [verifying, setVerifying] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [loadError, setLoadError] = useState("");

  const [status, setStatus] = useState<MiningStatus>("idle");
  const [continuous, setContinuous] = useState(true);
  const [template, setTemplate] = useState<Template | null>(null);
  const [nonce, setNonce] = useState(0);
  const [hashes, setHashes] = useState(0);
  const [hashrate, setHashrate] = useState(0);
  const [foundBlocks, setFoundBlocks] = useState<Block[]>([]);
  const [cooldownUntil, setCooldownUntil] = useState<number | null>(null);
  const [now, setNow] = useState(() => Date.now());

  const [settings, setSettings] = useState<Settings | null>(null);
  const [pin, setPin] = useState("");
  const [savingSettings, setSavingSettings] = useState(false);
  const [settingsMessage, setSettingsMessage] = useState("");

  const workerRef = useRef<Worker | null>(null);
  const workerUrlRef = useRef<string | null>(null);
  const templateRef = useRef<Template | null>(null);
  const wantMiningRef = useRef(false);
  const startedAtRef = useRef(0);
  const hashesRef = useRef(0);
  const refreshTimerRef = useRef<number | null>(null);
  const continuousRef = useRef(true);
  const startRoundRef = useRef<() => Promise<void>>(async () => {});

  const load = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const [overviewResult, blocksResult] = await Promise.all([
      supabase.rpc("get_blockchain_overview"),
      supabase.from("blocks").select("height,previous_hash,merkle_root,first_chain_index,last_chain_index,tx_count,mined_at,difficulty_bits,nonce,hash,miner_user_id,miner_label,reward,reward_transaction_id,created_at").order("height", { ascending: false }).limit(60),
    ]);
    if (overviewResult.error || blocksResult.error) {
      setLoadError("Die Blockchain ist noch nicht verfügbar. Wurde die Migration 20260915090000_add_gibb_blockchain angewendet?");
      return;
    }
    setLoadError("");
    const next = overviewResult.data as Overview;
    setOverview(next);
    setBlocks((blocksResult.data ?? []) as Block[]);
    setSettings((current) => current ?? { enabled: next.enabled, reward: next.reward, target_seconds: next.target_seconds, min_bits: next.min_bits, max_bits: next.max_bits, cooldown_seconds: next.cooldown_seconds, max_tx_per_block: next.max_tx_per_block });
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    const interval = window.setInterval(() => void load(), OVERVIEW_REFRESH_MS);
    return () => { window.clearTimeout(timer); window.clearInterval(interval); };
  }, [load]);

  useEffect(() => {
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(tick);
  }, []);

  const stopWorker = useCallback(() => {
    workerRef.current?.postMessage({ type: "stop" });
    workerRef.current?.terminate();
    workerRef.current = null;
    if (workerUrlRef.current) { URL.revokeObjectURL(workerUrlRef.current); workerUrlRef.current = null; }
    if (refreshTimerRef.current) { window.clearTimeout(refreshTimerRef.current); refreshTimerRef.current = null; }
  }, []);

  const stopMining = useCallback((message?: string) => {
    wantMiningRef.current = false;
    stopWorker();
    templateRef.current = null;
    setTemplate(null);
    setStatus("idle");
    setCooldownUntil(null);
    if (message) setNotice(message);
  }, [stopWorker]);

  const submitBlock = useCallback(async (current: Template, foundNonce: number, hash: string) => {
    const supabase = getSupabase();
    if (!supabase) return;
    setStatus("submitting");
    const { data, error: rpcError } = await supabase.rpc("submit_mined_block", {
      p_height: current.height,
      p_previous_hash: current.previous_hash,
      p_last_chain_index: current.last_chain_index,
      p_timestamp: current.timestamp,
      p_difficulty_bits: current.difficulty_bits,
      p_nonce: foundNonce,
      p_hash: hash,
    });
    if (rpcError) {
      const code = codeOf(rpcError);
      if (retryCodes.has(code) && wantMiningRef.current) {
        setNotice(describe(rpcError));
        window.setTimeout(() => void startRoundRef.current(), 800);
        return;
      }
      stopMining();
      setError(describe(rpcError));
      return;
    }
    const block = (data as { block: Block }).block;
    setFoundBlocks((list) => [block, ...list].slice(0, 10));
    setNotice(`Block #${block.height} gefunden! ${block.reward > 0 ? `+${block.reward} GIBB wurden deinem Wallet gutgeschrieben.` : "Belohnung ist zurzeit 0 GIBB."}`);
    setError("");
    onChanged();
    await load();
    if (!wantMiningRef.current || !continuousRef.current) { wantMiningRef.current = false; templateRef.current = null; setTemplate(null); setStatus("idle"); return; }
    const cooldownMs = Math.max(0, (overview?.cooldown_seconds ?? 90) * 1000);
    if (cooldownMs > 0) {
      setStatus("cooldown");
      setCooldownUntil(Date.now() + cooldownMs);
      refreshTimerRef.current = window.setTimeout(() => { if (wantMiningRef.current) void startRoundRef.current(); }, cooldownMs + 500);
    } else {
      void startRoundRef.current();
    }
  }, [load, onChanged, overview?.cooldown_seconds, stopMining]);

  const startRound = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase || !wantMiningRef.current) return;
    stopWorker();
    setStatus("preparing");
    setCooldownUntil(null);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("get_block_template");
    if (!wantMiningRef.current) return;
    if (rpcError) {
      const code = codeOf(rpcError);
      if (code === "no_pending_transactions" || code === "mining_cooldown") {
        setStatus("cooldown");
        setNotice(describe(rpcError));
        setCooldownUntil(Date.now() + 20_000);
        refreshTimerRef.current = window.setTimeout(() => void startRoundRef.current(), 20_000);
        return;
      }
      stopMining();
      setError(describe(rpcError));
      return;
    }
    const next = data as Template;
    // Konsistenzprüfung: Merkle-Root und Header müssen lokal exakt gleich herauskommen.
    const localMerkle = merkleRoot(next.tx_hashes);
    const prefix = `${next.height}|${next.previous_hash}|${next.merkle_root}|${next.timestamp}|${next.difficulty_bits}|${next.miner_user_id}|`;
    if (localMerkle !== next.merkle_root || `${prefix}0` !== next.header_prefix) {
      stopMining();
      setError("Die lokale Blockberechnung weicht vom Server ab. Bitte lade die App neu.");
      return;
    }
    templateRef.current = next;
    setTemplate(next);
    setNonce(0);
    setHashes(0);
    hashesRef.current = 0;
    startedAtRef.current = Date.now();
    setStatus("mining");

    const url = URL.createObjectURL(new Blob([minerWorkerSource()], { type: "text/javascript" }));
    workerUrlRef.current = url;
    const worker = new Worker(url);
    workerRef.current = worker;
    worker.onmessage = (event: MessageEvent<{ type: string; nonce: number; hashes?: number; hash?: string }>) => {
      const message = event.data;
      if (templateRef.current !== next) return;
      if (message.type === "progress") {
        hashesRef.current += message.hashes ?? 0;
        setNonce(message.nonce);
        setHashes(hashesRef.current);
        const elapsed = (Date.now() - startedAtRef.current) / 1000;
        if (elapsed > 0.5) setHashrate(hashesRef.current / elapsed);
        return;
      }
      if (message.type === "found" && message.hash) {
        stopWorker();
        // Lokale Gegenprüfung vor dem Einreichen.
        const header = { height: next.height, previous_hash: next.previous_hash, merkle_root: next.merkle_root, timestamp: next.timestamp, difficulty_bits: next.difficulty_bits, miner_user_id: next.miner_user_id, nonce: message.nonce };
        if (blockHash(header) !== message.hash || !meetsDifficulty(message.hash, next.difficulty_bits)) {
          setError("Der gefundene Block hat die lokale Prüfung nicht bestanden.");
          stopMining();
          return;
        }
        setNonce(message.nonce);
        void submitBlock(next, message.nonce, message.hash);
      }
    };
    worker.onerror = () => { stopMining(); setError("Der Mining-Worker ist abgestürzt."); };
    worker.postMessage({ type: "start", prefix, difficultyBits: next.difficulty_bits, startNonce: 0 });

    // Vorlage regelmässig erneuern: neue Transaktionen, neue Blöcke, frischer Zeitstempel.
    refreshTimerRef.current = window.setTimeout(() => { if (wantMiningRef.current && templateRef.current === next) void startRoundRef.current(); }, TEMPLATE_REFRESH_MS);
  }, [stopMining, stopWorker, submitBlock]);
  useEffect(() => { startRoundRef.current = startRound; }, [startRound]);

  const startMining = useCallback(() => {
    if (typeof Worker === "undefined") { setError("Dieser Browser unterstützt keine Web Worker."); return; }
    wantMiningRef.current = true;
    setNotice("");
    setFoundBlocks([]);
    void startRound();
  }, [startRound]);

  useEffect(() => () => { wantMiningRef.current = false; stopWorker(); }, [stopWorker]);

  const toggleBlock = useCallback(async (height: number) => {
    if (expanded === height) { setExpanded(null); return; }
    setExpanded(height);
    if (blockTransactions[height]) return;
    const supabase = getSupabase();
    if (!supabase) return;
    const { data } = await supabase.rpc("get_block_transactions", { p_height: height });
    setBlockTransactions((map) => ({ ...map, [height]: (data ?? []) as BlockTransaction[] }));
  }, [blockTransactions, expanded]);

  const verify = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    setVerifying(true);
    const { data, error: rpcError } = await supabase.rpc("verify_blockchain");
    setVerifying(false);
    if (rpcError) { setError(describe(rpcError)); return; }
    setVerification(data as Verification);
  }, []);

  const saveSettings = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase || !settings) return;
    setSavingSettings(true);
    setSettingsMessage("");
    const { data, error: rpcError } = await supabase.rpc("admin_update_blockchain_settings", { p_value: settings, p_pin: pin });
    setSavingSettings(false);
    const result = data as { ok: boolean; error?: string; settings?: Settings } | null;
    if (rpcError || !result?.ok) {
      const code = result?.error ?? codeOf(rpcError);
      setSettingsMessage(code?.startsWith("admin_pin_") ? "Admin-PIN ungültig oder Freigabe abgelaufen." : code === "mfa_required" ? "Für diese Änderung ist eine bestätigte MFA-Sitzung nötig." : code === "invalid_difficulty_range" ? "Die minimale Schwierigkeit darf die maximale nicht übersteigen." : "Die Einstellungen konnten nicht gespeichert werden.");
      return;
    }
    if (result.settings) setSettings(result.settings);
    setSettingsMessage("Blockchain-Einstellungen gespeichert.");
    await load();
  }, [load, pin, settings]);

  const cooldownTarget = cooldownUntil ?? (overview?.my_next_mining_at ? new Date(overview.my_next_mining_at).getTime() : null);
  const cooldownRemaining = cooldownTarget ? Math.max(0, Math.ceil((cooldownTarget - now) / 1000)) : 0;

  const expected = template ? expectedAttempts(template.difficulty_bits) : overview ? expectedAttempts(overview.difficulty_bits) : 0;
  const estimateSeconds = hashrate > 0 && expected > 0 ? expected / hashrate : null;
  const progress = expected > 0 ? Math.min(1, hashes / expected) : 0;
  const mining = status === "mining" || status === "preparing" || status === "submitting" || status === "cooldown";

  return (
    <div className="blockchain">
      {loadError && <div className="game-error">{loadError}</div>}

      <section className="card card-pad blockchain-hero">
        <div className="blockchain-hero-copy">
          <span className="eyebrow">GIBB BLOCKCHAIN</span>
          <h2>Proof of Work, der in der Schule läuft</h2>
          <p>Jede Coin-Bewegung landet in der Transaktions-Hash-Kette. Miner bündeln unbestätigte Transaktionen in Blöcke (Merkle-Root), verketten sie mit dem Vorgänger und suchen mit dem Prozessor eine Nonce, deren SHA-256-Hash genug führende Nullbits hat. Der Server prüft jeden Block nach und zahlt die Belohnung aus.</p>
        </div>
        <div className="admin-stats blockchain-stats">
          <div><span>Blockhöhe</span><strong>{overview?.height ?? "–"}</strong></div>
          <div><span>Schwierigkeit</span><strong>{overview ? `${overview.difficulty_bits} Bit` : "–"}</strong></div>
          <div><span>Unbestätigt</span><strong>{overview ? formatCount(overview.pending_count) : "–"}</strong></div>
          <div><span>Belohnung</span><strong>{overview ? `${overview.reward} GIBB` : "–"}</strong></div>
          <div><span>Ø Blockzeit</span><strong>{formatSeconds(overview?.average_block_seconds)}</strong></div>
          <div><span>Ziel</span><strong>{formatSeconds(overview?.target_seconds)}</strong></div>
          <div><span>Gemint gesamt</span><strong>{overview ? `${formatCount(overview.minted_reward)} GIBB` : "–"}</strong></div>
          <div><span>Deine Blöcke</span><strong>{overview?.my_blocks ?? "–"}</strong></div>
        </div>
      </section>

      <BlockchainCharts blocks={blocks} targetSeconds={overview?.target_seconds} />

      <div className="blockchain-grid">
        <section className="card card-pad blockchain-miner" aria-label="Mining">
          <div className="card-head"><h2>Miner</h2><span>{overview?.enabled === false ? "Vom Admin pausiert" : status === "mining" ? "Sucht Nonce …" : status === "preparing" ? "Lädt Vorlage …" : status === "submitting" ? "Reicht Block ein …" : status === "cooldown" ? "Wartet …" : "Bereit"}</span></div>
          <div className={`blockchain-mining-state ${status}`}>
            <div className="blockchain-meter" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(progress * 100)} aria-label="Erwarteter Fortschritt"><i style={{ width: `${Math.round(progress * 100)}%` }} /></div>
            <div className="blockchain-mining-grid">
              <div><span>Hashrate</span><strong>{status === "mining" ? formatHashrate(hashrate) : "–"}</strong></div>
              <div><span>Versuche</span><strong>{formatCount(hashes)}</strong></div>
              <div><span>Nonce</span><strong>{formatCount(nonce)}</strong></div>
              <div><span>Erwartet</span><strong>{expected ? `~${formatCount(expected)}` : "–"}</strong></div>
              <div><span>Ø Dauer</span><strong>{formatSeconds(estimateSeconds)}</strong></div>
              <div><span>Block</span><strong>{template ? `#${template.height} · ${template.tx_count} Tx` : "–"}</strong></div>
            </div>
            {template && <small className="blockchain-template">Vorgänger {shortHash(template.previous_hash)} · Merkle {shortHash(template.merkle_root)} · {template.difficulty_bits} Bit · Belohnung {template.reward} GIBB</small>}
            {status === "cooldown" && cooldownRemaining > 0 && <small className="blockchain-template">Nächster Versuch in {cooldownRemaining} s</small>}
          </div>
          <div className="blockchain-actions">
            {!mining
              ? <button className="primary compact" type="button" disabled={overview?.enabled === false || !!loadError || (cooldownRemaining > 0 && status === "idle")} onClick={startMining}>{cooldownRemaining > 0 && status === "idle" ? `Pause · ${cooldownRemaining} s` : "Mining starten"}</button>
              : <button className="secondary" type="button" onClick={() => stopMining("Mining gestoppt.")}>Mining stoppen</button>}
            <label className="blockchain-toggle"><input type="checkbox" checked={continuous} onChange={(event) => { setContinuous(event.target.checked); continuousRef.current = event.target.checked; }} /> Nach einem Treffer weiter minen</label>
          </div>
          {!continuous && status === "mining" && <small className="field-hint">Nach dem nächsten Block stoppt der Miner automatisch.</small>}
          {error && <div className="message error">{error}</div>}
          {notice && !error && <div className="message">{notice}</div>}
          {foundBlocks.length > 0 && <ul className="blockchain-found">{foundBlocks.map((block) => <li key={block.height}><strong>#{block.height}</strong><span>{shortHash(block.hash, 14)}</span><b>+{block.reward} GIBB</b></li>)}</ul>}
          <small className="field-hint">Die Belohnung landet nach der Serverprüfung <strong>direkt in deinem Wallet</strong>. Ein Block bündelt unbestätigte Coin-Bewegungen – gibt es gerade keine, wartet der Miner, bis jemand Coins sendet oder spielt. Läuft nur, solange dieser Tab offen ist.</small>
        </section>

        <section className="card card-pad" aria-label="Top-Miner">
          <div className="card-head"><h2>Bestenliste</h2><span>meiste gefundene Blöcke</span></div>
          <MinerLeaderboard miners={overview?.top_miners ?? []} userId={userId} myBlocks={overview?.my_blocks} />
          <div className="blockchain-verify">
            <button className="secondary compact" type="button" disabled={verifying || !!loadError} onClick={verify}>{verifying ? "Prüft …" : "Kette vollständig prüfen"}</button>
            {verification && <div className={`chain-status ${verification.valid ? "" : "invalid"}`}><i aria-hidden="true" />{verification.valid ? `${verification.blocks_checked} Blöcke verifiziert` : `Fehler bei Block #${verification.invalid_height}: ${verification.reason}`}</div>}
          </div>
          <small className="field-hint">Die Prüfung rechnet serverseitig alle Merkle-Roots, Block-Hashes und den Proof of Work jedes Blocks nach.</small>
        </section>
      </div>

      <section className="card card-pad" aria-label="Blöcke">
        <div className="card-head"><h2>Blöcke</h2><span>{overview ? `${formatCount(overview.block_count)} Blöcke · Spitze ${shortHash(overview.tip_hash)}` : ""}</span></div>
        {blocks.length === 0 && !loadError && <div className="empty">Noch keine Blöcke.</div>}
        <div className="blockchain-blocks">
          {blocks.map((block) => {
            const open = expanded === block.height;
            const transactions = blockTransactions[block.height];
            return (
              <article className={`blockchain-block ${open ? "open" : ""} ${block.miner_user_id === userId ? "mine" : ""}`} key={block.height}>
                <button type="button" className="blockchain-block-head" aria-expanded={open} onClick={() => void toggleBlock(block.height)}>
                  <span className="blockchain-block-height">#{block.height}</span>
                  <span className="blockchain-block-main"><strong>{shortHash(block.hash, 16)}</strong><small>{block.height === 0 ? "Genesis" : `Gefunden von ${block.miner_label}`} · {block.tx_count} Tx · {block.difficulty_bits} Bit · Nonce {formatCount(block.nonce)}</small></span>
                  <span className="blockchain-block-meta"><strong>{block.reward > 0 ? `+${block.reward} GIBB` : "–"}</strong><small>{formatDate(block.mined_at)}</small></span>
                </button>
                {open && (
                  <div className="blockchain-block-body">
                    <dl>
                      <div><dt>Hash</dt><dd><code>{block.hash}</code></dd></div>
                      <div><dt>Vorgänger</dt><dd><code>{block.previous_hash}</code></dd></div>
                      <div><dt>Merkle-Root</dt><dd><code>{block.merkle_root}</code></dd></div>
                      <div><dt>Kettenindex</dt><dd>{block.first_chain_index === null ? "–" : `${block.first_chain_index} – ${block.last_chain_index}`}</dd></div>
                      <div><dt>Zeitstempel</dt><dd>{formatDate(block.mined_at)} ({Math.floor(new Date(block.mined_at).getTime() / 1000)})</dd></div>
                    </dl>
                    <h3>Transaktionen im Block</h3>
                    {!transactions && <div className="empty">Lädt …</div>}
                    {transactions && transactions.length === 0 && <div className="empty">Keine Transaktionen.</div>}
                    {transactions && transactions.length > 0 && <ul className="blockchain-txs">{transactions.map((tx) => <li key={tx.hash}><span>#{tx.chain_index}</span><code title={tx.hash}>{shortHash(tx.hash, 18)}</code><small>{tx.type} · {formatDate(tx.created_at)}</small></li>)}</ul>}
                  </div>
                )}
              </article>
            );
          })}
        </div>
      </section>

      {isAdmin && settings && (
        <section className="card card-pad blockchain-admin" aria-label="Blockchain-Einstellungen">
          <div className="card-head"><h2>Admin · Blockchain</h2><span>Belohnung, Tempo, Schwierigkeit</span></div>
          <div className="blockchain-admin-grid">
            <label className="field"><span>Mining aktiv</span><select className="input" value={settings.enabled ? "1" : "0"} onChange={(event) => setSettings({ ...settings, enabled: event.target.value === "1" })}><option value="1">Ja</option><option value="0">Nein</option></select></label>
            <label className="field"><span>Belohnung pro Block (GIBB)</span><input className="input" type="number" min={0} max={1000} value={settings.reward} onChange={(event) => setSettings({ ...settings, reward: Number(event.target.value) })} /></label>
            <label className="field"><span>Ziel-Blockzeit (Sekunden)</span><input className="input" type="number" min={10} max={86400} value={settings.target_seconds} onChange={(event) => setSettings({ ...settings, target_seconds: Number(event.target.value) })} /></label>
            <label className="field"><span>Pause pro Miner (Sekunden)</span><input className="input" type="number" min={0} max={86400} value={settings.cooldown_seconds} onChange={(event) => setSettings({ ...settings, cooldown_seconds: Number(event.target.value) })} /></label>
            <label className="field"><span>Min. Schwierigkeit (Bit)</span><input className="input" type="number" min={8} max={48} value={settings.min_bits} onChange={(event) => setSettings({ ...settings, min_bits: Number(event.target.value) })} /></label>
            <label className="field"><span>Max. Schwierigkeit (Bit)</span><input className="input" type="number" min={8} max={48} value={settings.max_bits} onChange={(event) => setSettings({ ...settings, max_bits: Number(event.target.value) })} /></label>
            <label className="field"><span>Max. Transaktionen pro Block</span><input className="input" type="number" min={1} max={2000} value={settings.max_tx_per_block} onChange={(event) => setSettings({ ...settings, max_tx_per_block: Number(event.target.value) })} /></label>
            <label className="field"><span>Admin-PIN</span><input className="input" type="password" autoComplete="off" inputMode="numeric" value={pin} onChange={(event) => setPin(event.target.value)} placeholder="PIN zur Freigabe" /></label>
          </div>
          <div className="blockchain-actions">
            <button className="primary compact" type="button" disabled={savingSettings || !pin} onClick={() => void saveSettings()}>{savingSettings ? "Speichert …" : "Einstellungen speichern"}</button>
            {settingsMessage && <span className={`message ${settingsMessage.includes("gespeichert") ? "" : "error"}`}>{settingsMessage}</span>}
          </div>
          <small className="field-hint">Jedes Bit verdoppelt die nötige Rechenarbeit. Ein Notebook-Kern schafft rund 100–300 kH/s: 16 Bit ≈ Sekundenbruchteile, 20 Bit ≈ 5 s, 24 Bit ≈ 1–2 min, 28 Bit ≈ 20 min. Die Schwierigkeit regelt sich automatisch auf die Ziel-Blockzeit ein und sinkt, wenn die Kette stillsteht.</small>
        </section>
      )}

      <div className="disclaimer">Die GIBB-Blockchain ist ein Lernprojekt innerhalb der Schul-App: kein öffentliches Netzwerk, keine echte Kryptowährung. Guthaben bleiben serverautoritativ; Blöcke machen den Verlauf nachprüfbar.</div>
    </div>
  );
}
