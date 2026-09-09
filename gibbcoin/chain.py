"""Die GibbCoin-Blockchain: Validierung, Zustand, Difficulty und Persistenz."""

from __future__ import annotations

import json
import os
import time
from typing import Iterable

from .block import Block
from .params import (
    COIN,
    GENESIS_MESSAGE,
    GENESIS_TARGET,
    HALVING_INTERVAL,
    INITIAL_REWARD,
    MAGIC,
    MAX_BLOCK_TXS,
    MAX_FUTURE_DRIFT,
    MAX_RETARGET_FACTOR,
    MAX_SUPPLY,
    MAX_TARGET,
    RETARGET_INTERVAL,
    TARGET_BLOCK_TIME,
)
from .transaction import Transaction, coinbase

GENESIS_TIMESTAMP = 1767225600  # 2026-01-01 00:00:00 UTC


class ValidationError(Exception):
    """Ein Block oder eine Transaktion verstoesst gegen die Konsensregeln."""


def block_reward(height: int) -> int:
    halvings = height // HALVING_INTERVAL
    if halvings >= 64:
        return 0
    return INITIAL_REWARD >> halvings


def work(target: int) -> int:
    return (1 << 256) // (target + 1)


class Blockchain:
    def __init__(self, path: str | None = None):
        self.path = path
        self.blocks: list[Block] = []
        self.balances: dict[str, int] = {}
        self.nonces: dict[str, int] = {}
        self.mempool: dict[str, Transaction] = {}

        if path and os.path.exists(path):
            self.load()
        else:
            self.blocks = [self.genesis_block()]
            self._apply(self.blocks[0])

    # --- Genesis ----------------------------------------------------------

    @staticmethod
    def genesis_block() -> Block:
        return Block(
            height=0,
            previous_hash="00" * 32,
            transactions=[],
            timestamp=GENESIS_TIMESTAMP,
            target=GENESIS_TARGET,
            nonce=0,
        )

    # --- Zugriff ----------------------------------------------------------

    @property
    def tip(self) -> Block:
        return self.blocks[-1]

    @property
    def height(self) -> int:
        return self.tip.height

    @property
    def total_work(self) -> int:
        return sum(work(b.target) for b in self.blocks)

    @property
    def supply(self) -> int:
        return sum(self.balances.values())

    def balance_of(self, address: str) -> int:
        return self.balances.get(address, 0)

    def next_nonce(self, address: str) -> int:
        confirmed = self.nonces.get(address, 0)
        pending = [tx.nonce + 1 for tx in self.mempool.values() if tx.sender == address]
        return max([confirmed] + pending)

    def history(self, address: str) -> list[dict]:
        out = []
        for block in self.blocks:
            for tx in block.transactions:
                if address in (tx.sender, tx.recipient):
                    entry = tx.to_dict()
                    entry["height"] = block.height
                    out.append(entry)
        return out

    # --- Difficulty -------------------------------------------------------

    def next_target(self) -> int:
        height = self.height + 1
        if height % RETARGET_INTERVAL != 0 or len(self.blocks) <= RETARGET_INTERVAL:
            return self.tip.target

        first = self.blocks[-RETARGET_INTERVAL]
        elapsed = max(1, self.tip.timestamp - first.timestamp)
        expected = TARGET_BLOCK_TIME * RETARGET_INTERVAL
        elapsed = min(
            max(elapsed, expected // MAX_RETARGET_FACTOR),
            expected * MAX_RETARGET_FACTOR,
        )
        return min(self.tip.target * elapsed // expected, MAX_TARGET)

    # --- Transaktionen ----------------------------------------------------

    def add_transaction(self, tx: Transaction) -> bool:
        """Nimmt eine Transaktion in den Mempool. True, wenn sie neu ist."""
        if tx.is_coinbase:
            raise ValidationError("Coinbase gehoert nicht in den Mempool")
        if not tx.is_valid():
            raise ValidationError("Signatur oder Aufbau ungueltig")

        txid = tx.txid()
        if txid in self.mempool:
            return False
        if any(txid == t.txid() for b in self.blocks for t in b.transactions):
            return False
        if tx.nonce < self.nonces.get(tx.sender, 0):
            raise ValidationError("Nonce bereits verbraucht")

        spendable = self.balance_of(tx.sender) - sum(
            t.amount + t.fee for t in self.mempool.values() if t.sender == tx.sender
        )
        if tx.amount + tx.fee > spendable:
            raise ValidationError("Guthaben reicht nicht")

        self.mempool[txid] = tx
        return True

    def select_transactions(self) -> list[Transaction]:
        """Waehlt Mempool-Transaktionen fuer den naechsten Block aus."""
        by_sender: dict[str, list[Transaction]] = {}
        for tx in self.mempool.values():
            by_sender.setdefault(tx.sender, []).append(tx)

        chosen: list[Transaction] = []
        for sender, txs in by_sender.items():
            txs.sort(key=lambda t: t.nonce)
            nonce = self.nonces.get(sender, 0)
            budget = self.balance_of(sender)
            for tx in txs:
                if tx.nonce != nonce or tx.amount + tx.fee > budget:
                    break
                chosen.append(tx)
                nonce += 1
                budget -= tx.amount + tx.fee

        chosen.sort(key=lambda t: (-t.fee, t.timestamp))
        return chosen[: MAX_BLOCK_TXS - 1]

    # --- Blockbau ---------------------------------------------------------

    def candidate_block(self, miner_address: str) -> Block:
        txs = self.select_transactions()
        fees = sum(tx.fee for tx in txs)
        height = self.height + 1
        reward = block_reward(height) + fees
        memo = GENESIS_MESSAGE if height == 1 else ""
        cb = coinbase(miner_address, reward, height, memo)
        return Block(
            height=height,
            previous_hash=self.tip.hash(),
            transactions=[cb] + txs,
            timestamp=int(time.time()),
            target=self.next_target(),
            nonce=0,
        )

    # --- Validierung ------------------------------------------------------

    def validate_block(self, block: Block, prev: Block, state: dict, nonces: dict) -> None:
        if block.height != prev.height + 1:
            raise ValidationError(f"falsche Hoehe: {block.height}")
        if block.previous_hash != prev.hash():
            raise ValidationError("previous_hash passt nicht")
        if block.timestamp > time.time() + MAX_FUTURE_DRIFT:
            raise ValidationError("Zeitstempel liegt zu weit in der Zukunft")
        if block.timestamp < self._median_time_past(block.height):
            raise ValidationError("Zeitstempel liegt vor der Median-Zeit")
        if block.target > MAX_TARGET:
            raise ValidationError("Ziel ist leichter als erlaubt")
        if not block.meets_target():
            raise ValidationError("Proof of Work erfuellt das Ziel nicht")
        if len(block.transactions) > MAX_BLOCK_TXS:
            raise ValidationError("zu viele Transaktionen")
        if not block.transactions or not block.transactions[0].is_coinbase:
            raise ValidationError("erste Transaktion muss Coinbase sein")
        if any(tx.is_coinbase for tx in block.transactions[1:]):
            raise ValidationError("mehr als eine Coinbase")

        fees = sum(tx.fee for tx in block.transactions[1:])
        cb = block.transactions[0]
        if cb.amount > block_reward(block.height) + fees:
            raise ValidationError("Coinbase zahlt zu viel aus")
        if sum(state.values()) + cb.amount > MAX_SUPPLY:
            raise ValidationError("Maximalmenge ueberschritten")

        seen: set[str] = set()
        for tx in block.transactions:
            txid = tx.txid()
            if txid in seen:
                raise ValidationError("doppelte Transaktion im Block")
            seen.add(txid)
            if not tx.is_valid():
                raise ValidationError(f"ungueltige Transaktion {txid[:12]}")
            if tx.is_coinbase:
                continue
            if tx.nonce != nonces.get(tx.sender, 0):
                raise ValidationError(f"falsche Nonce fuer {tx.sender[:10]}")
            if state.get(tx.sender, 0) < tx.amount + tx.fee:
                raise ValidationError(f"Guthaben von {tx.sender[:10]} reicht nicht")
            state[tx.sender] = state.get(tx.sender, 0) - tx.amount - tx.fee
            state[tx.recipient] = state.get(tx.recipient, 0) + tx.amount
            nonces[tx.sender] = tx.nonce + 1

        state[cb.recipient] = state.get(cb.recipient, 0) + cb.amount

    def _median_time_past(self, height: int) -> int:
        window = self.blocks[max(0, height - 12) : height]
        if not window:
            return 0
        stamps = sorted(b.timestamp for b in window)
        return stamps[len(stamps) // 2]

    # --- Anhaengen --------------------------------------------------------

    def add_block(self, block: Block, persist: bool = True) -> bool:
        if block.hash() == self.tip.hash():
            return False
        state = dict(self.balances)
        nonces = dict(self.nonces)
        self.validate_block(block, self.tip, state, nonces)

        self.blocks.append(block)
        self.balances = {k: v for k, v in state.items() if v}
        self.nonces = nonces
        for tx in block.transactions:
            self.mempool.pop(tx.txid(), None)
        if persist:
            self.save()
        return True

    def _apply(self, block: Block) -> None:
        for tx in block.transactions:
            if not tx.is_coinbase:
                self.balances[tx.sender] = (
                    self.balances.get(tx.sender, 0) - tx.amount - tx.fee
                )
                self.nonces[tx.sender] = tx.nonce + 1
            self.balances[tx.recipient] = self.balances.get(tx.recipient, 0) + tx.amount

    # --- Reorg ------------------------------------------------------------

    def replace_chain(self, blocks: Iterable[dict]) -> bool:
        """Uebernimmt eine fremde Kette, wenn sie gueltig ist und mehr Arbeit hat."""
        candidate = Blockchain()
        incoming = [Block.from_dict(b) for b in blocks]
        if not incoming or incoming[0].hash() != candidate.blocks[0].hash():
            raise ValidationError("fremder Genesis-Block passt nicht")

        for block in incoming[1:]:
            candidate.add_block(block, persist=False)

        if candidate.total_work <= self.total_work:
            return False

        known = {tx.txid() for b in candidate.blocks for tx in b.transactions}
        self.blocks = candidate.blocks
        self.balances = candidate.balances
        self.nonces = candidate.nonces
        self.mempool = {k: v for k, v in self.mempool.items() if k not in known}
        self.save()
        return True

    # --- Persistenz -------------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "magic": MAGIC,
            "height": self.height,
            "blocks": [b.to_dict() for b in self.blocks],
            "mempool": [t.to_dict() for t in self.mempool.values()],
        }

    def save(self) -> None:
        if not self.path:
            return
        directory = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(directory, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.to_dict(), fh)
        os.replace(tmp, self.path)

    def load(self) -> None:
        with open(self.path, encoding="utf-8") as fh:
            data = json.load(fh)
        self.blocks = [self.genesis_block()]
        self.balances, self.nonces = {}, {}
        self._apply(self.blocks[0])
        for raw in data["blocks"][1:]:
            self.add_block(Block.from_dict(raw), persist=False)

        # unbestaetigte Transaktionen wiederherstellen; was inzwischen
        # ungueltig geworden ist, faellt einfach weg
        for raw in data.get("mempool", []):
            try:
                self.add_transaction(Transaction.from_dict(raw))
            except (ValidationError, ValueError, KeyError):
                continue

    def info(self) -> dict:
        return {
            "name": "GibbCoin",
            "symbol": "GIBB",
            "height": self.height,
            "tip": self.tip.hash(),
            "difficulty": round(self.tip.difficulty, 4),
            "next_target": hex(self.next_target()),
            "block_reward": block_reward(self.height + 1) / COIN,
            "supply": self.supply / COIN,
            "max_supply": MAX_SUPPLY / COIN,
            "mempool": len(self.mempool),
            "total_work": self.total_work,
        }
