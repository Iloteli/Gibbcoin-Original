"""Wallet: Schluessel erzeugen, laden, speichern und Transaktionen signieren."""

from __future__ import annotations

import json
import os
import stat

from . import crypto
from .params import MIN_FEE
from .transaction import Transaction

DEFAULT_WALLET = os.path.join(os.path.expanduser("~"), ".gibbcoin", "wallet.json")


class Wallet:
    def __init__(self, seed: bytes):
        if len(seed) != 32:
            raise ValueError("Seed muss 32 Bytes lang sein")
        self.seed = seed
        self.public_key = crypto.public_key(seed)
        self.address = crypto.public_key_to_address(self.public_key)

    # --- Erzeugen / Laden -------------------------------------------------

    @classmethod
    def create(cls) -> "Wallet":
        return cls(crypto.generate_seed())

    @classmethod
    def load(cls, path: str = DEFAULT_WALLET) -> "Wallet":
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return cls(bytes.fromhex(data["seed"]))

    @classmethod
    def load_or_create(cls, path: str = DEFAULT_WALLET) -> "Wallet":
        if os.path.exists(path):
            return cls.load(path)
        wallet = cls.create()
        wallet.save(path)
        return wallet

    def save(self, path: str = DEFAULT_WALLET) -> str:
        directory = os.path.dirname(os.path.abspath(path))
        os.makedirs(directory, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "address": self.address,
                    "public_key": self.public_key.hex(),
                    "seed": self.seed.hex(),
                },
                fh,
                indent=2,
            )
        try:  # auf POSIX nur fuer den Besitzer lesbar
            os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass
        return path

    # --- Signieren --------------------------------------------------------

    def create_transaction(
        self,
        recipient: str,
        amount: int,
        nonce: int,
        fee: int = MIN_FEE,
        memo: str = "",
    ) -> Transaction:
        if not crypto.is_valid_address(recipient):
            raise ValueError(f"ungueltige Empfaengeradresse: {recipient}")
        tx = Transaction(
            sender=self.address,
            recipient=recipient,
            amount=amount,
            fee=fee,
            nonce=nonce,
            memo=memo,
        )
        return tx.sign(self.seed)

    def __str__(self) -> str:
        return f"Wallet({self.address})"
