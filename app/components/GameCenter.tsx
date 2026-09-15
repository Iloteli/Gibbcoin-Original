"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { getSupabase } from "../lib/supabase";
import { DinoRunner } from "./DinoRunner";
import { openUserProfile } from "./UserProfileModal";

type GameKey = "roulette" | "coin_flip" | "blackjack" | "dice_duel" | "high_card" | "poker" | "plinko" | "dino_run" | "slots" | "baccarat" | "keno" | "wheel" | "mines" | "bingo" | "crash";
type LeaderboardPeriod = "today" | "week" | "all";
type SettingKey = "game_center" | GameKey;
type GameSetting = { game_key: SettingKey; label: string; enabled: boolean; updated_at: string };
type GameRound = {
  id: string;
  game_key: GameKey;
  choice: string | null;
  wager: number;
  payout: number;
  result: Record<string, unknown>;
  fairness_hash: string;
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
  period?: LeaderboardPeriod;
  entries: DinoLeaderboardEntry[];
  my_entry: DinoLeaderboardEntry | null;
};
type GameLeaderboardEntry = {
  rank: number;
  user_id: string;
  username: string;
  plays: number;
  wins: number;
  wagered: number;
  payout: number;
  net: number;
  best_score: number;
  is_me: boolean;
};
type GameLeaderboardState = { ok: boolean; game_key: GameKey; period?: LeaderboardPeriod; entries: GameLeaderboardEntry[]; my_entry: GameLeaderboardEntry | null };
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

const games: Array<{ key: GameKey; title: string; icon: string; description: string; minimumProgress?: string }> = [
  { key: "roulette", title: "Roulette", icon: "◎", description: "Setze auf Rot, Schwarz oder eine Zahl." },
  { key: "coin_flip", title: "Münzwurf", icon: "◐", description: "Kopf oder Zahl – ein schneller 50/50-Wurf." },
  { key: "blackjack", title: "Blackjack", icon: "♠", description: "Komme näher an 21 als die Bank." },
  { key: "dice_duel", title: "Würfelduell", icon: "⚄", description: "Der höhere Wurf gewinnt, Gleichstand zahlt zurück." },
  { key: "high_card", title: "High Card", icon: "♦", description: "Ziehe die höhere Karte als das Haus." },
  { key: "poker", title: "5-Karten-Poker", icon: "♣", description: "Halte starke Karten und ziehe den Rest neu." },
  { key: "plinko", title: "Plinko", icon: "●", description: "Lass die Kugel durch das Peg-Feld in ein Gewinnfach fallen." },
  { key: "dino_run", title: "Dino Run", icon: "▰", description: "Steigendes Tempo, enge Hindernisse und sichere Prämien.", minimumProgress: "2.500 Punkte" },
  { key: "slots", title: "Slot Machine", icon: "▦", description: "Drei Walzen und eine sichtbare Gewinn-Tabelle." },
  { key: "baccarat", title: "Baccarat", icon: "♢", description: "Spieler, Bank oder Unentschieden – du entscheidest." },
  { key: "keno", title: "Keno", icon: "⑨", description: "Wähle fünf Zahlen und treffe die Ziehung." },
  { key: "wheel", title: "Glücksrad", icon: "◉", description: "Feste, sichtbare Felder von 0× bis 10×." },
  { key: "mines", title: "Mines", icon: "✦", description: "Drei Minen in neun Feldern – Regeln offen angezeigt." },
  { key: "bingo", title: "Bingo", icon: "▤", description: "Eine Zahl ziehen und den Bingo-Treffer landen." },
  { key: "crash", title: "Crash", icon: "↗", description: "Wähle den Cash-out-Multiplikator rechtzeitig." },
];
const wagers = [1, 10, 50, 100, 500, 1_000, 5_000, 10_000];
const plinkoMultipliers = [3, 1, 0, 0, 0, 0, 0, 1, 3];
const DINO_ENTRY_COST = 150;
const casinoGameKeys: GameKey[] = ["slots", "baccarat", "keno", "wheel", "mines", "bingo", "crash"];
const fairRules: Record<GameKey, string> = {
  roulette: "37 gleich mögliche Zahlen: Rot/Schwarz je 18 von 37 · Einzelzahl 1 von 37.",
  coin_flip: "Kopf und Zahl haben je 50 % Chance · Treffer zahlt 2×.",
  blackjack: "Klassisches Ziel 21 gegen die Bank · Gleichstand zahlt den Einsatz zurück.",
  dice_duel: "Zwei faire Würfel: Gewinn 15/36 · Gleichstand 6/36 · Verlust 15/36.",
  high_card: "Zwei Kartenwerte 1–13: Gewinn 6/13 · Gleichstand 1/13 · Verlust 6/13.",
  poker: "Eine Ziehrunde, sichtbare Handwertung und feste Multiplikatoren.",
  plinko: "9 gleich verteilte Fächer: 2× 3-fach, 2× 1-fach, 5× ohne Auszahlung.",
  dino_run: "150 GIBB Eintritt · je bestätigte 1’000 Punkte 100 GIBB Prämie.",
  slots: "6 Symbole pro Walze · Paar 2× · drei gleiche 8× · drei Siebener 20×.",
  baccarat: "Spieler 2× · Bank 1,95× · Unentschieden 9×.",
  keno: "5 aus 40; Auszahlungen ab 2 Treffern stehen direkt am Spielfeld.",
  wheel: "8 gleich grosse Felder mit sichtbar aufgedruckten Multiplikatoren.",
  mines: "3 Minen in 9 Feldern · ein aufgedecktes sicheres Feld zahlt 2×.",
  bingo: "Eine Zahl aus 75; der feste Bingo-Treffer zahlt 12×.",
  crash: "Das gewählte Ziel wird nur bezahlt, wenn es vor dem serverseitigen Crash liegt.",
};

