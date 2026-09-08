"""
REST-API für Gibbcoin, gedacht als Backend für die Wallet-Website
(https://gibb-coin.kbb8vy5sjy.workers.dev/).

Startet einen HTTP-Server, der die Blockchain-Logik aus gibbcoin.py
kapselt und per JSON über CORS für das Frontend erreichbar macht.

Starten:
    pip install fastapi uvicorn
    uvicorn api:app --reload --port 8000

Die Chain wird nach jeder Änderung automatisch in chain_data.json
gespeichert und beim Start wieder geladen, damit Daten Neustarts überleben.
"""

from __future__ import annotations

from pathlib import Path
from threading import Lock

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from gibbcoin import Blockchain

CHAIN_FILE = Path(__file__).parent / "chain_data.json"

app = FastAPI(title="Gibbcoin API", version="1.0.0")

# CORS offen lassen, damit die auf Cloudflare Workers gehostete Website
# (oder jede andere Domain) die API per fetch() ansprechen kann.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

_lock = Lock()
blockchain = Blockchain.load(CHAIN_FILE)


def _persist() -> None:
    blockchain.save(CHAIN_FILE)


class TransactionRequest(BaseModel):
    sender: str = Field(..., min_length=1)
    recipient: str = Field(..., min_length=1)
    amount: int = Field(..., gt=0)


class MineRequest(BaseModel):
    miner: str = Field(..., min_length=1)


@app.get("/api/chain")
def get_chain():
    """Gibt die vollständige Chain zurück (für z.B. eine Explorer-Ansicht)."""
    with _lock:
        return blockchain.as_dict()


@app.get("/api/balance/{address}")
def get_balance(address: str):
    """Kontostand einer Wallet-Adresse."""
    with _lock:
        return {"address": address, "balance": blockchain.get_balance(address)}


@app.get("/api/transactions/{address}")
def get_transactions(address: str):
    """Transaktionshistorie (bestätigt + ausstehend) einer Adresse, neueste zuerst."""
    with _lock:
        return {"address": address, "transactions": blockchain.get_transactions_for(address)}


@app.post("/api/transactions")
def create_transaction(payload: TransactionRequest):
    """Neue Transaktion zum Mempool hinzufügen (wird erst beim nächsten Mining bestätigt)."""
    with _lock:
        try:
            tx = blockchain.add_transaction(payload.sender, payload.recipient, payload.amount)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        _persist()
        return {"status": "pending", "transaction": tx.as_dict()}


@app.post("/api/mine")
def mine(payload: MineRequest):
    """Mint alle ausstehenden Transaktionen in einen neuen Block und schreibt
    die Mining-Belohnung dem angegebenen Miner gut."""
    with _lock:
        try:
            block = blockchain.mine_block(payload.miner)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        _persist()
        return {"status": "mined", "block": block.as_dict()}


@app.get("/api/status")
def status():
    """Allgemeiner Zustand: Difficulty, Blockanzahl, Gültigkeit, offene Tx."""
    with _lock:
        return {
            "difficulty": blockchain.difficulty,
            "mining_reward": blockchain.mining_reward,
            "block_count": len(blockchain.chain),
            "pending_count": len(blockchain.pending_transactions),
            "is_valid": blockchain.is_valid(),
        }
