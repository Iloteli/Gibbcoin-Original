"""GibbCoin - eine schlanke, CPU-minebare Blockchain ohne Abhaengigkeiten."""

from .block import Block
from .chain import Blockchain, ValidationError, block_reward
from .miner import mine_block, mine_forever
from .node import Node
from .params import COIN, NAME, SYMBOL
from .transaction import Transaction
from .wallet import Wallet

__version__ = "1.0.0"
__all__ = [
    "Block",
    "Blockchain",
    "Node",
    "Transaction",
    "Wallet",
    "ValidationError",
    "block_reward",
    "mine_block",
    "mine_forever",
    "COIN",
    "NAME",
    "SYMBOL",
    "__version__",
]
