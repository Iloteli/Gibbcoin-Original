"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { getSupabase } from "../lib/supabase";
import { DinoRunner } from "./DinoRunner";

type GameKey = "roulette" | "coin_flip" | "blackjack" | "dice_duel" | "high_card" | "poker" | "plinko" | "dino_run" | "slots" | "baccarat" | "keno" | "wheel" | "mines" | "bingo" | "crash";
type PrankGameKey = Exclude<GameKey, "dino_run">;
type SettingKey = "game_center" | GameKey;
type GameSetting = { game_key: SettingKey; label: string; enabled: boolean; updated_at: string };
type GameRound = {
  id: string;
  game_key: GameKey;
  choice: string | null;
  wager: number;
  payout: number;
  result: Record<string, unknown>;
  created_at: string;
};
type BlackjackState = {
  id: string;
  wager: number;
  player_cards: number[];
  dealer_cards: number[];
  dealer_hidden: boolean;
  status: "active" | "won" | "lost" | "push";
  payout: number;
  player_score: number;
  dealer_score?: number | null;
};
type PokerState = {
  id: string;
  wager: number;
  cards: number[];
  status: "active" | "finished";
  payout: number;
  hand?: string;
  multiplier?: number;
};
type DinoState = {
  ok: boolean;
  id: string;
  seed: number;
  score: number;
  wager: number;
  reward: number;
  total_reward: number;
  next_reward_at: number;
  balance: number;
  status: "active" | "finished" | "abandoned";
  game_key: "dino_run";
  speed_level: number;
  difficulty_level: number;
};
type DinoLeaderboardEntry = {
  rank: number;
  user_id: string;
  username: string;
  score: number;
  reward_total: number;
  finished_at: string;
  is_me: boolean;
};
type DinoLeaderboardState = {
  ok: boolean;
  entries: DinoLeaderboardEntry[];
  my_entry: DinoLeaderboardEntry | null;
};
type CenterState = {
  balance: number;
  settings: GameSetting[];
  recent_rounds: GameRound[];
  blackjack: BlackjackState | null;
  poker: PokerState | null;
};
type GameResult = {
  ok: boolean;
  game_key: GameKey;
  wager: number;
  payout: number;
  net: number;
  result: Record<string, unknown>;
  balance: number;
};
type Props = {
  walletBalance: number;
  onChanged: () => void | Promise<void>;
};

const games: Array<{ key: GameKey; title: string; icon: string; description: string }> = [
  { key: "roulette", title: "Roulette", icon: "◎", description: "Setze auf Rot, Schwarz oder eine Zahl." },
  { key: "coin_flip", title: "Münzwurf", icon: "◐", description: "Kopf oder Zahl – ein schneller 50/50-Wurf." },
  { key: "blackjack", title: "Blackjack", icon: "♠", description: "Komme näher an 21 als die Bank." },
  { key: "dice_duel", title: "Würfelduell", icon: "⚄", description: "Der höhere Wurf gewinnt, Gleichstand zahlt zurück." },
  { key: "high_card", title: "High Card", icon: "♦", description: "Ziehe die höhere Karte als das Haus." },
  { key: "poker", title: "5-Karten-Poker", icon: "♣", description: "Halte starke Karten und ziehe den Rest neu." },
  { key: "plinko", title: "Plinko", icon: "●", description: "Lass die Kugel durch das Peg-Feld in ein Gewinnfach fallen." },
  { key: "dino_run", title: "Dino Run", icon: "▰", description: "Steigendes Tempo, enge Hindernisse und sichere Prämien." },
  { key: "slots", title: "Slots", icon: "▦", description: "Drei Symbole, ein serverseitig fairer Zufall." },
  { key: "baccarat", title: "Baccarat", icon: "♛", description: "Wähle Spieler, Bank oder Unentschieden." },
  { key: "keno", title: "Keno", icon: "⑨", description: "Wähle fünf Zahlen zwischen 1 und 40." },
  { key: "wheel", title: "Wheel", icon: "◉", description: "Drehe das Rad mit acht serverseitigen Feldern." },
  { key: "mines", title: "Mines", icon: "✦", description: "Ein serverseitiger Feld-Reveal entscheidet über Gewinn oder Verlust." },
  { key: "bingo", title: "Bingo", icon: "▤", description: "Eine serverseitige Gewinnchance entscheidet die Runde." },
  { key: "crash", title: "Crash", icon: "↗", description: "Wähle ein Ziel und vergleiche es mit dem serverseitigen Multiplikator." },
];
const wagers = [1, 10, 50, 100, 500, 1_000, 5_000, 10_000];
const plinkoMultipliers = [3, 1, 0, 0, 0, 0, 0, 1, 3];
const DINO_ENTRY_COST = 150;
const casinoGameKeys: GameKey[] = ["slots", "baccarat", "keno", "wheel", "mines", "bingo", "crash"];

function gameError(message?: string) {
  if (message?.includes("insufficient_balance")) return "Dein Wallet hat nicht genügend GIBB für diesen Einsatz.";
  if (message?.includes("game_disabled")) return "Dieses Spiel wurde von einem Admin deaktiviert.";
  if (message?.includes("game_too_fast")) return "Kurz warten – die vorige Runde wird noch verbucht.";
  if (message?.includes("wallet_locked")) return "Dein Konto ist gesperrt und kann nicht spielen.";
  if (message?.includes("blackjack_session_active")) return "Beende zuerst deine laufende Blackjack-Runde.";
  if (message?.includes("blackjack_session")) return "Diese Blackjack-Runde ist nicht mehr aktiv.";
  if (message?.includes("poker_session_active")) return "Beende zuerst deine laufende Poker-Runde.";
  if (message?.includes("poker_session")) return "Diese Poker-Runde ist nicht mehr aktiv.";
  if (message?.includes("invalid_poker_hold")) return "Die gehaltenen Karten konnten nicht sicher übernommen werden.";
  if (message?.includes("dino_score_too_fast")) return "Der Punktestand war schneller als ein echter Lauf und wurde nicht ausgezahlt.";
  if (message?.includes("dino_score")) return "Dieser Dino-Punktestand konnte nicht sicher bestätigt werden.";
  if (message?.includes("dino_session")) return "Dieser Dino-Lauf ist nicht mehr aktiv. Starte einen neuen Lauf.";
  if (message?.includes("invalid_game_wager")) return "Der Einsatz muss eine positive ganze Zahl sein.";
  return "Die Runde konnte nicht sicher verbucht werden. Versuche es nochmals.";
}