function gameError(message?: string) {
  if (message?.includes("insufficient_balance")) return "Dein Wallet hat nicht genügend GIBB für diesen Einsatz.";
  if (message?.includes("game_disabled")) return "Dieses Spiel wurde von einem Admin deaktiviert.";
  if (message?.includes("game_too_fast")) return "Kurz warten – die vorige Runde wird noch verbucht.";
  if (message?.includes("global_wager_limit")) return "Dieser Einsatz überschreitet das globale Admin-Limit.";
  if (message?.includes("global_daily_loss_limit")) return "Das globale Tagesverlust-Limit für dein Konto ist erreicht.";
  if (message?.includes("global_or_player_cooldown")) return "Die vorgeschriebene Pause zwischen zwei Runden ist noch nicht vorbei.";
  if (message?.includes("personal_wager_limit") || message?.includes("player_wager_limit")) return "Der Einsatz liegt über deinem persönlichen Spielschutz-Limit.";
  if (message?.includes("daily_loss_limit") || message?.includes("player_daily_loss_limit")) return "Dein persönliches Tagesverlust-Limit ist erreicht.";
  if (message?.includes("game_break_active") || message?.includes("player_break_active")) return "Deine selbst gesetzte Spielpause ist noch aktiv.";
  if (message?.includes("player_cooldown")) return "Deine eingestellte Pause zwischen zwei Runden ist noch nicht vorbei.";
  if (message?.includes("wallet_locked")) return "Dein Konto ist gesperrt und kann nicht spielen.";
  if (message?.includes("blackjack_session_active")) return "Beende zuerst deine laufende Blackjack-Runde.";
  if (message?.includes("blackjack_session")) return "Diese Blackjack-Runde ist nicht mehr aktiv.";
  if (message?.includes("poker_session_active")) return "Beende zuerst deine laufende Poker-Runde.";
  if (message?.includes("poker_session")) return "Diese Poker-Runde ist nicht mehr aktiv.";
  if (message?.includes("invalid_poker_hold")) return "Die gehaltenen Karten konnten nicht sicher übernommen werden.";
  if (message?.includes("dino_score_too_fast")) return "Der Punktestand war schneller als ein echter Lauf und wurde nicht ausgezahlt.";
  if (message?.includes("dino_score")) return "Dieser Dino-Punktestand konnte nicht sicher bestätigt werden.";
  if (message?.includes("dino_session")) return "Dieser Dino-Lauf ist nicht mehr aktiv. Starte einen neuen Lauf.";
  if (message?.includes("invalid_game_choice")) return "Diese Auswahl passt nicht zu den sichtbaren Spielregeln.";
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
  if (round.game_key === "slots") return `${Array.isArray(round.result.symbols) ? (round.result.symbols as unknown[]).map((symbol) => ["🍒", "⭐", "💎", "🔔", "7️⃣", "🍀"][Number(symbol)] ?? "?").join(" ") : "Walzen"} · ${round.result.multiplier ?? 0}×`;
  if (round.game_key === "baccarat") return `${String(round.result.winner ?? "Baccarat")} · ${round.result.player ?? 0}:${round.result.dealer ?? 0}`;
  if (round.game_key === "keno") return `${round.result.hits ?? 0}/5 Treffer · ${round.result.multiplier ?? 0}×`;
  if (round.game_key === "wheel") return `Feld ${Number(round.result.segment ?? 0) + 1} · ${round.result.multiplier ?? 0}×`;
  if (round.game_key === "mines") return `${round.result.safe ? "Sicher" : "Mine"} · ${round.result.multiplier ?? 0}×`;
  if (round.game_key === "bingo") return `Zahl ${round.result.number ?? "?"} · ${round.result.bingo ? "Bingo" : "kein Treffer"}`;
  if (round.game_key === "crash") return `Crash bei ${round.result.crash_at ?? "?"}× · Ziel ${round.result.target ?? "?"}×`;
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
  const [kenoPicks, setKenoPicks] = useState<number[]>([1, 7, 13, 25, 40]);
  const [crashTarget, setCrashTarget] = useState("2");
  const [lastResult, setLastResult] = useState<GameResult | null>(null);
  const [blackjackOutcome, setBlackjackOutcome] = useState<BlackjackState | null>(null);
  const [blackjack, setBlackjack] = useState<BlackjackState | null>(null);
  const [poker, setPoker] = useState<PokerState | null>(null);
  const [dino, setDino] = useState<DinoState | null>(null);
  const [dinoLeaderboard, setDinoLeaderboard] = useState<DinoLeaderboardState | null>(null);
  const [leaderboard, setLeaderboard] = useState<GameLeaderboardState | null>(null);
  const [leaderboardPeriod, setLeaderboardPeriod] = useState<LeaderboardPeriod>("week");
  const [dinoRewardNotice, setDinoRewardNotice] = useState("");
  const [dinoPendingScore, setDinoPendingScore] = useState<number | null>(null);
  const [heldPokerCards, setHeldPokerCards] = useState<Set<number>>(() => new Set());
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [animationKey, setAnimationKey] = useState(0);
  const activeRoundRef = useRef(false);
  const pendingLiveRefreshRef = useRef(false);
  const dinoRef = useRef<DinoState | null>(null);
  const dinoSyncChainRef = useRef<Promise<void>>(Promise.resolve());
  const dinoFinalQueuedRef = useRef(false);
  const leaderboardRequestRef = useRef(0);
  const dinoLeaderboardRequestRef = useRef(0);

  const loadState = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) {
      setError("Die Wallet-Verbindung ist noch nicht bereit. Lade die Spiele erneut.");
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
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
    } catch {
      setError("Die Wallet-Verbindung konnte nicht aktualisiert werden.");
      setLoading(false);
    }
  }, []);

  const loadDinoLeaderboard = useCallback(async () => {
    const supabase = getSupabase();
    if (!supabase) return;
    const requestId = ++dinoLeaderboardRequestRef.current;
    try {
      const { data, error: rpcError } = await supabase.rpc("get_dino_leaderboard", { p_period: leaderboardPeriod });
      if (rpcError || requestId !== dinoLeaderboardRequestRef.current) return;
      const next = data as DinoLeaderboardState | null;
      if (!next?.ok || !Array.isArray(next.entries)) return;
      setDinoLeaderboard({ ok: true, period: leaderboardPeriod, entries: next.entries, my_entry: next.my_entry ?? null });
    } catch {
      if (requestId === dinoLeaderboardRequestRef.current) setDinoLeaderboard(null);
    }
  }, [leaderboardPeriod]);

  const loadLeaderboard = useCallback(async (gameKey: GameKey = selectedGame) => {
    if (gameKey === "dino_run") return;
    const supabase = getSupabase();
    if (!supabase) return;
    const requestId = ++leaderboardRequestRef.current;
    try {
      const { data, error: rpcError } = await supabase.rpc("get_game_leaderboard", { p_game_key: gameKey, p_period: leaderboardPeriod });
      if (rpcError || requestId !== leaderboardRequestRef.current) return;
      const next = data as GameLeaderboardState | null;
      if (!next?.ok || !Array.isArray(next.entries)) return;
      setLeaderboard({ ...next, period: leaderboardPeriod, game_key: gameKey, my_entry: next.my_entry ?? null });
    } catch {
      if (requestId === leaderboardRequestRef.current) setLeaderboard(null);
    }
  }, [leaderboardPeriod, selectedGame]);

  const refreshLeaderboards = useCallback(async () => {
    await Promise.all([loadDinoLeaderboard(), selectedGame === "dino_run" ? Promise.resolve() : loadLeaderboard(selectedGame)]);
  }, [loadDinoLeaderboard, loadLeaderboard, selectedGame]);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadState(), 0);
    return () => window.clearTimeout(timer);
  }, [loadState]);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadDinoLeaderboard(), 0);
    return () => window.clearTimeout(timer);
  }, [loadDinoLeaderboard]);

  useEffect(() => {
    const timer = window.setTimeout(() => void loadLeaderboard(selectedGame), 0);
    return () => window.clearTimeout(timer);
  }, [loadLeaderboard, selectedGame]);

  useEffect(() => {
    const resetTimer = window.setTimeout(() => {
      setLeaderboard(null);
      setDinoLeaderboard(null);
    }, 0);
    const refresh = () => void refreshLeaderboards();
    const timer = window.setInterval(refresh, 30_000);
    window.addEventListener("focus", refresh);
    window.addEventListener("online", refresh);
    return () => {
      window.clearTimeout(resetTimer);
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      window.removeEventListener("online", refresh);
    };
  }, [refreshLeaderboards]);

  useEffect(() => {
    if (!state || activeRoundRef.current) return;
    setState((current) => current && current.balance !== walletBalance ? { ...current, balance: walletBalance } : current);
  }, [state, walletBalance]);

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

  async function playInstant() {
    if (busy || loading || !currentEnabled) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    const choice = selectedGame === "roulette" ? rouletteChoice : selectedGame === "coin_flip" ? coinChoice : "spielen";
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setAnimationKey((key) => key + 1);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("play_instant_game", {
        p_game_key: selectedGame,
        p_choice: choice,
        p_wager: wager,
      }),
      holdAnimation(1150),
    ]);
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as GameResult;
    setLastResult(result);
    setState((current) => current ? { ...current, balance: result.balance } : current);
    await Promise.all([loadState(), onChanged()]);
  }

  async function startBlackjack() {
    if (busy || loading || blackjack || !currentEnabled) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setAnimationKey((key) => key + 1);
    setBlackjackOutcome(null);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("start_blackjack", { p_wager: wager }),
      holdAnimation(850),
    ]);
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as BlackjackState & { balance: number };
    setBlackjack(result.status === "active" ? result : null);
    setBlackjackOutcome(result.status === "active" ? null : result);
    if (typeof result.balance === "number") setState((current) => current ? { ...current, balance: result.balance } : current);
    if (result.status !== "active") {
      setLastResult({
        ok: true,
        game_key: "blackjack",
        wager: result.wager,
        payout: result.payout,
        net: result.payout - result.wager,
        result: {
          status: result.status,
          player_cards: result.player_cards,
          dealer_cards: result.dealer_cards,
          player_score: result.player_score,
          dealer_score: result.dealer_score,
        },
        balance: result.balance,
      });
    }
    await Promise.all([loadState(), onChanged()]);
  }

  async function actBlackjack(action: "hit" | "stand") {
    if (!blackjack || busy) return;
    const supabase = getSupabase();
    if (!supabase) return;
    activeRoundRef.current = true;
    setBusy(true); setError(""); setAnimationKey((key) => key + 1);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("blackjack_action", { p_session_id: blackjack.id, p_action: action }),
      holdAnimation(600),
    ]);
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as BlackjackState & { balance?: number };
    if (result.status === "active") {
      setBlackjack(result);
      setBlackjackOutcome(null);
      return;
    }
    setBlackjack(null);
    setBlackjackOutcome(result);
    if (typeof result.balance === "number") setState((current) => current ? { ...current, balance: result.balance! } : current);
    setLastResult({ ok: true, game_key: "blackjack", wager: result.wager, payout: result.payout, net: result.payout - result.wager, result: { status: result.status, player_score: result.player_score, dealer_score: result.dealer_score, player_cards: result.player_cards, dealer_cards: result.dealer_cards }, balance: result.balance ?? currentBalance });
    await Promise.all([loadState(), onChanged()]);
  }

  async function startPoker() {
    if (busy || loading || poker || !currentEnabled) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setHeldPokerCards(new Set()); setAnimationKey((key) => key + 1);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("start_poker", { p_wager: wager }),
      holdAnimation(850),
    ]);
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as PokerState & { balance: number };
    setPoker(result);
    setState((current) => current ? { ...current, balance: result.balance } : current);
    await Promise.all([loadState(), onChanged()]);
  }

  async function playCasinoGame() {
    if (busy || loading || !currentEnabled || !casinoGameKeys.includes(selectedGame)) return;
    if (!wagerValid) { setError("Gib einen positiven ganzen Einsatz ein."); return; }
    if (currentBalance < wager) { setError("Dein Wallet hat nicht genügend GIBB für diesen Einsatz."); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    const choice = selectedGame === "baccarat"
      ? baccaratChoice
      : selectedGame === "keno"
        ? kenoPicks.join(",")
        : selectedGame === "crash" ? crashTarget : "spielen";
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setAnimationKey((key) => key + 1);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("play_casino_game", { p_game_key: selectedGame, p_choice: choice, p_wager: wager }),
      holdAnimation(1150),
    ]);
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as GameResult;
    setLastResult(result);
    setState((current) => current ? { ...current, balance: result.balance } : current);
    await Promise.all([loadState(), loadLeaderboard(selectedGame), onChanged()]);
  }

  function startSelectedGame() {
    if (selectedGame === "blackjack") return startBlackjack();
    if (selectedGame === "poker") return startPoker();
    if (selectedGame === "dino_run") return startDinoRun();
    if (casinoGameKeys.includes(selectedGame)) return playCasinoGame();
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
    if (!supabase) return;
    activeRoundRef.current = true;
    setBusy(true); setError(""); setAnimationKey((key) => key + 1);
    const holds = Array.from(heldPokerCards).sort((a, b) => a - b);
    const [{ data, error: rpcError }] = await Promise.all([
      supabase.rpc("poker_draw", { p_session_id: poker.id, p_hold_positions: holds }),
      holdAnimation(750),
    ]);
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as GameResult & PokerState;
    setPoker(null); setHeldPokerCards(new Set()); setLastResult(result);
    setState((current) => current ? { ...current, balance: result.balance } : current);
    await Promise.all([loadState(), onChanged()]);
  }

  async function startDinoRun() {
    if (busy || loading || dino || !currentEnabled) return;
    if (!dinoCanStart) { setError(`Du brauchst ${DINO_ENTRY_COST} GIBB für den Dino-Run-Eintritt.`); return; }
    const supabase = getSupabase();
    if (!supabase) { setError("Die Wallet-Verbindung ist noch nicht bereit. Versuche es nochmals."); return; }
    activeRoundRef.current = true;
    setBusy(true); setError(""); setLastResult(null); setDinoRewardNotice("");
    const { data, error: rpcError } = await supabase.rpc("start_dino_run");
    setBusy(false);
    if (rpcError) { setError(gameError(rpcError.message)); return; }
    const result = data as DinoState;
    dinoSyncChainRef.current = Promise.resolve();
    dinoFinalQueuedRef.current = false;
    setDinoPendingScore(null);
    dinoRef.current = result;
    setDino(result);
    setState((current) => current ? { ...current, balance: result.balance } : current);
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
      let data: unknown = null;
      let rpcError: { message?: string } | null = null;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          const response = await supabase.rpc("sync_dino_run", {
            p_session_id: sessionId,
            p_score: score,
            p_finished: finished,
          });
          data = response.data;
          rpcError = response.error;
        } catch (caught) {
          rpcError = { message: caught instanceof Error ? caught.message : "network_error" };
        }
        if (!rpcError) break;
        if (attempt < 2) await new Promise<void>((resolve) => window.setTimeout(resolve, 350 * (attempt + 1)));
      }
      if (rpcError) {
        setDinoPendingScore(score);
        setError(`${gameError(rpcError.message)} Die Dino-Runde bleibt offen und wird beim nächsten Versuch erneut synchronisiert.`);
        return;
      }
      setDinoPendingScore(null);

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
      <div className="leaderboard-periods" role="group" aria-label="Zeitraum der Dino-Bestenliste">{(["today", "week", "all"] as const).map((period) => <button type="button" className={leaderboardPeriod === period ? "active" : ""} key={period} onClick={() => setLeaderboardPeriod(period)}>{period === "today" ? "Heute" : period === "week" ? "Woche" : "Gesamt"}</button>)}</div>
      {dinoLeaderboard === null ? <p className="dino-leaderboard-empty">Bestenliste wird geladen …</p> : entries.length === 0 ? <p className="dino-leaderboard-empty">Noch keine abgeschlossenen Läufe. Sei der Erste!</p> : <ol className="dino-leaderboard-list">
        {entries.map((entry) => <li className={entry.is_me ? "is-me" : ""} key={entry.user_id}>
          <span className="dino-leaderboard-rank">{String(entry.rank).padStart(2, "0")}</span>
          <div><button className="user-profile-link" type="button" onClick={() => openUserProfile(entry.user_id)}><strong>{entry.username}{entry.is_me ? " · Du" : ""}</strong><small>{entry.reward_total.toLocaleString("de-CH")} GIBB Prämien</small></button></div>
          <b>{entry.score.toLocaleString("de-CH")}</b>
        </li>)}
      </ol>}
      {myEntry && !myIsListed && <p className="dino-leaderboard-you">Dein Platz: <strong>#{myEntry.rank}</strong> · {myEntry.score.toLocaleString("de-CH")} Punkte</p>}
      <small className="dino-leaderboard-note">Pro Person zählt der beste serverbestätigte Lauf.</small>
    </aside>;
  }

  function renderLeaderboard() {
    if (selectedGame === "dino_run") return null;
    const entries = leaderboard?.entries ?? [];
    const myEntry = leaderboard?.my_entry;
    const listed = entries.some((entry) => entry.is_me);
    return <aside className="game-leaderboard" aria-labelledby="game-leaderboard-title">
      <div className="game-leaderboard-head"><div><span>ONLINE · SERVERBESTÄTIGT</span><strong id="game-leaderboard-title">{gameName(selectedGame)} Leaderboard</strong></div><b>TOP 10</b></div>
      <div className="leaderboard-periods" role="group" aria-label="Zeitraum der Bestenliste">{(["today", "week", "all"] as const).map((period) => <button type="button" className={leaderboardPeriod === period ? "active" : ""} key={period} onClick={() => setLeaderboardPeriod(period)}>{period === "today" ? "Heute" : period === "week" ? "Woche" : "Gesamt"}</button>)}</div>
      {leaderboard === null ? <p className="game-leaderboard-empty">Bestenliste wird geladen …</p> : entries.length === 0 ? <p className="game-leaderboard-empty">Noch keine abgeschlossenen Runden. Sei der Erste!</p> : <ol className="game-leaderboard-list">
        {entries.map((entry) => <li className={entry.is_me ? "is-me" : ""} key={entry.user_id}><span>{String(entry.rank).padStart(2, "0")}</span><div><button className="user-profile-link" type="button" onClick={() => openUserProfile(entry.user_id)}><strong>{entry.username}{entry.is_me ? " · Du" : ""}</strong><small>{entry.wins.toLocaleString("de-CH")} Gewinne · {entry.plays.toLocaleString("de-CH")} Runden</small></button></div><b className={entry.net >= 0 ? "positive" : "negative"}>{entry.net > 0 ? "+" : ""}{entry.net.toLocaleString("de-CH")}</b></li>)}
      </ol>}
      {myEntry && !listed && <p className="game-leaderboard-you">Dein Platz: <strong>#{myEntry.rank}</strong> · {myEntry.net > 0 ? "+" : ""}{myEntry.net.toLocaleString("de-CH")} GIBB netto</p>}
      <small className="game-leaderboard-note">Sortiert nach Nettoergebnis. Nur Benutzernamen, keine privaten Daten.</small>
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
    if (selectedGame === "slots") {
      const symbols = (lastResult?.game_key === "slots" && Array.isArray(lastResult.result.symbols) ? lastResult.result.symbols : [null, null, null]).map((symbol) => symbol === null ? "?" : ["🍒", "⭐", "💎", "🔔", "7️⃣", "🍀"][Number(symbol)] ?? "?");
      const multiplier = lastResult?.game_key === "slots" ? Number(lastResult.result.multiplier ?? 0) : null;
      return <div className="game-stage casino-stage slots-stage" key={`slots-${animationKey}`}><div className="slot-reels">{symbols.map((symbol, index) => <span className={busy ? "rolling" : ""} key={`${symbol}-${index}`}>{symbol}</span>)}</div><div className="game-outcome">{multiplier === null ? <span>Drei gleiche Symbole bringen die sichtbare Auszahlung</span> : <><strong>{multiplier}×</strong><span>{multiplier > 0 ? "Treffer" : "Kein Treffer"}</span></>}</div><div className="payout-table" aria-label="Slot Gewinn-Tabelle"><span>Paar · 2×</span><span>3 gleiche · 8×</span><span>3× 7️⃣ · 20×</span></div></div>;
    }
    if (selectedGame === "baccarat") {
      const result = lastResult?.game_key === "baccarat" ? lastResult.result : null;
      return <div className="game-stage casino-stage baccarat-stage" key={`baccarat-${animationKey}`}><div className="baccarat-hand"><span>SPIELER</span><strong>{result ? Number(result.player) : "?"}</strong></div><i>VS</i><div className="baccarat-hand"><span>BANK</span><strong>{result ? Number(result.dealer) : "?"}</strong></div><div className="payout-table"><span>Spieler · 2×</span><span>Bank · 1,95×</span><span>Unentschieden · 9×</span></div></div>;
    }
    if (selectedGame === "keno") {
      const result = lastResult?.game_key === "keno" ? lastResult.result : null;
      const draws = Array.isArray(result?.draws) ? result.draws as unknown[] : [];
      return <div className="game-stage casino-stage keno-stage" key={`keno-${animationKey}`}><div className="keno-balls">{(draws.length ? draws : ["?", "?", "?", "?", "?"]).map((number, index) => <span className={busy ? "rolling" : ""} key={`${number}-${index}`}>{String(number)}</span>)}</div><div className="game-outcome">{result ? <><strong>{Number(result.hits ?? 0)}/5</strong><span>Treffer · {Number(result.multiplier ?? 0)}×</span></> : <span>Fünf Zahlen werden gezogen</span>}</div><div className="payout-table"><span>2 Treffer · 1×</span><span>3 · 3×</span><span>4 · 10×</span><span>5 · 25×</span></div></div>;
    }
    if (selectedGame === "wheel") {
      const result = lastResult?.game_key === "wheel" ? lastResult.result : null;
      const wheelFields = ["0×", "0×", "1×", "2×", "0×", "3×", "5×", "10×"];
      return <div className="game-stage casino-stage wheel-stage" key={`wheel-${animationKey}`}><div className={`wheel-disc ${busy ? "spinning" : ""}`}>{wheelFields.map((field, index) => <span className={result && Number(result.segment) === index ? "active" : ""} key={field + index} style={{ transform: `rotate(${index * 45}deg) translateY(-92px) rotate(${-index * 45}deg)` }}>{field}</span>)}</div><div className="game-outcome">{result ? <><strong>{Number(result.multiplier ?? 0)}×</strong><span>Feld {Number(result.segment ?? 0) + 1}</span></> : <span>Feste Felder · jede Auszahlung offen</span>}</div></div>;
    }
    if (selectedGame === "mines") {
      const result = lastResult?.game_key === "mines" ? lastResult.result : null;
      const revealed = result ? Number(result.revealed_field) : null;
      return <div className="game-stage casino-stage mines-stage" key={`mines-${animationKey}`}><div className="mine-grid">{Array.from({ length: 9 }, (_, index) => <span className={revealed === index ? result?.safe ? "safe" : "mine" : ""} key={index}>{revealed === index ? result?.safe ? "◆" : "✹" : "·"}</span>)}</div><div className="game-outcome">{result ? <><strong>{result.safe ? "Sicher · 2×" : "Mine · 0×"}</strong><span>3 Minen in 9 Feldern</span></> : <span>3 Minen · 9 Felder · ein Aufdecken pro Runde</span>}</div></div>;
    }
    if (selectedGame === "bingo") {
      const result = lastResult?.game_key === "bingo" ? lastResult.result : null;
      return <div className="game-stage casino-stage bingo-stage" key={`bingo-${animationKey}`}><div className={`bingo-ball ${busy ? "rolling" : ""}`}>{result ? Number(result.number) : "?"}</div><div className="game-outcome">{result ? <><strong>{result.bingo ? "BINGO! · 12×" : "Noch kein Bingo"}</strong><span>Gezogene Zahl · {Number(result.number)}</span></> : <span>Eine Zahl von 1 bis 75</span>}</div></div>;
    }
    if (selectedGame === "crash") {
      const result = lastResult?.game_key === "crash" ? lastResult.result : null;
      return <div className="game-stage casino-stage crash-stage" key={`crash-${animationKey}`}><div className={`crash-meter ${busy ? "rising" : ""}`}><strong>{result ? `${Number(result.crash_at).toFixed(1)}×` : busy ? "…" : "1.0×"}</strong><span>CRASH</span></div><div className="game-outcome">{result ? <><strong>{result.cashed_out ? `Ausgezahlt bei ${Number(result.target).toFixed(1)}×` : "Zu spät · 0×"}</strong><span>Crash bei {Number(result.crash_at).toFixed(1)}×</span></> : <span>Ziel wählen und vor dem Crash auszahlen</span>}</div></div>;
    }
    const finished = lastResult?.game_key === "blackjack" ? lastResult.result : null;
    const outcome = blackjackOutcome ?? finished;
    const playerCards = blackjack?.player_cards ?? blackjackOutcome?.player_cards ?? (finished?.player_cards as number[] | undefined) ?? [];
    const dealerCards = blackjack?.dealer_cards ?? blackjackOutcome?.dealer_cards ?? (finished?.dealer_cards as number[] | undefined) ?? [];
    const dealerHidden = blackjack?.dealer_hidden ?? false;
    const dealerScore = Number(blackjack?.dealer_score ?? blackjackOutcome?.dealer_score ?? finished?.dealer_score ?? 0);
    const playerScore = Number(blackjack?.player_score ?? blackjackOutcome?.player_score ?? finished?.player_score ?? 0);
    return <div className="game-stage blackjack-stage" key={`blackjack-${animationKey}`}><div><span>Bank {dealerHidden ? "" : dealerScore ? `· ${dealerScore}` : ""}</span><PlayingCards cards={dealerCards} hidden={dealerHidden} /></div><div><span>Du · {playerScore}</span><PlayingCards cards={playerCards} /></div>{!blackjack && playerCards.length === 0 && !Boolean(outcome) && <p>Neue Runde starten und zwei Karten erhalten.</p>}</div>;
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

      {visibleGames.length > 0 && <div className="game-tabs" role="tablist" aria-label="Spiele auswählen">{visibleGames.map((game, index) => { const liveEnabled = centerEnabled && (settings.get(game.key)?.enabled ?? false); return <button role="tab" aria-selected={selectedGame === game.key} className={selectedGame === game.key ? "active" : ""} type="button" key={game.key} onClick={() => chooseGame(game.key)}><u aria-hidden="true">0{index + 1}</u><span aria-hidden="true">{game.icon}</span><b>{game.title}{game.minimumProgress && <small className="game-requirement">Ab {game.minimumProgress}</small>}<small>{game.description}</small></b><i className={liveEnabled ? "enabled" : ""}>{liveEnabled ? "AN" : "RUNDE"}</i></button>; })}</div>}

      <div className="game-layout">
        {selectedVisible ? <article className="game-machine">
          <header><div><span>{activeGame.icon}</span><div><h3>{activeGame.title}{activeGame.minimumProgress && <small className="game-requirement">Ab {activeGame.minimumProgress}</small>}</h3><p>{activeGame.description}</p></div></div><b>Server Fair Play</b></header>
          <div className="stage-shell" key={`stage-${selectedGame}`}><div className="stage-lights" aria-hidden="true"><i /><i /><i /></div>{renderStage()}<div className="stage-energy" aria-hidden="true"><i /><i /><i /><i /></div><div className="stage-particles" aria-hidden="true">{Array.from({ length: 16 }, (_, index) => <i key={index} />)}</div></div>
          {won && <div className="win-confetti" aria-hidden="true">{Array.from({ length: 22 }, (_, index) => <i key={index} />)}</div>}

          <div className="game-controls">
            {selectedGame === "roulette" && <div className="game-choice"><label htmlFor="roulette-choice">Dein Tipp</label><select id="roulette-choice" className="input" value={rouletteChoice} onChange={(event) => setRouletteChoice(event.target.value)} disabled={busy}><option value="rot">Rot · 2×</option><option value="schwarz">Schwarz · 2×</option>{Array.from({ length: 37 }, (_, number) => <option value={number} key={number}>{number} · 36×</option>)}</select></div>}
            {selectedGame === "coin_flip" && <div className="game-choice coin-choice" role="group" aria-label="Münzseite">{["kopf", "zahl"].map((choice) => <button type="button" className={coinChoice === choice ? "active" : ""} key={choice} onClick={() => setCoinChoice(choice)}>{choice === "kopf" ? "Kopf" : "Zahl"} · 2×</button>)}</div>}
            {selectedGame === "baccarat" && <div className="game-choice"><label htmlFor="baccarat-choice">Dein Tipp</label><select id="baccarat-choice" className="input" value={baccaratChoice} onChange={(event) => setBaccaratChoice(event.target.value)} disabled={busy}><option value="spieler">Spieler · 2×</option><option value="bank">Bank · 1,95×</option><option value="unentschieden">Unentschieden · 9×</option></select></div>}
            {selectedGame === "keno" && <div className="game-choice keno-choice"><label>Wähle 5 Zahlen · {kenoPicks.length}/5</label><div className="keno-picker">{Array.from({ length: 40 }, (_, index) => { const number = index + 1; const active = kenoPicks.includes(number); return <button type="button" className={active ? "active" : ""} disabled={busy || (!active && kenoPicks.length >= 5)} key={number} onClick={() => setKenoPicks((current) => active ? current.filter((pick) => pick !== number) : [...current, number])}>{number}</button>; })}</div><small>2 Treffer 1× · 3 Treffer 3× · 4 Treffer 10× · 5 Treffer 25×</small></div>}
            {selectedGame === "crash" && <div className="game-choice"><label htmlFor="crash-target">Cash-out-Ziel</label><select id="crash-target" className="input" value={crashTarget} onChange={(event) => setCrashTarget(event.target.value)} disabled={busy}><option value="1.5">1,5×</option><option value="2">2×</option><option value="3">3×</option><option value="5">5×</option><option value="8">8×</option></select><small>Erreichst du das Ziel vor dem Crash, wird Einsatz × Ziel ausgezahlt.</small></div>}
            {selectedGame === "dino_run" ? <div className="dino-reward-rule"><span>EINTRITT · GARANTIERTE PRÄMIE</span><strong>150 GIBB · 1’000 Punkte = 100 GIBB</strong><small>Einmaliger Eintritt pro Lauf · jede Marke serverseitig nur einmal</small></div> : <div className="wager-choice"><label htmlFor="game-wager">Eigener Einsatz · persönliche Limits gelten</label><div className="wager-input"><input id="game-wager" className="input" type="number" inputMode="numeric" min={1} step={1} value={wager || ""} onChange={(event) => setWager(Number(event.target.value))} disabled={busy || Boolean(blackjack) || Boolean(poker)} aria-describedby="wager-presets" /><span>GIBB</span></div><div className="wager-presets" id="wager-presets" aria-label="Schnelleinsätze">{wagers.map((value) => <button className={wager === value ? "active" : ""} type="button" disabled={busy || Boolean(blackjack) || Boolean(poker)} key={value} onClick={() => setWager(value)}>{value.toLocaleString("de-CH")}</button>)}<button className={`wager-all-in ${wager === allInWager && allInWager > 0 ? "active" : ""}`} type="button" aria-label={`All-in mit ${allInWager.toLocaleString("de-CH")} GIBB`} disabled={busy || Boolean(blackjack) || Boolean(poker) || allInWager < 1} onClick={() => setWager(allInWager)}>All-in · {allInWager.toLocaleString("de-CH")}</button></div></div>}
            {selectedGame === "blackjack" && blackjack ? <div className="blackjack-actions"><button type="button" className="primary" disabled={busy} onClick={() => void actBlackjack("hit")}>Karte ziehen</button><button type="button" className="secondary" disabled={busy} onClick={() => void actBlackjack("stand")}>Halten</button></div> : selectedGame === "poker" && poker ? <div className="poker-actions"><button type="button" className="primary" disabled={busy} onClick={() => void drawPoker()}>{busy ? "Karten werden gezogen …" : heldPokerCards.size === 5 ? "Hand auswerten" : `${5 - heldPokerCards.size} Karte${5 - heldPokerCards.size === 1 ? "" : "n"} neu ziehen`}</button></div> : <button className="primary game-play" type="button" disabled={busy || loading || !currentEnabled || Boolean(dino) || (selectedGame === "dino_run" && !dinoCanStart) || (selectedGame === "keno" && kenoPicks.length !== 5)} onClick={() => void startSelectedGame()}><span>{busy ? "Runde läuft …" : loading ? "Wallet wird verbunden …" : selectedGame === "dino_run" ? dino ? "Dino läuft …" : dinoCanStart ? `Dino Run starten · ${DINO_ENTRY_COST} GIBB` : `${DINO_ENTRY_COST} GIBB benötigt` : selectedGame === "keno" && kenoPicks.length !== 5 ? "5 Zahlen wählen" : wagerValid ? `Runde starten · ${wager} GIBB` : "Einsatz eingeben"}</span><i aria-hidden="true">→</i></button>}
          </div>

          <div className={`game-wallet-hint ${selectedGame === "dino_run" ? dino || dinoCanStart ? "ready" : "insufficient" : wagerValid && currentBalance >= wager ? "ready" : "insufficient"}`}><span>{selectedGame === "dino_run" ? dino ? "Lauf aktiv · Eintritt bezahlt" : dinoCanStart ? "150 GIBB Eintritt bereit" : "150 GIBB erforderlich" : !wagerValid ? "Einsatz prüfen" : currentBalance < wager ? "Guthaben reicht noch nicht" : "Bereit zum Spielen"}</span><strong>{new Intl.NumberFormat("de-CH").format(currentBalance)} GIBB im Haupt-Wallet</strong>{selectedGame === "dino_run" ? <small>{dino ? "Jede bestätigte 1’000er-Marke bringt automatisch 100 GIBB." : dinoCanStart ? "Der Server zieht den Eintritt beim Start genau einmal ab." : "Sammle oder empfange zuerst genügend Coins für den Eintritt."}</small> : !wagerValid ? <small>Erlaubt sind positive ganze Beträge innerhalb deiner Spielschutz-Limits.</small> : currentBalance < wager && <small>Gib einen kleineren eigenen Betrag ein oder fordere Coins an.</small>}</div>

          <details className="fair-rules"><summary>Regeln, Chancen &amp; Fairness</summary><p>{fairRules[selectedGame]}</p><small>Ergebnisse entstehen serverseitig mit festen Regeln. Es gibt keine versteckten personenbezogenen Gewinnchancen. Jede abgeschlossene Runde erhält einen SHA-256-Prüfcode.</small></details>

          {dinoRewardNotice && selectedGame === "dino_run" && <p className="message success-message dino-reward-notice" role="status">✓ {dinoRewardNotice}</p>}
          {dinoPendingScore !== null && selectedGame === "dino_run" && <button type="button" className="secondary compact" onClick={() => { dinoFinalQueuedRef.current = false; syncDinoScore(dinoPendingScore, true); }}>Dino-Ergebnis erneut synchronisieren</button>}
          {lastResult && (lastResult.game_key === "dino_run" ? <div className={`game-result ${lastResult.net > 0 ? "win" : lastResult.net === 0 ? "push" : "loss"}`} role="status"><i className="result-flare" aria-hidden="true" /><div><span>DINO RUN BEENDET</span><strong>{Number(lastResult.result.score ?? 0).toLocaleString("de-CH")} Punkte</strong></div><p>Eintritt {lastResult.wager.toLocaleString("de-CH")} · Prämie {lastResult.payout.toLocaleString("de-CH")} GIBB · Netto {lastResult.net > 0 ? "+" : ""}{lastResult.net}</p></div> : <div className={`game-result ${lastResult.net > 0 ? "win" : lastResult.net === 0 ? "push" : "loss"}`} role="status"><i className="result-flare" aria-hidden="true" /><div><span>{lastResult.net > 0 ? "JACKPOT · GEWONNEN" : lastResult.net === 0 ? "GLEICHSTAND" : "RUNDE BEENDET"}</span><strong>{lastResult.net > 0 ? "+" : ""}{lastResult.net} GIBB</strong></div><p>Einsatz {lastResult.wager} · Auszahlung {lastResult.payout} GIBB</p></div>)}
          {error && <p className="message error game-error" role="alert">{error}</p>}
        </article> : <div className="game-empty-state"><span>{loading ? "↻" : "⊘"}</span><strong>{loading ? "Spiele werden geladen …" : error ? "Spiele konnten nicht geladen werden" : "Aktuell sind keine Spiele aktiv"}</strong><p>{loading ? "Die sicheren Spielschalter werden synchronisiert." : error || "Ein Admin kann Spiele im geschützten Bereich wieder einschalten."}</p>{!loading && error && <button type="button" className="secondary compact" onClick={() => void loadState()}>Erneut laden</button>}</div>}

        {renderLeaderboard()}
        <aside className="game-history"><div className="game-history-head"><div><span>LETZTE RUNDEN</span><h3>Deine Spielhistorie</h3></div><b>{state?.recent_rounds.length ?? 0}</b></div><div className="game-history-list">{(state?.recent_rounds ?? []).length === 0 && <p className="empty">Noch keine Runde gespielt.</p>}{(state?.recent_rounds ?? []).map((round) => <article key={round.id}><span className={`history-icon ${round.payout > round.wager ? "won" : ""}`}>{games.find((game) => game.key === round.game_key)?.icon}</span><div><strong>{gameName(round.game_key)}</strong><small>{resultText(round)} · {new Date(round.created_at).toLocaleTimeString("de-CH", { hour: "2-digit", minute: "2-digit" })}</small><small title={round.fairness_hash}>Prüfcode #{round.fairness_hash.slice(0, 10)}</small></div><b className={round.payout > round.wager ? "positive" : round.payout < round.wager ? "negative" : ""}>{round.payout - round.wager > 0 ? "+" : ""}{round.payout - round.wager}</b></article>)}</div><p className="game-rules-note">Nur virtuelle GIBB Coins. Kein Kauf, keine Auszahlung, kein Echtgeld.</p></aside>
      </div>

    </section>
  );
}
