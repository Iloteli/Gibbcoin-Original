"""
Eigenständiger Blockchain-Node (Server)
========================================
- Läuft komplett eigenständig auf deinem eigenen Server (kein externer Dienst nötig).
- REST-API zum Anzeigen der Chain, Einreichen von Transaktionen und Minen.
- Mining ist für SCHWACHE GERÄTE optimiert:
    * SHA-256 statt speicherintensiver Algorithmen (kein RAM-Flaschenhals)
    * Niedrige Standard-Difficulty (3), sofort per API änderbar
    * Adaptive Difficulty: passt sich automatisch an die tatsächliche Mining-Zeit
      des Geräts an (Ziel: ~5 Sekunden pro Block), damit ein Raspberry Pi
      oder alter Laptop nicht stundenlang rechnen muss
    * Kein Multi-Threading/Multi-Core-Zwang -> läuft sparsam auf 1 Kern
- Mehrere Server (Nodes) können sich gegenseitig kennen und per Konsens
  (längste gültige Chain gewinnt) synchronisieren.
"""

import hashlib
import json
import time
import uuid
from urllib.parse import urlparse

import requests
from flask import Flask, jsonify, request


# ------------------------------------------------------------------
# Block & Chain-Logik
# ------------------------------------------------------------------

class Block:
    def __init__(self, index, transactions, previous_hash, timestamp=None, nonce=0, hash_=None):
        self.index = index
        self.timestamp = timestamp or time.time()
        self.transactions = transactions
        self.previous_hash = previous_hash
        self.nonce = nonce
        self.hash = hash_ or self.calculate_hash()

    def calculate_hash(self):
        block_string = json.dumps({
            "index": self.index,
            "timestamp": self.timestamp,
            "transactions": self.transactions,
            "previous_hash": self.previous_hash,
            "nonce": self.nonce,
        }, sort_keys=True).encode()
        return hashlib.sha256(block_string).hexdigest()

    def to_dict(self):
        return {
            "index": self.index,
            "timestamp": self.timestamp,
            "transactions": self.transactions,
            "previous_hash": self.previous_hash,
            "nonce": self.nonce,
            "hash": self.hash,
        }

    @staticmethod
    def from_dict(d):
        return Block(
            index=d["index"],
            transactions=d["transactions"],
            previous_hash=d["previous_hash"],
            timestamp=d["timestamp"],
            nonce=d["nonce"],
            hash_=d["hash"],
        )


class Blockchain:
    # Ziel-Blockzeit in Sekunden -- wichtig fuer schwache Geraete:
    # lieber haeufiger einfache Blocks als selten sehr schwere.
    TARGET_BLOCK_TIME = 5.0
    MIN_DIFFICULTY = 1
    MAX_DIFFICULTY = 6  # bewusst gedeckelt, damit ein schwaches Geraet nicht abstuerzt

    def __init__(self, difficulty=3):
        self.difficulty = difficulty
        self.chain = []
        self.pending_transactions = []
        self.nodes = set()
        self.node_id = str(uuid.uuid4()).replace("-", "")
        self.chain.append(self._create_genesis_block())

    def _create_genesis_block(self):
        return Block(0, ["Genesis Block"], "0", timestamp=0)

    def get_latest_block(self):
        return self.chain[-1]

    def register_node(self, address):
        parsed = urlparse(address)
        if parsed.netloc:
            self.nodes.add(parsed.netloc)
        elif parsed.path:
            self.nodes.add(parsed.path)

    def add_transaction(self, sender, recipient, amount):
        self.pending_transactions.append({
            "sender": sender,
            "recipient": recipient,
            "amount": amount,
        })
        return self.get_latest_block().index + 1

    def _adjust_difficulty(self, mining_seconds):
        """Passt die Difficulty an, damit Mining auf schwacher Hardware
        weder zu langsam noch trivial schnell wird."""
        if mining_seconds < self.TARGET_BLOCK_TIME / 2 and self.difficulty < self.MAX_DIFFICULTY:
            self.difficulty += 1
        elif mining_seconds > self.TARGET_BLOCK_TIME * 2 and self.difficulty > self.MIN_DIFFICULTY:
            self.difficulty -= 1

    def mine_pending_transactions(self, miner_address):
        if not self.pending_transactions:
            self.pending_transactions.append({
                "sender": "network",
                "recipient": miner_address,
                "amount": 0,
            })

        new_block = Block(
            index=len(self.chain),
            transactions=self.pending_transactions,
            previous_hash=self.get_latest_block().hash,
        )

        target = "0" * self.difficulty
        start = time.time()

        # Bewusst simpler Single-Core-Loop: schont CPU/RAM auf schwachen Geraeten,
        # kein paralleler Brute-Force noetig bei niedriger Difficulty.
        while new_block.hash[:self.difficulty] != target:
            new_block.nonce += 1
            new_block.hash = new_block.calculate_hash()

        elapsed = time.time() - start
        self._adjust_difficulty(elapsed)

        # Miner-Belohnung
        self.pending_transactions = [{
            "sender": "network",
            "recipient": miner_address,
            "amount": 1,
        }]

        self.chain.append(new_block)
        return new_block, elapsed

    def is_chain_valid(self, chain=None):
        chain = chain or self.chain
        for i in range(1, len(chain)):
            current = chain[i]
            previous = chain[i - 1]

            current_hash = current.hash if isinstance(current, Block) else current["hash"]
            calc_hash = (current.calculate_hash() if isinstance(current, Block)
                         else Block.from_dict(current).calculate_hash())
            prev_hash = previous.hash if isinstance(previous, Block) else previous["hash"]
            current_prev_hash = (current.previous_hash if isinstance(current, Block)
                                  else current["previous_hash"])

            if current_hash != calc_hash:
                return False
            if current_prev_hash != prev_hash:
                return False
        return True

    def resolve_conflicts(self):
        """Konsens-Algorithmus: die laengste gueltige Chain im Netzwerk gewinnt."""
        neighbours = self.nodes
        new_chain = None
        max_length = len(self.chain)

        for node in neighbours:
            try:
                response = requests.get(f"http://{node}/chain", timeout=3)
            except requests.exceptions.RequestException:
                continue

            if response.status_code == 200:
                data = response.json()
                length = data["length"]
                chain_dicts = data["chain"]
                candidate_chain = [Block.from_dict(b) for b in chain_dicts]

                if length > max_length and self.is_chain_valid(candidate_chain):
                    max_length = length
                    new_chain = candidate_chain

        if new_chain:
            self.chain = new_chain
            return True
        return False