function gameName(key: GameKey) {
  return games.find((game) => game.key === key)?.title ?? key;
}

function cardLabel(value: number) {
  if (value === 1) return "A";
  if (value === 11) return "J";
  if (value === 12) return "Q";
  if (value === 13) return "K";
  return String(value);
}

function dieFace(value: number) {
  return ["⚀", "⚁", "⚂", "⚃", "⚄", "⚅"][Math.max(0, Math.min(5, value - 1))];
}

function holdAnimation(duration: number) {
  return new Promise<void>((resolve) => window.setTimeout(resolve, duration));
}

function resultText(round: GameRound) {
  if (round.game_key === "roulette") return `${round.result.number ?? "?"} · ${round.result.color ?? "?"}`;
  if (round.game_key === "coin_flip") return String(round.result.side ?? "?");
  if (round.game_key === "blackjack") return String(round.result.status ?? "beendet");
  if (round.game_key === "poker") return String(round.result.hand ?? "Pokerhand");
  if (round.game_key === "plinko") return `Fach ${Number(round.result.slot ?? 0) + 1} · ${round.result.multiplier ?? 0}×`;
  if (round.game_key === "dino_run") return `${Number(round.result.score ?? 0).toLocaleString("de-CH")} Punkte`;
  return `${round.result.player ?? "?"} : ${round.result.house ?? "?"}`;
}

function PlayingCards({ cards, hidden = false }: { cards: number[]; hidden?: boolean }) {
  const suits = ["♠", "♥", "♣", "♦"];
  return <div className="playing-cards">{cards.map((card, index) => <span className={`playing-card ${index % 2 ? "red" : ""}`} key={`${card}-${index}`}><b>{cardLabel(card)}</b><i>{suits[index % suits.length]}</i></span>)}{hidden && <span className="playing-card card-back" aria-label="Verdeckte Karte">G</span>}</div>;
}

function PokerCards({ cards, held, disabled, onToggle }: { cards: number[]; held: Set<number>; disabled: boolean; onToggle: (position: number) => void }) {
  const suits = ["♠", "♥", "♣", "♦"];
  return <div className="playing-cards poker-cards">{cards.map((card, index) => {
    const position = index + 1;
    const rank = (card % 13) + 2;
    const suitIndex = Math.floor(card / 13);
    const isHeld = held.has(position);
    return <button className={`playing-card poker-card ${suitIndex % 2 ? "red" : ""} ${isHeld ? "held" : ""}`} type="button" aria-pressed={isHeld} disabled={disabled} key={`${card}-${position}`} onClick={() => onToggle(position)}><b>{cardLabel(rank === 14 ? 1 : rank)}</b><i>{suits[suitIndex]}</i><em>{isHeld ? "HALTEN" : "TAUSCHEN"}</em></button>;
  })}</div>;
}

function PlinkoBoard({ slot, dropping, animationKey }: { slot: number | null; dropping: boolean; animationKey: number }) {
  const safeSlot = Math.max(0, Math.min(8, slot ?? 4));
  return <div className="plinko-board" aria-label={slot === null ? "Plinko-Spielfeld bereit" : `Plinko-Kugel in Fach ${safeSlot + 1}`}>
    <div className="plinko-drop-zone">
      <div className="plinko-launch" aria-hidden="true"><i /><i /><i /></div>
      {Array.from({ length: 7 }, (_, row) => <div className="plinko-peg-row" key={row}>{Array.from({ length: row + 3 }, (_, peg) => <i key={peg} />)}</div>)}
      <span
        className={`plinko-ball plinko-slot-${safeSlot} ${dropping ? "searching" : slot !== null ? "landed" : "ready"}`}
        key={`plinko-ball-${animationKey}-${slot ?? "ready"}`}
        style={{ "--plinko-slot": safeSlot } as CSSProperties}
        aria-hidden="true"
      >G</span>
    </div>
    <div className="plinko-slots" aria-hidden="true">{plinkoMultipliers.map((multiplier, index) => <span className={slot === index ? "active" : ""} key={index}><b>{multiplier}×</b><i /></span>)}</div>
  </div>;
}

