"""Transaktionen (Konto-Modell mit Nonces)."""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass, field

from . import crypto
from .params import COIN, MIN_FEE

COINBASE_SENDER = "COINBASE"


@dataclass
class Transaction:
    sender: str                  # Adresse oder COINBASE_SENDER
    recipient: str
    amount: int                  # in Gibbits
    fee: int = 0
    nonce: int = 0               # fortlaufend pro Absender; bei Coinbase = Hoehe
    timestamp: int = field(default_factory=lambda: int(time.time()))
    memo: str = ""
    public_key: str = ""         # hex, leer bei Coinbase
    signature: str = ""          # hex, leer bei Coinbase

    # --- Serialisierung ---------------------------------------------------

    def signing_payload(self) -> bytes:
        """Kanonische Bytes, die signiert werden (ohne Signatur selbst)."""
        data = {
            "sender": self.sender,
            "recipient": self.recipient,
            "amount": self.amount,
            "fee": self.fee,
            "nonce": self.nonce,
            "timestamp": self.timestamp,
            "memo": self.memo,
            "public_key": self.public_key,
        }
        return json.dumps(data, sort_keys=True, separators=(",", ":")).encode()

    def txid(self) -> str:
        raw = self.signing_payload() + bytes.fromhex(self.signature or "")
        return crypto.double_sha256(raw).hex()

    def to_dict(self) -> dict:
        out = asdict(self)
        out["txid"] = self.txid()
        return out

    @classmethod
    def from_dict(cls, data: dict) -> "Transaction":
        return cls(
            sender=data["sender"],
            recipient=data["recipient"],
            amount=int(data["amount"]),
            fee=int(data.get("fee", 0)),
            nonce=int(data.get("nonce", 0)),
            timestamp=int(data.get("timestamp", 0)),
            memo=data.get("memo", ""),
            public_key=data.get("public_key", ""),
            signature=data.get("signature", ""),
        )

    # --- Signieren / Pruefen ---------------------------------------------

    @property
    def is_coinbase(self) -> bool:
        return self.sender == COINBASE_SENDER

    def sign(self, seed: bytes) -> "Transaction":
        pub = crypto.public_key(seed)
        self.public_key = pub.hex()
        self.signature = crypto.sign(seed, self.signing_payload()).hex()
        return self

    def is_valid(self) -> bool:
        """Strukturelle Pruefung - Guthaben/Nonce prueft die Chain."""
        if self.amount < 0 or self.fee < 0:
            return False
        if not crypto.is_valid_address(self.recipient):
            return False
        if len(self.memo) > 128:
            return False

        if self.is_coinbase:
            return not self.public_key and not self.signature

        if self.fee < MIN_FEE or self.amount == 0:
            return False
        if not crypto.is_valid_address(self.sender):
            return False
        try:
            pub = bytes.fromhex(self.public_key)
            sig = bytes.fromhex(self.signature)
        except ValueError:
            return False
        if not crypto.address_matches_pubkey(self.sender, pub):
            return False
        return crypto.verify(pub, self.signing_payload(), sig)

    def __str__(self) -> str:
        return (
            f"{self.txid()[:12]}… {self.sender[:10]}→{self.recipient[:10]} "
            f"{self.amount / COIN:.8f} GIBB (fee {self.fee})"
        )


def coinbase(recipient: str, amount: int, height: int, memo: str = "") -> Transaction:
    return Transaction(
        sender=COINBASE_SENDER,
        recipient=recipient,
        amount=amount,
        fee=0,
        nonce=height,
        memo=memo,
    )
