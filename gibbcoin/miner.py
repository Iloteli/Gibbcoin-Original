"""CPU-Miner fuer GibbCoin.

Die Difficulty ist bewusst so niedrig, dass ein einzelner CPU-Kern genuegt
(im Schnitt rund 65.000 SHA-256d-Hashes pro Block bei Startschwierigkeit).
Mit ``throttle`` laesst sich die Last zusaetzlich drosseln, damit das Mining
im Hintergrund kaum spuerbar ist.
"""

from __future__ import annotations

import json
import threading
import time
from typing import Callable

from . import crypto
from .block import Block
from .chain import Blockchain
from .params import COIN


class MiningResult:
    def __init__(self, block: Block, hashes: int, seconds: float):
        self.block = block
        self.hashes = hashes
        self.seconds = seconds

    @property
    def hashrate(self) -> float:
        return self.hashes / self.seconds if self.seconds else 0.0


def _header_template(block: Block) -> tuple[bytes, bytes]:
    """Zerlegt den Header einmalig in die Teile vor und nach der Nonce."""
    data = {
        "version": block.version,
        "height": block.height,
        "previous_hash": block.previous_hash,
        "merkle_root": block.merkle_root(),
        "timestamp": block.timestamp,
        "target": hex(block.target),
        "nonce": 0,
    }
    blob = json.dumps(data, sort_keys=True, separators=(",", ":"))
    prefix, suffix = blob.split('"nonce":0', 1)
    return (prefix + '"nonce":').encode(), suffix.encode()


def mine_block(
    block: Block,
    stop: threading.Event | None = None,
    throttle: float = 0.0,
    on_progress: Callable[[int], None] | None = None,
) -> MiningResult | None:
    """Sucht eine Nonce, bis der Block-Hash das Ziel unterschreitet.

    ``throttle`` ist ein Wert zwischen 0.0 (Vollgas) und 0.99 (sehr sparsam)
    und gibt an, welcher Anteil der Zeit schlafend verbracht wird.
    """
    prefix, suffix = _header_template(block)
    target = block.target
    started = time.time()
    hashes = 0
    nonce = block.nonce

    while stop is None or not stop.is_set():
        header = prefix + str(nonce).encode() + suffix
        digest = crypto.double_sha256(header)
        hashes += 1
        if crypto.hash_to_int(digest) <= target:
            block.nonce = nonce
            return MiningResult(block, hashes, time.time() - started)

        nonce += 1
        if hashes % 20_000 == 0:
            if on_progress:
                on_progress(hashes)
            if throttle > 0:
                time.sleep(min(max(throttle, 0.0), 0.99) * 0.05)
    return None


def mine_forever(
    chain: Blockchain,
    address: str,
    stop: threading.Event | None = None,
    throttle: float = 0.0,
    blocks: int | None = None,
    on_block: Callable[[MiningResult], None] | None = None,
    lock: threading.Lock | None = None,
) -> int:
    """Mint Bloecke, bis ``blocks`` erreicht ist oder ``stop`` gesetzt wird."""
    mined = 0
    while (blocks is None or mined < blocks) and (stop is None or not stop.is_set()):
        with lock or threading.Lock():
            candidate = chain.candidate_block(address)
        result = mine_block(candidate, stop=stop, throttle=throttle)
        if result is None:
            break
        try:
            with lock or threading.Lock():
                chain.add_block(result.block)
        except Exception as exc:  # Konkurrenz: jemand war schneller
            print(f"  Block verworfen: {exc}")
            continue
        mined += 1
        if on_block:
            on_block(result)
        else:
            reward = result.block.transactions[0].amount / COIN
            print(
                f"Block #{result.block.height} gefunden - "
                f"{reward:.8f} GIBB - {result.hashes} Hashes in "
                f"{result.seconds:.2f}s ({result.hashrate / 1000:.1f} kH/s)"
            )
    return mined