export function GameCenter({ walletBalance, onChanged }: Props) {
  const [state, setState] = useState<CenterState | null>(null);
  const [selectedGame, setSelectedGame] = useState<GameKey>("roulette");
  const [wager, setWager] = useState(1);
  const [rouletteChoice, setRouletteChoice] = useState("rot");
  const [coinChoice, setCoinChoice] = useState("kopf");
  const [baccaratChoice, setBaccaratChoice] = useState("spieler");
  const [kenoPicks, setKenoPicks] = useState([1, 2, 3, 4, 5]);
  const [crashTarget, setCrashTarget] = useState(2);
  const [lastResult, setLastResult] = useState<GameResult | null>(null);
  const [blackjack, setBlackjack] = useState<BlackjackState | null>(null);
  const [poker, setPoker] = useState<PokerState | null>(null);
  const [dino, setDino] = useState<DinoState | null>(null);
  const [dinoLeaderboard, setDinoLeaderboard] = useState<DinoLeaderboardState | null>(null);
  const [dinoRewardNotice, setDinoRewardNotice] = useState("");
  const [heldPokerCards, setHeldPokerCards] = useState<Set<number>>(() => new Set());
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [animationKey, setAnimationKey] = useState(0);
  const [effectivePrankGames, setEffectivePrankGames] = useState<Set<PrankGameKey>>(() => new Set());
  const activeRoundRef = useRef(false);
  const pendingLiveRefreshRef = useRef(false);
  const dinoRef = useRef<DinoState | null>(null);
  const dinoSyncChainRef = useRef<Promise<void>>(Promise.resolve());
  const dinoFinalQueuedRef = useRef(false);

  const loadState = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) {
      setError("Die Wallet-Verbindung ist noch nicht bereit. Lade die Spiele erneut.");
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: rpcError } = await supabase.rpc("get_game_center_state");
    if (rpcError) {
      setError(gameError(rpcError.message));
      setLoading(false);
      return;
    }
    const next = data as CenterState;
    const nextSettings = new Map(next.settings.map((setting) => [setting.game_key, setting]));
    const nextCenterEnabled = nextSettings.get("game_center")?.enabled ?? false;
    const nextVisibleGames = games.filter((game) => (
      nextCenterEnabled && (nextSettings.get(game.key)?.enabled ?? false)
    ) || (game.key === "blackjack" && Boolean(next.blackjack)) || (game.key === "poker" && Boolean(next.poker)));
    setSelectedGame((current) => next.blackjack ? "blackjack" : next.poker ? "poker" : nextVisibleGames.some((game) => game.key === current) ? current : nextVisibleGames[0]?.key ?? current);
    setState(next);
    setBlackjack(next.blackjack);
    setPoker(next.poker);
    setError("");
    setLoading(false);
  }, []);

  const loadDinoLeaderboard = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) { setError("Die Bestenliste ist momentan nicht erreichbar."); return; }
    const { data, error: rpcError } = await supabase.rpc("get_dino_leaderboard");
    if (rpcError) { setError("Die Bestenliste konnte nicht geladen werden. Versuche es nochmals."); return; }
    const next = data as DinoLeaderboardState | null;
    if (!next?.ok || !Array.isArray(next.entries)) return;
    setDinoLeaderboard({ ok: true, entries: next.entries, my_entry: next.my_entry ?? null });
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadState(), 0);
    return () => window.clearTimeout(timer);
  }, [loadState]);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadDinoLeaderboard(), 0);
    return () => window.clearTimeout(timer);
  }, [loadDinoLeaderboard]);

  const loadEffectivePranks = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    const { data, error: rpcError } = await supabase.rpc("get_effective_visual_pranks");
    if (rpcError) { setError("Die Spielansicht konnte nicht aktualisiert werden."); return; }
    const next = data as { ok?: boolean; games?: PrankGameKey[] } | null;
    if (!next?.ok || !Array.isArray(next.games)) return;
    setEffectivePrankGames(new Set(next.games));
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadEffectivePranks(), 0);
    const interval = window.setInterval(() => void loadEffectivePranks(), 10_000);
    return () => {
      window.clearTimeout(timer);
      window.clearInterval(interval);
    };
  }, [loadEffectivePranks]);

  useEffect(() => {
    activeRoundRef.current = busy || Boolean(blackjack) || Boolean(poker) || Boolean(dino);
    if (!activeRoundRef.current && pendingLiveRefreshRef.current) {
      pendingLiveRefreshRef.current = false;
      void loadState();
    }
  }, [blackjack, busy, dino, loadState, poker]);

  useEffect(() => {
    const supabase = getSupabase();
    if (!supabase) return;
    const channel = supabase
      .channel("game-settings-live")
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "game_settings" }, () => {
        if (activeRoundRef.current) {
          pendingLiveRefreshRef.current = true;
          return;
        }
        void loadState();
      })
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [loadState]);

  const settings = useMemo(() => new Map((state?.settings ?? []).map((setting) => [setting.game_key, setting])), [state?.settings]);
  const centerEnabled = settings.get("game_center")?.enabled ?? false;
  const visibleGames = useMemo(() => games.filter((game) => (
    centerEnabled && (settings.get(game.key)?.enabled ?? false)
  ) || (game.key === "blackjack" && Boolean(blackjack)) || (game.key === "poker" && Boolean(poker)) || (game.key === "dino_run" && Boolean(dino))), [blackjack, centerEnabled, dino, poker, settings]);
  const selectedVisible = visibleGames.some((game) => game.key === selectedGame);
  const currentEnabled = centerEnabled && (settings.get(selectedGame)?.enabled ?? false);
  const currentBalance = state?.balance ?? walletBalance;
  const wagerValid = Number.isSafeInteger(wager) && wager >= 1;
  const allInWager = Math.max(Math.floor(currentBalance), 0);
  const dinoCanStart = currentBalance >= DINO_ENTRY_COST;
  const won = Boolean(lastResult && lastResult.payout > lastResult.wager);
  const lost = Boolean(lastResult && lastResult.payout < lastResult.wager);

  function chooseGame(key: GameKey) {
    if ((blackjack && key !== "blackjack") || (poker && key !== "poker") || (dino && key !== "dino_run")) {
      setError(`Beende zuerst deine laufende ${blackjack ? "Blackjack" : poker ? "Poker" : "Dino-Run"}-Runde.`);
      return;
    }
    setSelectedGame(key);
    setLastResult(null);
    setError("");
  }

  function selectedChoice() {
    if (selectedGame === "roulette") return rouletteChoice;
    if (selectedGame === "coin_flip") return coinChoice;
    if (selectedGame === "baccarat") return baccaratChoice;
    if (selectedGame === "keno") {
      const picks = [...new Set(kenoPicks)];
      if (picks.length !== 5 || picks.some((pick) => !Number.isInteger(pick) || pick < 1 || pick > 40)) {
        setError("Keno braucht genau fünf verschiedene Zahlen zwischen 1 und 40.");
        return null;
      }
      return picks.sort((a, b) => a - b).join(",");
    }
    if (selectedGame === "crash") {
      if (!Number.isFinite(crashTarget) || crashTarget < 1.1 || crashTarget > 10) {
        setError("Das Crash-Ziel muss zwischen 1,1 und 10,0 liegen.");
        return null;
      }
      return crashTarget.toFixed(1);
    }
    return "spielen";
  }

  async function playInstant() {
    if (busy || loading || !currentEnabled) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    const choice = selectedChoice();
    if (!choice) return;
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setAnimationKey((key) => key + 1);
    try {
      const [{ data, error: rpcError }] = await Promise.all([
        supabase.rpc(casinoGameKeys.includes(selectedGame) ? "play_casino_game" : "play_instant_game", {
          p_game_key: selectedGame,
          p_choice: choice,
          p_wager: wager,
        }),
        holdAnimation(1150),
      ]);
      if (rpcError) { setError(gameError(rpcError.message)); return; }
      const result = data as GameResult;
      setLastResult(result);
      setState((current) => current ? { ...current, balance: result.balance } : current);
      try { await Promise.all([loadState(), onChanged()]); } catch { setError("Runde verbucht. Wallet-Ansicht konnte nicht aktualisiert werden."); }
    } catch { setError("Die Runde konnte wegen eines Verbindungsfehlers nicht verbucht werden. Versuche es nochmals."); }
    finally { setBusy(false); }
  }

  async function startBlackjack() {
    if (busy || loading || blackjack || !currentEnabled) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setAnimationKey((key) => key + 1);
    try {
      const [{ data, error: rpcError }] = await Promise.all([
        supabase.rpc("start_blackjack", { p_wager: wager }),
        holdAnimation(850),
      ]);
      if (rpcError) { setError(gameError(rpcError.message)); return; }
      const result = data as BlackjackState & { balance: number };
      setBlackjack(result.status === "active" ? result : null);
      if (typeof result.balance === "number") setState((current) => current ? { ...current, balance: result.balance } : current);
      if (result.status !== "active") {
        setLastResult({ ok: true, game_key: "blackjack", wager: result.wager, payout: result.payout, net: result.payout - result.wager, result: { status: result.status }, balance: result.balance });
      }
      try { await Promise.all([loadState(), onChanged()]); } catch { setError("Runde verbucht. Wallet-Ansicht konnte nicht aktualisiert werden."); }
    } catch { setError("Die Runde konnte wegen eines Verbindungsfehlers nicht gestartet werden. Versuche es nochmals."); }
    finally { setBusy(false); }
  }

  async function actBlackjack(action: "hit" | "stand") {
    if (!blackjack || busy) return;
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setAnimationKey((key) => key + 1);
    try {
      const [{ data, error: rpcError }] = await Promise.all([
        supabase.rpc("blackjack_action", { p_session_id: blackjack.id, p_action: action }),
        holdAnimation(600),
      ]);
      if (rpcError) { setError(gameError(rpcError.message)); return; }
      const result = data as BlackjackState & { balance?: number };
      if (result.status === "active") { setBlackjack(result); return; }
      setBlackjack(null);
      if (typeof result.balance === "number") setState((current) => current ? { ...current, balance: result.balance! } : current);
      setLastResult({ ok: true, game_key: "blackjack", wager: result.wager, payout: result.payout, net: result.payout - result.wager, result: { status: result.status, player_score: result.player_score, dealer_score: result.dealer_score, player_cards: result.player_cards, dealer_cards: result.dealer_cards }, balance: result.balance ?? currentBalance });
      try { await Promise.all([loadState(), onChanged()]); } catch { setError("Runde verbucht. Wallet-Ansicht konnte nicht aktualisiert werden."); }
    } catch { setError("Die Blackjack-Aktion konnte wegen eines Verbindungsfehlers nicht ausgeführt werden. Versuche es nochmals."); }
    finally { setBusy(false); }
  }

  async function startPoker() {
    if (busy || loading || poker || !currentEnabled) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setHeldPokerCards(new Set()); setAnimationKey((key) => key + 1);
    try {
      const [{ data, error: rpcError }] = await Promise.all([
        supabase.rpc("start_poker", { p_wager: wager }),
        holdAnimation(850),
      ]);
      if (rpcError) { setError(gameError(rpcError.message)); return; }
      const result = data as PokerState & { balance: number };
      setPoker(result);
      setState((current) => current ? { ...current, balance: result.balance } : current);
      try { await Promise.all([loadState(), onChanged()]); } catch { setError("Runde verbucht. Wallet-Ansicht konnte nicht aktualisiert werden."); }
    } catch { setError("Die Poker-Runde konnte wegen eines Verbindungsfehlers nicht gestartet werden. Versuche es nochmals."); }
    finally { setBusy(false); }
  }

  async function playVisualPrank() {
    if (busy || loading || !currentEnabled || selectedGame === "dino_run") return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    const choice = selectedChoice();
    if (!choice) return;
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setAnimationKey((key) => key + 1);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("play_visual_prank_game", {
        p_game_key: selectedGame,
        p_choice: choice,
        p_wager: wager,
      }),
      holdAnimation(1150),
    ]);
    setBusy(false);
    if (rpcError) {
      await loadEffectivePranks();
      setError(gameError(rpcError.message));
      return;
    }
    const result = data as GameResult;
    setBlackjack(null);
    setPoker(null);
    setHeldPokerCards(new Set());
    setLastResult(result);
    setState((current) => current ? { ...current, balance: result.balance } : current);
    await loadState();
  }

  function startSelectedGame() {
    if (selectedGame !== "dino_run" && effectivePrankGames.has(selectedGame)) {
      return playVisualPrank();
    }
    if (selectedGame === "blackjack") return startBlackjack();
    if (selectedGame === "poker") return startPoker();
    if (selectedGame === "dino_run") return startDinoRun();
    return playInstant();
  }

  function togglePokerCard(position: number) {
    if (!poker || busy) return;
    setHeldPokerCards((current) => {
      const next = new Set(current);
      if (next.has(position)) next.delete(position);
      else next.add(position);
      return next;
    });
  }

  async function drawPoker() {
    if (!poker || busy) return;
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setAnimationKey((key) => key + 1);
    const holds = Array.from(heldPokerCards).sort((a, b) => a - b);
    try {
      const [{ data, error: rpcError }] = await Promise.all([
        supabase.rpc("poker_draw", { p_session_id: poker.id, p_hold_positions: holds }),
        holdAnimation(750),
      ]);
      if (rpcError) { setError(gameError(rpcError.message)); return; }
      const result = data as GameResult & PokerState;
      setPoker(null); setHeldPokerCards(new Set()); setLastResult(result);
      setState((current) => current ? { ...current, balance: result.balance } : current);
      try { await Promise.all([loadState(), onChanged()]); } catch { setError("Runde verbucht. Wallet-Ansicht konnte nicht aktualisiert werden."); }
    } catch { setError("Die Poker-Aktion konnte wegen eines Verbindungsfehlers nicht ausgeführt werden. Versuche es nochmals."); }
    finally { setBusy(false); }
  }

  async function startDinoRun() {
    if (busy || loading || dino || !currentEnabled) return;
    if (!dinoCanStart) { setError(`Du brauchst ${DINO_ENTRY_COST} GIBB für den Dino-Run-Eintritt.`); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setDinoRewardNotice("");
    try {
      const { data, error: rpcError } = await supabase.rpc("start_dino_run");
      if (rpcError) { setError(gameError(rpcError.message)); return; }
      const result = data as DinoState;
      dinoSyncChainRef.current = Promise.resolve();
      dinoFinalQueuedRef.current = false;
      dinoRef.current = result;
      setDino(result);
      setState((current) => current ? { ...current, balance: result.balance } : current);
    } catch { setError("Der Dino-Run konnte wegen eines Verbindungsfehlers nicht gestartet werden. Versuche es nochmals."); }
    finally { setBusy(false); }
  }

  function syncDinoScore(score: number, finished: boolean) {
    if (finished && dinoFinalQueuedRef.current) return;
    if (finished) dinoFinalQueuedRef.current = true;
    const sessionId = dinoRef.current?.id;
    if (!sessionId) return;

    dinoSyncChainRef.current = dinoSyncChainRef.current.then(async () => {
      const currentSession = dinoRef.current;
      if (!currentSession || currentSession.id !== sessionId) return;
      const supabase = getSupabase();
      if (!supabase) return;
      const { data, error: rpcError } = await supabase.rpc("sync_dino_run", {
        p_session_id: sessionId,
        p_score: score,
        p_finished: finished,
      });
      if (rpcError) {
        setError(gameError(rpcError.message));
        if (finished) {
          dinoRef.current = null;
          setDino(null);
        }
        return;
      }

      const result = data as DinoState;
      dinoRef.current = result.status === "active" ? { ...currentSession, ...result } : null;
      setDino(dinoRef.current);
      setState((current) => current ? { ...current, balance: result.balance } : current);
      if (result.reward > 0) {
        setDinoRewardNotice(`+${result.reward.toLocaleString("de-CH")} GIBB für ${Math.floor(result.score / 1000).toLocaleString("de-CH")} erreichte 1’000er-Marke${Math.floor(result.score / 1000) === 1 ? "" : "n"}.`);
        await onChanged();
      }

      if (finished || result.status !== "active") {
        setLastResult({
          ok: true,
          game_key: "dino_run",
          wager: result.wager,
          payout: result.total_reward,
          net: result.total_reward - result.wager,
          result: { score: result.score, milestones: Math.floor(result.score / 1000), status: result.status },
          balance: result.balance,
        });
        await Promise.all([loadState(), loadDinoLeaderboard(), result.reward > 0 ? Promise.resolve() : onChanged()]);
      }
    });
  }

  function renderDinoLeaderboard() {
    const entries = dinoLeaderboard?.entries ?? [];
    const myEntry = dinoLeaderboard?.my_entry ?? null;
    const myIsListed = entries.some((entry) => entry.is_me);
    return <aside className="dino-leaderboard" aria-labelledby="dino-leaderboard-title">
      <div className="dino-leaderboard-head">
        <div><span>BESTÄTIGTE LÄUFE</span><strong id="dino-leaderboard-title">Dino Run Leaderboard</strong></div>
        <b>TOP 10</b>
      </div>
      {dinoLeaderboard === null ? <p className="dino-leaderboard-empty">Bestenliste wird geladen …</p> : entries.length === 0 ? <p className="dino-leaderboard-empty">Noch keine abgeschlossenen Läufe. Sei der Erste!</p> : <ol className="dino-leaderboard-list">
        {entries.map((entry) => <li className={entry.is_me ? "is-me" : ""} key={entry.user_id}>
          <span className="dino-leaderboard-rank">{String(entry.rank).padStart(2, "0")}</span>
          <div><strong>{entry.username}{entry.is_me ? " · Du" : ""}</strong><small>{entry.reward_total.toLocaleString("de-CH")} GIBB Prämien</small></div>
          <b>{entry.score.toLocaleString("de-CH")}</b>
        </li>)}
      </ol>}
      {myEntry && !myIsListed && <p className="dino-leaderboard-you">Dein Platz: <strong>#{myEntry.rank}</strong> · {myEntry.score.toLocaleString("de-CH")} Punkte</p>}
      <small className="dino-leaderboard-note">Pro Person zählt der beste serverbestätigte Lauf.</small>
    </aside>;
  }

  function renderStage() {
    if (selectedGame === "dino_run") {
      const finishedScore = lastResult?.game_key === "dino_run" ? Number(lastResult.result.score ?? 0) : 0;
      return <div className="game-stage dino-stage"><div className="dino-playfield">{dino ? <DinoRunner sessionId={dino.id} seed={dino.seed} running={dino.status === "active"} speedLevel={dino.speed_level} difficultyLevel={dino.difficulty_level} onProgress={(score) => syncDinoScore(score, false)} onCrash={(score) => syncDinoScore(score, true)} /> : <div className="dino-ready"><span aria-hidden="true">▰</span><strong>{finishedScore > 0 ? `${finishedScore.toLocaleString("de-CH")} Punkte` : "Bereit für den schweren Lauf"}</strong><p>Der Eintritt kostet 150 GIBB. Danach steigt das Tempo schnell, die Abstände werden enger und alle 1’000 Punkte bringen 100 GIBB.</p></div>}</div>{renderDinoLeaderboard()}</div>;
    }
    if (selectedGame === "roulette") {
      const number = lastResult?.game_key === "roulette" ? Number(lastResult.result.number) : null;
      return <div className="game-stage roulette-stage"><div className={`roulette-wheel ${busy ? "spinning" : ""}`} key={`roulette-${animationKey}`}><div className={`roulette-ball-track ${busy ? "orbiting" : ""}`}><i /></div><span>{number ?? "G"}</span></div><div className="game-outcome">{number !== null ? <><strong className={lastResult?.result.color === "rot" ? "red-result" : ""}>{number}</strong><span>{String(lastResult?.result.color)}</span></> : <span>Server-Roulette · 0 bis 36</span>}</div></div>;
    }
    if (selectedGame === "coin_flip") {
      const side = lastResult?.game_key === "coin_flip" ? String(lastResult.result.side) : "G";
      return <div className="game-stage coin-stage"><div className="coin-energy" aria-hidden="true"><i /><i /><i /></div><div className={`game-coin ${busy ? "flipping" : ""}`} key={`coin-${animationKey}`}><span>{side === "kopf" ? "K" : side === "zahl" ? "Z" : "G"}</span></div><div className="game-outcome"><strong>{side === "G" ? "Bereit" : side === "kopf" ? "Kopf" : "Zahl"}</strong></div></div>;
    }
    if (selectedGame === "dice_duel") {
      const player = Number(lastResult?.result.player ?? 1);
      const house = Number(lastResult?.result.house ?? 1);
      return <div className="game-stage dice-stage"><div><span>Du</span><b aria-label={`Würfel ${player}`} className={busy ? "rolling" : ""} key={`d1-${animationKey}`}>{dieFace(player)}</b></div><i>VS</i><div><span>Haus</span><b aria-label={`Würfel ${house}`} className={busy ? "rolling delay" : ""} key={`d2-${animationKey}`}>{dieFace(house)}</b></div></div>;
    }
    if (selectedGame === "high_card") {
      const player = Number(lastResult?.result.player ?? 1);
      const house = Number(lastResult?.result.house ?? 1);
      return <div className="game-stage high-card-stage" key={`high-card-${animationKey}`}><div><span>DEINE KARTE</span><PlayingCards cards={[player]} /></div><i>VS</i><div><span>HAUS</span><PlayingCards cards={[house]} /></div></div>;
    }
    if (selectedGame === "poker") {
      const finished = lastResult?.game_key === "poker" ? lastResult.result : null;
      const cards = poker?.cards ?? (finished?.cards as number[] | undefined) ?? [];
      const hand = finished?.hand ? String(finished.hand) : null;
      return <div className="game-stage poker-stage" key={`poker-${animationKey}`}><div><span>{poker ? "Karten antippen: halten oder tauschen" : hand ?? "Fünf Karten ziehen und deine Gewinnhand bauen"}</span><PokerCards cards={cards} held={heldPokerCards} disabled={!poker || busy} onToggle={togglePokerCard} /></div>{poker && <p>{heldPokerCards.size} von 5 Karten werden gehalten.</p>}{!poker && cards.length === 0 && <p>Neue Runde starten, Karten halten und einmal neu ziehen.</p>}</div>;
    }
    if (selectedGame === "plinko") {
      const slot = lastResult?.game_key === "plinko" ? Number(lastResult.result.slot) : null;
      const multiplier = lastResult?.game_key === "plinko" ? Number(lastResult.result.multiplier ?? 0) : null;
      return <div className="game-stage plinko-stage" key={`plinko-${animationKey}`}><PlinkoBoard slot={slot} dropping={busy} animationKey={animationKey} /><div className="game-outcome">{multiplier === null ? <span>Kugel starten · 3× an den Außenfächern</span> : <><strong>{multiplier}×</strong><span>Fach {Number(slot) + 1}</span></>}</div></div>;
    }
    if (casinoGameKeys.includes(selectedGame)) {
      const result = lastResult?.game_key === selectedGame ? lastResult.result : null;
      return <div className="game-stage casino-stage"><strong>{result ? String(result.outcome ?? result.result ?? "Runde beendet") : gameName(selectedGame)}</strong><p>{busy ? "Server entscheidet die Runde …" : "Die Runde wird fair und serverseitig ausgelost."}</p></div>;
    }
    const finished = lastResult?.game_key === "blackjack" ? lastResult.result : null;
    const playerCards = blackjack?.player_cards ?? (finished?.player_cards as number[] | undefined) ?? [];
    const dealerCards = blackjack?.dealer_cards ?? (finished?.dealer_cards as number[] | undefined) ?? [];
    return <div className="game-stage blackjack-stage" key={`blackjack-${animationKey}`}><div><span>Bank {blackjack?.dealer_hidden ? "" : finished?.dealer_score ? `· ${finished.dealer_score}` : ""}</span><PlayingCards cards={dealerCards} hidden={Boolean(blackjack?.dealer_hidden)} /></div><div><span>Du · {blackjack?.player_score ?? finished?.player_score ?? 0}</span><PlayingCards cards={playerCards} /></div>{!blackjack && playerCards.length === 0 && <p>Neue Runde starten und zwei Karten erhalten.</p>}</div>;
  }

  const activeGame = games.find((game) => game.key === selectedGame)!;
  return (
    <section className={`card game-center game-theme-${selectedGame} ${busy ? "is-playing" : ""} ${won ? "is-win" : ""} ${lost ? "is-loss" : ""}`} id="game-center">
      <div className="game-ambient" aria-hidden="true"><i /><i /><i /><i /><i /><i /></div>
      <div className="game-center-hero">
        <div><div className="game-live-line"><span className="game-eyebrow">GIBB GAME CENTER</span><b><i /> LIVE</b></div><h2>Spielen. Riskieren. <em>Coins gewinnen.</em></h2><p>Einsätze, Gewinne und Dino-Prämien werden direkt in deinem einzigen GIBB-Wallet verbucht. Es gibt kein separates Spielkonto.</p></div>
        <div className="game-balance"><span>Einziges GIBB Wallet</span><strong>Haupt-Wallet verbunden</strong><i className={centerEnabled ? "online" : ""}>{centerEnabled ? "Live synchronisiert" : "Von Admin deaktiviert"}</i></div>
      </div>

      <div className="game-marquee" aria-hidden="true"><div><span>SERVER FAIR PLAY</span><i>◆</i><span>EIN WALLET</span><i>◆</i><span>SOFORT VERBUCHT</span><i>◆</i><span>NUR GIBB COINS</span><i>◆</i><span>SERVER FAIR PLAY</span><i>◆</i><span>EIN WALLET</span><i>◆</i></div></div>

      {visibleGames.length > 0 && <div className="game-tabs" role="tablist" aria-label="Spiele auswählen">{visibleGames.map((game, index) => { const liveEnabled = centerEnabled && (settings.get(game.key)?.enabled ?? false); return <button role="tab" aria-selected={selectedGame === game.key} className={selectedGame === game.key ? "active" : ""} type="button" key={game.key} onClick={() => chooseGame(game.key)}><u aria-hidden="true">0{index + 1}</u><span aria-hidden="true">{game.icon}</span><b>{game.title}<small>{game.description}</small></b><i className={liveEnabled ? "enabled" : ""}>{liveEnabled ? "AN" : "RUNDE"}</i></button>; })}</div>}

      <div className="game-layout">
        {selectedVisible ? <article className="game-machine">
          <header><div><span>{activeGame.icon}</span><div><h3>{activeGame.title}</h3><p>{activeGame.description}</p></div></div><b>Server Fair Play</b></header>
          <div className="stage-shell" key={`stage-${selectedGame}`}><div className="stage-lights" aria-hidden="true"><i /><i /><i /></div>{renderStage()}<div className="stage-energy" aria-hidden="true"><i /><i /><i /><i /></div><div className="stage-particles" aria-hidden="true">{Array.from({ length: 16 }, (_, index) => <i key={index} />)}</div></div>
          {won && <div className="win-confetti" aria-hidden="true">{Array.from({ length: 22 }, (_, index) => <i key={index} />)}</div>}

          <div className="game-controls">
            {selectedGame === "roulette" && <div className="game-choice"><label htmlFor="roulette-choice">Dein Tipp</label><select id="roulette-choice" className="input" value={rouletteChoice} onChange={(event) => setRouletteChoice(event.target.value)} disabled={busy}><option value="rot">Rot · 2×</option><option value="schwarz">Schwarz · 2×</option>{Array.from({ length: 37 }, (_, number) => <option value={number} key={number}>{number} · 36×</option>)}</select></div>}
            {selectedGame === "coin_flip" && <div className="game-choice coin-choice" role="group" aria-label="Münzseite">{["kopf", "zahl"].map((choice) => <button type="button" className={coinChoice === choice ? "active" : ""} key={choice} onClick={() => setCoinChoice(choice)}>{choice === "kopf" ? "Kopf" : "Zahl"} · 2×</button>)}</div>}
            {selectedGame === "baccarat" && <select className="input" aria-label="Baccarat-Tipp" value={baccaratChoice} onChange={(event) => setBaccaratChoice(event.target.value)} disabled={busy}><option value="spieler">Spieler · 2×</option><option value="bank">Bank · 1,95×</option><option value="unentschieden">Unentschieden · 9×</option></select>}
            {selectedGame === "keno" && <input className="input" value={kenoPicks.join(",")} aria-label="Fünf Keno-Zahlen 1 bis 40" onChange={(event) => setKenoPicks(event.target.value.split(",").map(Number))} disabled={busy} />}
            {selectedGame === "crash" && <input className="input" type="number" min="1.1" max="10" step="0.1" value={crashTarget} aria-label="Crash-Ziel" onChange={(event) => setCrashTarget(Number(event.target.value))} disabled={busy} />}
            {selectedGame === "dino_run" ? <div className="dino-reward-rule"><span>EINTRITT · GARANTIERTE PRÄMIE</span><strong>150 GIBB · 1’000 Punkte = 100 GIBB</strong><small>Einmaliger Eintritt pro Lauf · jede Marke serverseitig nur einmal</small></div> : <div className="wager-choice"><label htmlFor="game-wager">Eigener Eintritt · kein Limit</label><div className="wager-input"><input id="game-wager" className="input" type="number" inputMode="numeric" min={1} step={1} value={wager || ""} onChange={(event) => setWager(Number(event.target.value))} disabled={busy || Boolean(blackjack) || Boolean(poker)} aria-describedby="wager-presets" /><span>GIBB</span></div><div className="wager-presets" id="wager-presets" aria-label="Schnelleinsätze">{wagers.map((value) => <button className={wager === value ? "active" : ""} type="button" disabled={busy || Boolean(blackjack) || Boolean(poker)} key={value} onClick={() => setWager(value)}>{value.toLocaleString("de-CH")}</button>)}<button className={`wager-all-in ${wager === allInWager && allInWager > 0 ? "active" : ""}`} type="button" aria-label={`All-in mit ${allInWager.toLocaleString("de-CH")} GIBB`} disabled={busy || Boolean(blackjack) || Boolean(poker) || allInWager < 1} onClick={() => setWager(allInWager)}>All-in · {allInWager.toLocaleString("de-CH")}</button></div></div>}
            {selectedGame === "blackjack" && blackjack ? <div className="blackjack-actions"><button type="button" className="primary" disabled={busy} onClick={() => void actBlackjack("hit")}>Karte ziehen</button><button type="button" className="secondary" disabled={busy} onClick={() => void actBlackjack("stand")}>Halten</button></div> : selectedGame === "poker" && poker ? <div className="poker-actions"><button type="button" className="primary" disabled={busy} onClick={() => void drawPoker()}>{busy ? "Karten werden gezogen …" : heldPokerCards.size === 5 ? "Hand auswerten" : `${5 - heldPokerCards.size} Karte${5 - heldPokerCards.size === 1 ? "" : "n"} neu ziehen`}</button></div> : <button className="primary game-play" type="button" disabled={busy || loading || !currentEnabled || Boolean(dino) || (selectedGame === "dino_run" && !dinoCanStart)} onClick={() => void startSelectedGame()}><span>{busy ? "Runde läuft …" : loading ? "Wallet wird verbunden …" : selectedGame === "dino_run" ? dino ? "Dino läuft …" : dinoCanStart ? `Dino Run starten · ${DINO_ENTRY_COST} GIBB` : `${DINO_ENTRY_COST} GIBB benötigt` : wagerValid ? `Runde starten · ${wager} GIBB` : "Einsatz eingeben"}</span><i aria-hidden="true">→</i></button>}
          </div>

          <div className={`game-wallet-hint ${selectedGame === "dino_run" ? dino || dinoCanStart ? "ready" : "insufficient" : wagerValid && currentBalance >= wager ? "ready" : "insufficient"}`}><span>{selectedGame === "dino_run" ? dino ? "Lauf aktiv · Eintritt bezahlt" : dinoCanStart ? "150 GIBB Eintritt bereit" : "150 GIBB erforderlich" : !wagerValid ? "Einsatz prüfen" : currentBalance < wager ? "Guthaben reicht noch nicht" : "Bereit zum Spielen"}</span><strong>{new Intl.NumberFormat("de-CH").format(currentBalance)} GIBB im Haupt-Wallet</strong>{selectedGame === "dino_run" ? <small>{dino ? "Jede bestätigte 1’000er-Marke bringt automatisch 100 GIBB." : dinoCanStart ? "Der Server zieht den Eintritt beim Start genau einmal ab." : "Sammle oder empfange zuerst genügend Coins für den Eintritt."}</small> : !wagerValid ? <small>Erlaubt sind positive ganze Beträge ohne feste Obergrenze.</small> : currentBalance < wager && <small>Gib einen kleineren eigenen Betrag ein oder fordere Coins an.</small>}</div>

          {dinoRewardNotice && selectedGame === "dino_run" && <p className="message success-message dino-reward-notice" role="status">✓ {dinoRewardNotice}</p>}
          {lastResult && (lastResult.game_key === "dino_run" ? <div className={`game-result ${lastResult.net > 0 ? "win" : lastResult.net === 0 ? "push" : "loss"}`} role="status"><i className="result-flare" aria-hidden="true" /><div><span>DINO RUN BEENDET</span><strong>{Number(lastResult.result.score ?? 0).toLocaleString("de-CH")} Punkte</strong></div><p>Eintritt {lastResult.wager.toLocaleString("de-CH")} · Prämie {lastResult.payout.toLocaleString("de-CH")} GIBB · Netto {lastResult.net > 0 ? "+" : ""}{lastResult.net}</p></div> : <div className={`game-result ${lastResult.net > 0 ? "win" : lastResult.net === 0 ? "push" : "loss"}`} role="status"><i className="result-flare" aria-hidden="true" /><div><span>{lastResult.net > 0 ? "JACKPOT · GEWONNEN" : lastResult.net === 0 ? "GLEICHSTAND" : "RUNDE BEENDET"}</span><strong>{lastResult.net > 0 ? "+" : ""}{lastResult.net} GIBB</strong></div><p>Einsatz {lastResult.wager} · Auszahlung {lastResult.payout} GIBB</p></div>)}
          {error && <p className="message error game-error" role="alert">{error}</p>}
        </article> : <div className="game-empty-state"><span>{loading ? "↻" : "⊘"}</span><strong>{loading ? "Spiele werden geladen …" : error ? "Spiele konnten nicht geladen werden" : "Aktuell sind keine Spiele aktiv"}</strong><p>{loading ? "Die sicheren Spielschalter werden synchronisiert." : error || "Ein Admin kann Spiele im geschützten Bereich wieder einschalten."}</p>{!loading && error && <button type="button" className="secondary compact" onClick={() => void loadState()}>Erneut laden</button>}</div>}

        <aside className="game-history"><div className="game-history-head"><div><span>LETZTE RUNDEN</span><h3>Deine Spielhistorie</h3></div><b>{state?.recent_rounds.length ?? 0}</b></div><div className="game-history-list">{(state?.recent_rounds ?? []).length === 0 && <p className="empty">Noch keine Runde gespielt.</p>}{(state?.recent_rounds ?? []).map((round) => <article key={round.id}><span className={`history-icon ${round.payout > round.wager ? "won" : ""}`}>{games.find((game) => game.key === round.game_key)?.icon}</span><div><strong>{gameName(round.game_key)}</strong><small>{resultText(round)} · {new Date(round.created_at).toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit" })}</small></div><b className={round.payout > round.wager ? "positive" : round.payout < round.wager ? "negative" : ""}>{round.payout - round.wager > 0 ? "+" : ""}{round.payout - round.wager}</b></article>)}</div><p className="game-rules-note">Nur virtuelle GIBB Coins. Kein Kauf, keine Auszahlung, kein Echtgeld.</p></aside>
      </div>

    </section>
  );
}
