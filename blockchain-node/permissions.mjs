// Rechte für Basic-Konten: jede Funktion einzeln ein-/ausschaltbar.
// s:<key> = Einstellung der Chain-Seite, w:<key> = Einstellung für die Hauptseite, a:<name> = Aktion.
export const PERMISSION_CATALOG = [
  { group: "⛏ Mining", items: [
    ["s:reward", "Belohnung pro Block"], ["s:targetSeconds", "Ziel-Blockzeit"], ["s:maxTxPerBlock", "Max. Transaktionen pro Block"],
    ["s:difficultyBits", "Schwierigkeit jetzt"], ["s:minBits", "Min. Schwierigkeit"], ["s:maxBits", "Max. Schwierigkeit"], ["s:autoAdjust", "Schwierigkeit automatisch"],
  ] },
  { group: "📏 Mining-Regeln", items: [
    ["w:miningEnabled", "Mining an/aus"], ["w:cooldownSeconds", "Pause pro Miner"], ["w:halvingBlocks", "Belohnung halbieren"],
    ["w:maxBlocksPerDay", "Max. Blöcke pro Tag"], ["w:requireRealTx", "Nur mit echten Transaktionen"],
  ] },
  { group: "📈 Markt & Coinwert", items: [
    ["s:marketEnabled", "Markt an/aus"], ["w:buyEnabled", "Kaufen erlaubt"], ["w:sellEnabled", "Verkaufen erlaubt"],
    ["s:websitePrice", "Kurs jetzt setzen"], ["w:minPrice", "Mindestkurs"], ["w:maxPrice", "Höchstkurs"], ["w:marketStepPercent", "Kursänderung pro GIBB"],
    ["s:tradingFeePercent", "Handelsgebühr"], ["w:maxTrade", "Max. GIBB pro Handel"], ["w:dailySellLimit", "Verkaufslimit pro Person"],
    ["s:startPrice", "Startpreis Chain-Markt"], ["s:startingCash", "Startguthaben Chain-Wallets"], ["s:minOrderAmount", "Min. Ordermenge"],
  ] },
  { group: "🗂 Tabs & 💳 Zahlarten", items: [
    ["w:disabledTabs", "Tabs der Hauptseite ein/aus"], ["w:cardEnabled", "Karte / TWINT an/aus"], ["w:creditsEnabled", "Mit Credits kaufen an/aus"],
  ] },
  { group: "🖥 Server", items: [
    ["s:fallbackMinerEnabled", "Reserve-Miner an/aus"], ["s:fallbackDelaySeconds", "Reserve-Miner Einsprung"], ["s:browserMinerThreads", "Browser-Miner Kerne"],
  ] },
  { group: "⚙ Aktionen", items: [
    ["a:miner", "Server-Miner starten/stoppen"], ["a:verify", "Kette prüfen"], ["a:bank", "Banküberweisungen bestätigen"],
  ] },
  { group: "🛡 Verwaltung der Hauptseite", items: [
    ["a:accounts", "Konten ansehen, bannen, Passwort-Reset, Fun-Rang"], ["a:accountsCreate", "Neue Konten erstellen"], ["a:accountsDelete", "Konten löschen"],
    ["a:coins", "Coins geben und abziehen"], ["a:games", "Spiele verwalten"], ["a:tools", "Tools & Support-Fälle"],
    ["a:audit", "Protokoll ansehen"], ["a:visitors", "Besucher-Statistik"],
  ] },
];

export const ALL_PERMISSIONS = PERMISSION_CATALOG.flatMap((g) => g.items.map(([id]) => id));

// Frühere Gruppen-Rechte (bis Okt. 2026) in einzelne Rechte übersetzen
const LEGACY = {
  mining: ["s:reward", "s:targetSeconds", "s:maxTxPerBlock", "s:difficultyBits", "s:minBits", "s:maxBits", "s:autoAdjust"],
  rules: ["w:miningEnabled", "w:cooldownSeconds", "w:halvingBlocks", "w:maxBlocksPerDay", "w:requireRealTx"],
  market: ["s:marketEnabled", "w:buyEnabled", "w:sellEnabled", "s:websitePrice", "w:minPrice", "w:maxPrice", "w:marketStepPercent", "s:tradingFeePercent", "w:maxTrade", "w:dailySellLimit", "s:startPrice", "s:startingCash", "s:minOrderAmount"],
  tabs: ["w:disabledTabs"],
  payments: ["w:cardEnabled", "w:creditsEnabled"],
  server: ["s:fallbackMinerEnabled", "s:fallbackDelaySeconds", "s:browserMinerThreads"],
  miner: ["a:miner"], verify: ["a:verify"], bank: ["a:bank"],
};

export function normalizePermissions(list) {
  if (!Array.isArray(list)) return [];
  const out = new Set();
  for (const raw of list) {
    const id = String(raw);
    if (LEGACY[id]) LEGACY[id].forEach((p) => out.add(p));
    else if (ALL_PERMISSIONS.includes(id)) out.add(id);
  }
  return [...out];
}

export const DEFAULT_BASIC_PERMISSIONS = normalizePermissions(["mining", "rules", "market", "tabs", "payments", "server", "miner", "verify"]);
