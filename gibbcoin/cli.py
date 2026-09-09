"""Kommandozeile fuer GibbCoin: ``python -m gibbcoin <befehl>``."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error

from . import crypto
from .chain import Blockchain, ValidationError
from .miner import mine_forever
from .node import Node, http_json
from .params import COIN, DEFAULT_PORT, MIN_FEE, NAME, SYMBOL
from .wallet import DEFAULT_WALLET, Wallet

DEFAULT_DATA = os.path.join(os.path.expanduser("~"), ".gibbcoin", "chain.json")


def _chain(args) -> Blockchain:
    return Blockchain(args.data)


def _wallet(args) -> Wallet:
    return Wallet.load_or_create(args.wallet)


def _amount(value: str) -> int:
    """'1.5' -> 150000000 Gibbits."""
    return int(round(float(value) * COIN))


# --- Befehle -------------------------------------------------------------


def cmd_wallet(args) -> int:
    if args.new and os.path.exists(args.wallet) and not args.force:
        print(f"Es gibt schon eine Wallet unter {args.wallet} (--force ueberschreibt).")
        return 1
    if args.new:
        wallet = Wallet.create()
        wallet.save(args.wallet)
        print(f"Neue Wallet gespeichert: {args.wallet}")
    else:
        wallet = _wallet(args)

    print(f"Adresse:    {wallet.address}")
    print(f"Public Key: {wallet.public_key.hex()}")
    if args.show_secret:
        print(f"Seed:       {wallet.seed.hex()}  <- geheim halten!")
    return 0


def cmd_info(args) -> int:
    if args.node:
        print(json.dumps(http_json(f"{args.node}/info"), indent=2))
        return 0
    print(json.dumps(_chain(args).info(), indent=2))
    return 0


def cmd_balance(args) -> int:
    address = args.address or _wallet(args).address
    if args.node:
        data = http_json(f"{args.node}/balance/{address}")
        print(f"{address}: {data['balance']:.8f} {SYMBOL}")
        return 0
    chain = _chain(args)
    print(f"{address}: {chain.balance_of(address) / COIN:.8f} {SYMBOL}")
    return 0


def cmd_mine(args) -> int:
    wallet = _wallet(args)
    address = args.address or wallet.address
    chain = _chain(args)
    print(f"{NAME}-Mining an {address}")
    print(f"Hoehe {chain.height}, Difficulty {chain.tip.difficulty:.2f}, "
          f"Throttle {args.throttle}")
    mined = mine_forever(chain, address, throttle=args.throttle, blocks=args.blocks)
    print(f"{mined} Block(s) gemint. Guthaben: "
          f"{chain.balance_of(address) / COIN:.8f} {SYMBOL}")
    return 0


def cmd_node(args) -> int:
    chain = Blockchain(args.data)
    peers = [p for p in (args.peer or []) if p]
    node = Node(chain, host=args.host, port=args.port, peers=peers)
    address = None
    if args.mine:
        address = args.address or _wallet(args).address
    node.start(mine_for=address, throttle=args.throttle)
    node.serve_forever()
    return 0


def cmd_send(args) -> int:
    wallet = _wallet(args)
    if not crypto.is_valid_address(args.recipient):
        print(f"Ungueltige Empfaengeradresse: {args.recipient}")
        return 1

    amount = _amount(args.amount)
    fee = _amount(args.fee) if args.fee else MIN_FEE

    if args.node:
        nonce = http_json(f"{args.node}/balance/{wallet.address}")["nonce"]
        tx = wallet.create_transaction(args.recipient, amount, nonce, fee, args.memo)
        result = http_json(f"{args.node}/tx", tx.to_dict())
        print(json.dumps(result, indent=2))
        return 0 if result.get("accepted") else 1

    chain = _chain(args)
    nonce = chain.next_nonce(wallet.address)
    tx = wallet.create_transaction(args.recipient, amount, nonce, fee, args.memo)
    chain.add_transaction(tx)
    print(f"Transaktion im lokalen Mempool: {tx.txid()}")
    chain.save()
    print("Hinweis: erst der naechste geminte Block bestaetigt sie.")
    return 0


def cmd_history(args) -> int:
    address = args.address or _wallet(args).address
    chain = _chain(args)
    entries = chain.history(address)
    if not entries:
        print(f"Keine Transaktionen fuer {address}")
        return 0
    for entry in entries:
        direction = "IN " if entry["recipient"] == address else "OUT"
        print(
            f"#{entry['height']:>6} {direction} {entry['amount'] / COIN:>16.8f} "
            f"{SYMBOL}  {entry['txid'][:16]}"
        )
    return 0


def cmd_peers(args) -> int:
    if args.add:
        print(json.dumps(http_json(f"{args.node}/peers", {"peer": args.add}), indent=2))
    else:
        print(json.dumps(http_json(f"{args.node}/peers"), indent=2))
    return 0


# --- Parser --------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gibbcoin",
        description=f"{NAME} ({SYMBOL}) - eine schlanke, CPU-minebare Blockchain",
    )
    parser.add_argument("--data", default=DEFAULT_DATA, help="Pfad zur Chain-Datei")
    parser.add_argument("--wallet", default=DEFAULT_WALLET, help="Pfad zur Wallet-Datei")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("wallet", help="Wallet anzeigen oder erzeugen")
    p.add_argument("--new", action="store_true", help="neue Wallet erzeugen")
    p.add_argument("--force", action="store_true", help="bestehende Wallet ersetzen")
    p.add_argument("--show-secret", action="store_true", help="Seed mit ausgeben")
    p.set_defaults(func=cmd_wallet)

    p = sub.add_parser("info", help="Status der Kette")
    p.add_argument("--node", help="stattdessen einen Node abfragen")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("balance", help="Guthaben einer Adresse")
    p.add_argument("address", nargs="?", help="Adresse (Standard: eigene Wallet)")
    p.add_argument("--node")
    p.set_defaults(func=cmd_balance)

    p = sub.add_parser("mine", help="lokal Bloecke minen")
    p.add_argument("--address", help="Empfaenger der Belohnung")
    p.add_argument("--blocks", type=int, help="nach N Bloecken aufhoeren")
    p.add_argument("--throttle", type=float, default=0.0,
                   help="0.0 = Vollgas, 0.9 = sehr sparsam")
    p.set_defaults(func=cmd_mine)

    p = sub.add_parser("node", help="Node starten (HTTP-API, Sync, optional Mining)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--peer", action="append", help="Peer-URL (mehrfach moeglich)")
    p.add_argument("--mine", action="store_true", help="im Hintergrund minen")
    p.add_argument("--address", help="Empfaenger der Belohnung")
    p.add_argument("--throttle", type=float, default=0.0)
    p.set_defaults(func=cmd_node)

    p = sub.add_parser("send", help="GIBB ueberweisen")
    p.add_argument("recipient")
    p.add_argument("amount", help="Betrag in GIBB, z. B. 1.5")
    p.add_argument("--fee", help="Gebuehr in GIBB")
    p.add_argument("--memo", default="", help="kurze Notiz (max. 128 Zeichen)")
    p.add_argument("--node", help="Transaktion an diesen Node senden")
    p.set_defaults(func=cmd_send)

    p = sub.add_parser("history", help="Transaktionen einer Adresse")
    p.add_argument("address", nargs="?")
    p.set_defaults(func=cmd_history)

    p = sub.add_parser("peers", help="Peers eines Nodes anzeigen/hinzufuegen")
    p.add_argument("--node", default=f"http://127.0.0.1:{DEFAULT_PORT}")
    p.add_argument("--add", help="Peer-URL hinzufuegen")
    p.set_defaults(func=cmd_peers)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ValidationError as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        return 1
    except (urllib.error.URLError, OSError) as exc:
        print(f"Netzwerk-/Dateifehler: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
