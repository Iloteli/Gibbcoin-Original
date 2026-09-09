"""Konsens-Parameter von GibbCoin (GIBB)."""

COIN = 100_000_000          # 1 GIBB = 100.000.000 Gibbits (wie Satoshi)
SYMBOL = "GIBB"
NAME = "GibbCoin"

# --- Proof of Work -------------------------------------------------------
# Bewusst niedrig gewaehlt: ein normaler Notebook-Kern findet Bloecke.
# Ziel = 2**240  ->  im Schnitt ~65.536 Hashes pro Block.
MAX_TARGET = 2 ** 240
GENESIS_TARGET = MAX_TARGET

TARGET_BLOCK_TIME = 30      # Sekunden
RETARGET_INTERVAL = 20      # Bloecke
MAX_RETARGET_FACTOR = 4     # Difficulty darf pro Retarget max. x4 / :4 springen

# --- Geldpolitik ---------------------------------------------------------
INITIAL_REWARD = 50 * COIN
HALVING_INTERVAL = 210_000  # Bloecke
MAX_SUPPLY = 21_000_000 * COIN

# --- Limits --------------------------------------------------------------
MAX_BLOCK_TXS = 500
MIN_FEE = 1000              # Gibbits pro Transaktion
MAX_FUTURE_DRIFT = 2 * 60   # Sekunden, die ein Block in der Zukunft liegen darf

# --- Netzwerk ------------------------------------------------------------
DEFAULT_PORT = 9333
MAGIC = "gibb-mainnet-1"
GENESIS_MESSAGE = "GibbCoin genesis - minable on a laptop, 2026"
