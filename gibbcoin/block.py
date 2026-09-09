"""Bloecke, Merkle-Root und Proof-of-Work-Header."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field

from . import crypto
from .params import MAX_TARGET
from .transaction import Transaction


def merkle_root(txids: list[str]) -> str:
    if not txids:
        return "00" * 32
    layer = [bytes.fromhex(t) for t in txids]
    while len(layer) > 1:
        if len(layer) % 2:
            layer.append(layer[-1])
        layer = [
            crypto.double_sha256(layer[i] + layer[i + 1])
            for i in range(0, len(layer), 2)
        ]
    return layer[0].hex()


@dataclass
class Block:
    height: int
    previous_hash: str
    transactions: list[Transaction] = field(default_factory=list)
    timestamp: int = field(default_factory=lambda: int(time.time()))
    target: int = MAX_TARGET
    nonce: int = 0
    version: int = 1

    # --- Header -----------------------------------------------------------

    def merkle_root(self) -> str:
        return merkle_root([tx.txid() for tx in self.transactions])

    def header(self) -> bytes:
        data = {
            "version": self.version,
            "height": self.height,
            "previous_hash": self.previous_hash,
            "merkle_root": self.merkle_root(),
            "timestamp": self.timestamp,
            "target": hex(self.target),
            "nonce": self.nonce,
        }
        return json.dumps(data, sort_keys=True, separators=(",", ":")).encode()

    def hash(self) -> str:
        return crypto.double_sha256(self.header()).hex()

    def meets_target(self) -> bool:
        return crypto.hash_to_int(bytes.fromhex(self.hash())) <= self.target

    @property
    def difficulty(self) -> float:
        """1.0 = leichtester erlaubter Block."""
        return MAX_TARGET / self.target if self.target else float("inf")

    # --- Serialisierung ---------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "height": self.height,
            "previous_hash": self.previous_hash,
            "merkle_root": self.merkle_root(),
            "timestamp": self.timestamp,
            "target": hex(self.target),
            "nonce": self.nonce,
            "hash": self.hash(),
            "transactions": [tx.to_dict() for tx in self.transactions],
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Block":
        return cls(
            height=int(data["height"]),
            previous_hash=data["previous_hash"],
            transactions=[Transaction.from_dict(t) for t in data.get("transactions", [])],
            timestamp=int(data["timestamp"]),
            target=int(data["target"], 16) if isinstance(data["target"], str) else int(data["target"]),
            nonce=int(data["nonce"]),
            version=int(data.get("version", 1)),
        )

    def __str__(self) -> str:
        return (
            f"Block #{self.height} {self.hash()[:16]}… "
            f"({len(self.transactions)} tx, diff {self.difficulty:.2f})"
        )