# ------------------------------------------------------------------
# Flask-Server (REST-API)
# ------------------------------------------------------------------

app = Flask(__name__)
blockchain = Blockchain(difficulty=3)


@app.route("/mine", methods=["GET"])
def mine():
    miner_address = request.args.get("miner", blockchain.node_id)
    block, elapsed = blockchain.mine_pending_transactions(miner_address)
    response = {
        "message": "Neuer Block gemined",
        "block": block.to_dict(),
        "mining_time_seconds": round(elapsed, 3),
        "new_difficulty": blockchain.difficulty,
    }
    return jsonify(response), 200


@app.route("/transactions/new", methods=["POST"])
def new_transaction():
    values = request.get_json(force=True)
    required = ["sender", "recipient", "amount"]
    if not values or not all(k in values for k in required):
        return jsonify({"message": "Fehlende Felder: sender, recipient, amount noetig"}), 400

    index = blockchain.add_transaction(values["sender"], values["recipient"], values["amount"])
    return jsonify({"message": f"Transaktion wird in Block {index} aufgenommen"}), 201


@app.route("/chain", methods=["GET"])
def full_chain():
    response = {
        "chain": [block.to_dict() for block in blockchain.chain],
        "length": len(blockchain.chain),
        "difficulty": blockchain.difficulty,
    }
    return jsonify(response), 200


@app.route("/nodes/register", methods=["POST"])
def register_nodes():
    values = request.get_json(force=True)
    nodes = values.get("nodes") if values else None
    if nodes is None:
        return jsonify({"message": "Fehler: bitte eine Liste von Nodes angeben"}), 400

    for node in nodes:
        blockchain.register_node(node)

    return jsonify({
        "message": "Neue Nodes hinzugefuegt",
        "total_nodes": list(blockchain.nodes),
    }), 201


@app.route("/nodes/resolve", methods=["GET"])
def consensus():
    replaced = blockchain.resolve_conflicts()
    if replaced:
        response = {"message": "Chain wurde ersetzt", "new_chain": [b.to_dict() for b in blockchain.chain]}
    else:
        response = {"message": "Chain ist bereits aktuell", "chain": [b.to_dict() for b in blockchain.chain]}
    return jsonify(response), 200


@app.route("/status", methods=["GET"])
def status():
    return jsonify({
        "node_id": blockchain.node_id,
        "chain_length": len(blockchain.chain),
        "difficulty": blockchain.difficulty,
        "pending_transactions": len(blockchain.pending_transactions),
        "peers": list(blockchain.nodes),
        "chain_valid": blockchain.is_chain_valid(),
    }), 200


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Eigenstaendiger Blockchain-Node")
    parser.add_argument("--port", default=5000, type=int, help="Port fuer diesen Node")
    parser.add_argument("--host", default="0.0.0.0", help="Host-Bindung (0.0.0.0 = von aussen erreichbar)")
    args = parser.parse_args()

    # threaded=False, um auf schwacher Hardware keine Ueberlastung durch
    # parallele Requests zu erzeugen. Fuer mehr Last: threaded=True setzen.
    app.run(host=args.host, port=args.port, threaded=False)
