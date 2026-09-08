"""A small, deterministic blockchain implementation for learning purposes."""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class Transaction:
    sender: str
    recipient: str
    amount: int
    timestamp: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "sender": self.sender,
            "recipient": self.recipient,
            "amount": self.amount,
            "timestamp": self.timestamp,
        }


@dataclass(frozen=True)
class Block:
    index: int
    timestamp: str
    transactions: tuple[Transaction, ...]
    miner: str
    previous_hash: str
    nonce: int
    hash: str

    def calculate_hash(self) -> str:
        payload = {
            "index": self.index,
            "timestamp": self.timestamp,
            "transactions": [transaction.as_dict() for transaction in self.transactions],
            "miner": self.miner,
            "previous_hash": self.previous_hash,
            "nonce": self.nonce,
        }
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def as_dict(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "timestamp": self.timestamp,
            "transactions": [transaction.as_dict() for transaction in self.transactions],
            "miner": self.miner,
            "previous_hash": self.previous_hash,
            "nonce": self.nonce,
            "hash": self.hash,
        }


class Blockchain:
    """An append-only chain secured by hashes and proof-of-work."""

    def __init__(self, difficulty: int = 3, mining_reward: int = 50) -> None:
        if not 1 <= difficulty <= 64:
            raise ValueError("difficulty must be between 1 and 64")
        self.difficulty = difficulty
        self.mining_reward = mining_reward
        self.chain: list[Block] = [self._create_genesis_block()]
        self.pending_transactions: list[Transaction] = []

    def _create_genesis_block(self) -> Block:
        block = Block(
            index=0,
            timestamp="1970-01-01T00:00:00+00:00",
            transactions=(),
            miner="genesis",
            previous_hash="0",
            nonce=0,
            hash="",
        )
        return self._mine(block)

    def _mine(self, block: Block) -> Block:
        nonce = block.nonce
        while True:
            candidate = Block(
                index=block.index,
                timestamp=block.timestamp,
                transactions=block.transactions,
                miner=block.miner,
                previous_hash=block.previous_hash,
                nonce=nonce,
                hash="",
            )
            digest = candidate.calculate_hash()
            if digest.startswith("0" * self.difficulty):
                return Block(
                    index=candidate.index,
                    timestamp=candidate.timestamp,
                    transactions=candidate.transactions,
                    miner=candidate.miner,
                    previous_hash=candidate.previous_hash,
                    nonce=candidate.nonce,
                    hash=digest,
                )
            nonce += 1

    def get_latest_block(self) -> Block:
        return self.chain[-1]

    def add_transaction(self, sender: str, recipient: str, amount: int) -> Transaction:
        if not sender.strip() or not recipient.strip():
            raise ValueError("sender and recipient are required")
        if sender == recipient:
            raise ValueError("sender and recipient must differ")
        if isinstance(amount, bool) or not isinstance(amount, int) or amount <= 0:
            raise ValueError("amount must be a positive integer")
        transaction = Transaction(sender, recipient, amount, _utc_now())
        self.pending_transactions.append(transaction)
        return transaction

    def mine_block(self, miner: str) -> Block:
        if not miner.strip():
            raise ValueError("miner is required")
        reward_tx = Transaction("NETWORK", miner, self.mining_reward, _utc_now())
        block = Block(
            index=len(self.chain),
            timestamp=_utc_now(),
            transactions=tuple(self.pending_transactions) + (reward_tx,),
            miner=miner,
            previous_hash=self.get_latest_block().hash,
            nonce=0,
            hash="",
        )
        mined = self._mine(block)
        self.chain.append(mined)
        self.pending_transactions.clear()
        return mined

    def get_balance(self, address: str) -> int:
        """Berechnet den Kontostand einer Adresse durch Durchlaufen der gesamten Chain
        (inklusive noch nicht geminter, ausstehender Transaktionen als 'pending')."""
        balance = 0
        for block in self.chain:
            for tx in block.transactions:
                if tx.recipient == address:
                    balance += tx.amount
                if tx.sender == address:
                    balance -= tx.amount
        return balance

    def get_transactions_for(self, address: str) -> list[dict[str, Any]]:
        """Liefert alle Transaktionen (gemint + ausstehend) einer Adresse, neueste zuerst."""
        results: list[dict[str, Any]] = []
        for block in self.chain:
            for tx in block.transactions:
                if tx.sender == address or tx.recipient == address:
                    entry = tx.as_dict()
                    entry["block_index"] = block.index
                    entry["status"] = "confirmed"
                    results.append(entry)
        for tx in self.pending_transactions:
            if tx.sender == address or tx.recipient == address:
                entry = tx.as_dict()
                entry["block_index"] = None
                entry["status"] = "pending"
                results.append(entry)
        results.sort(key=lambda entry: entry["timestamp"], reverse=True)
        return results

    def is_valid(self) -> bool:
        if not self.chain or self.chain[0].index != 0:
            return False
        for index, current in enumerate(self.chain):
            if current.index != index or current.hash != current.calculate_hash():
                return False
            if not current.hash.startswith("0" * self.difficulty):
                return False
            if index == 0:
                if current.previous_hash != "0" or current.miner != "genesis":
                    return False
                continue
            previous = self.chain[index - 1]
            if current.previous_hash != previous.hash:
                return False
            for transaction in current.transactions:
                if (
                    not isinstance(transaction.sender, str)
                    or not isinstance(transaction.recipient, str)
                    or isinstance(transaction.amount, bool)
                    or not isinstance(transaction.amount, int)
                    or not transaction.sender.strip()
                    or not transaction.recipient.strip()
                    or transaction.sender == transaction.recipient
                    or transaction.amount <= 0
                ):
                    return False
        return True

    def as_dict(self) -> dict[str, Any]:
        return {
            "difficulty": self.difficulty,
            "mining_reward": self.mining_reward,
            "chain": [block.as_dict() for block in self.chain],
            "pending_transactions": [tx.as_dict() for tx in self.pending_transactions],
        }

    def save(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps(self.as_dict(), indent=2), encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path) -> "Blockchain":
        """Lädt eine zuvor gespeicherte Chain von Disk. Existiert die Datei nicht,
        wird eine frische Chain mit Default-Werten zurückgegeben."""
        file_path = Path(path)
        if not file_path.exists():
            return cls()

        data = json.loads(file_path.read_text(encoding="utf-8"))
        instance = cls.__new__(cls)
        instance.difficulty = data["difficulty"]
        instance.mining_reward = data.get("mining_reward", 50)
        instance.chain = [
            Block(
                index=b["index"],
                timestamp=b["timestamp"],
                transactions=tuple(
                    Transaction(t["sender"], t["recipient"], t["amount"], t["timestamp"])
                    for t in b["transactions"]
                ),
                miner=b["miner"],
                previous_hash=b["previous_hash"],
                nonce=b["nonce"],
                hash=b["hash"],
            )
            for b in data["chain"]
        ]
        instance.pending_transactions = [
            Transaction(t["sender"], t["recipient"], t["amount"], t["timestamp"])
            for t in data.get("pending_transactions", [])
        ]
        return instance


if __name__ == "__main__":
    blockchain = Blockchain(difficulty=3)
    blockchain.add_transaction("Alice", "Bob", 50)
    blockchain.add_transaction("Bob", "Charlie", 25)
    blockchain.mine_block("Miner1")
    print(f"Blockchain is valid: {blockchain.is_valid()}")
    for block in blockchain.chain:
        print(f"Block #{block.index} - {block.hash[:12]}...")
