"""Node: HTTP-JSON-API, Peer-Gossip und optionales Mining im Hintergrund."""

from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from .block import Block
from .chain import Blockchain, ValidationError
from .miner import mine_forever
from .params import COIN, DEFAULT_PORT, MAGIC
from .transaction import Transaction

SYNC_INTERVAL = 10  # Sekunden
HTTP_TIMEOUT = 5


def http_json(url: str, payload: dict | None = None, timeout: int = HTTP_TIMEOUT) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "User-Agent": "gibbcoin/1.0"},
        method="POST" if data else "GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode()
    return json.loads(body) if body else {}


class Node:
    def __init__(
        self,
        chain: Blockchain,
        host: str = "127.0.0.1",
        port: int = DEFAULT_PORT,
        peers: list[str] | None = None,
    ):
        self.chain = chain
        self.host = host
        self.port = port
        self.peers: set[str] = set()
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self._server: ThreadingHTTPServer | None = None
        for peer in peers or []:
            self.add_peer(peer)

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.port}"

    # --- Peers ------------------------------------------------------------

    def add_peer(self, peer: str) -> bool:
        peer = peer.strip().rstrip("/")
        if not peer:
            return False
        if not peer.startswith("http"):
            peer = "http://" + peer
        parsed = urlparse(peer)
        if not parsed.hostname or peer == self.url:
            return False
        if peer in self.peers:
            return False
        self.peers.add(peer)
        return True

    def broadcast(self, path: str, payload: dict) -> None:
        for peer in list(self.peers):
            try:
                http_json(f"{peer}{path}", payload)
            except (urllib.error.URLError, OSError, ValueError, TimeoutError):
                continue

    # --- Synchronisierung -------------------------------------------------

    def sync_once(self) -> bool:
        """Holt bei Bedarf die laengste (arbeitsreichste) Kette. True bei Reorg."""
        changed = False
        for peer in list(self.peers):
            try:
                info = http_json(f"{peer}/info")
                if info.get("total_work", 0) <= self.chain.total_work:
                    continue
                remote = http_json(f"{peer}/chain", timeout=30)
                with self.lock:
                    if self.chain.replace_chain(remote["blocks"]):
                        changed = True
                        print(f"Kette von {peer} uebernommen - Hoehe {self.chain.height}")
            except (urllib.error.URLError, OSError, ValueError, KeyError, TimeoutError):
                continue
            except ValidationError as exc:
                print(f"Kette von {peer} abgelehnt: {exc}")
        return changed

    def _sync_loop(self) -> None:
        while not self.stop_event.wait(SYNC_INTERVAL):
            self.sync_once()
            self.broadcast("/peers", {"peer": self.url})

    # --- Eingehende Daten -------------------------------------------------

    def submit_transaction(self, tx: Transaction, relay: bool = True) -> bool:
        with self.lock:
            added = self.chain.add_transaction(tx)
            if added:
                self.chain.save()
        if added and relay:
            threading.Thread(
                target=self.broadcast, args=("/tx", tx.to_dict()), daemon=True
            ).start()
        return added

    def submit_block(self, block: Block, relay: bool = True) -> bool:
        with self.lock:
            added = self.chain.add_block(block)
        if added and relay:
            threading.Thread(
                target=self.broadcast, args=("/block", block.to_dict()), daemon=True
            ).start()
        return added

    # --- Start / Stop -----------------------------------------------------

    def start(self, mine_for: str | None = None, throttle: float = 0.0) -> None:
        handler = _make_handler(self)
        self._server = ThreadingHTTPServer((self.host, self.port), handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        threading.Thread(target=self._sync_loop, daemon=True).start()
        print(f"GibbCoin-Node laeuft auf {self.url} (Hoehe {self.chain.height})")
        if self.peers:
            print("Peers: " + ", ".join(sorted(self.peers)))
        self.sync_once()

        if mine_for:
            print(f"Mining an {mine_for} (throttle {throttle})")
            threading.Thread(
                target=self._mine_loop, args=(mine_for, throttle), daemon=True
            ).start()

    def _mine_loop(self, address: str, throttle: float) -> None:
        def on_block(result) -> None:
            reward = result.block.transactions[0].amount / COIN
            print(
                f"Block #{result.block.height} gefunden - {reward:.8f} GIBB - "
                f"{result.hashrate / 1000:.1f} kH/s"
            )
            self.broadcast("/block", result.block.to_dict())

        mine_forever(
            self.chain,
            address,
            stop=self.stop_event,
            throttle=throttle,
            on_block=on_block,
            lock=self.lock,
        )

    def serve_forever(self) -> None:
        try:
            while not self.stop_event.is_set():
                time.sleep(0.5)
        except KeyboardInterrupt:
            print("\nNode wird beendet…")
        finally:
            self.stop()

    def stop(self) -> None:
        self.stop_event.set()
        if self._server:
            self._server.shutdown()
            self._server.server_close()


def _make_handler(node: "Node"):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GibbCoin/1.0"

        def log_message(self, *args) -> None:  # ruhiges Log
            pass

        # --- Hilfen ------------------------------------------------------

        def _send(self, payload: dict, status: int = 200) -> None:
            body = json.dumps(payload, indent=2).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length", 0))
            if not length:
                return {}
            return json.loads(self.rfile.read(length).decode())

        # --- Routen ------------------------------------------------------

        def do_GET(self) -> None:
            path = urlparse(self.path).path.rstrip("/") or "/"
            try:
                if path == "/" or path == "/info":
                    info = node.chain.info()
                    info["magic"] = MAGIC
                    info["peers"] = sorted(node.peers)
                    info["url"] = node.url
                    return self._send(info)
                if path == "/chain":
                    return self._send(node.chain.to_dict())
                if path == "/mempool":
                    return self._send(
                        {"transactions": [t.to_dict() for t in node.chain.mempool.values()]}
                    )
                if path == "/peers":
                    return self._send({"peers": sorted(node.peers)})
                if path.startswith("/block/"):
                    height = int(path.split("/")[2])
                    if 0 <= height <= node.chain.height:
                        return self._send(node.chain.blocks[height].to_dict())
                    return self._send({"error": "unbekannte Hoehe"}, 404)
                if path.startswith("/balance/"):
                    address = path.split("/")[2]
                    return self._send(
                        {
                            "address": address,
                            "balance": node.chain.balance_of(address) / COIN,
                            "gibbits": node.chain.balance_of(address),
                            "nonce": node.chain.next_nonce(address),
                        }
                    )
                if path.startswith("/history/"):
                    address = path.split("/")[2]
                    return self._send({"transactions": node.chain.history(address)})
                return self._send({"error": "unbekannter Pfad"}, 404)
            except (ValueError, IndexError) as exc:
                return self._send({"error": str(exc)}, 400)

        def do_POST(self) -> None:
            path = urlparse(self.path).path.rstrip("/") or "/"
            try:
                payload = self._body()
                if path == "/tx":
                    tx = Transaction.from_dict(payload)
                    added = node.submit_transaction(tx)
                    return self._send({"accepted": added, "txid": tx.txid()})
                if path == "/block":
                    block = Block.from_dict(payload)
                    added = node.submit_block(block)
                    return self._send({"accepted": added, "hash": block.hash()})
                if path == "/peers":
                    added = node.add_peer(payload.get("peer", ""))
                    return self._send({"added": added, "peers": sorted(node.peers)})
                return self._send({"error": "unbekannter Pfad"}, 404)
            except ValidationError as exc:
                return self._send({"error": str(exc)}, 400)
            except (ValueError, KeyError, TypeError) as exc:
                return self._send({"error": f"ungueltige Anfrage: {exc}"}, 400)

    return Handler
