# GibbCoin (GIBB)

Eine kleine, vollstaendige Blockchain in reinem Python — **ohne jede externe Abhaengigkeit** — mit einem eigenen Coin namens **GibbCoin (GIBB)**. Die Difficulty ist absichtlich so niedrig gewaehlt, dass ein einzelner CPU-Kern eines normalen Notebooks Bloecke findet. Kein GPU-Rig, kein ASIC.

> **Hinweis:** Das ist ein Lern- und Bastelprojekt, kein Finanzprodukt. Die Ed25519-Implementierung ist die Referenzvariante und nicht seitenkanalfest. Nicht fuer echtes Geld verwenden.

## Was drin ist

- **Proof of Work** (SHA-256d) mit niedriger Startschwierigkeit und automatischem Retarget
- **Konto-Modell** mit Nonces (Schutz gegen Replay und Double Spend)
- **Ed25519-Signaturen** und Base58Check-Adressen (beginnen mit `G`)
- **Merkle-Root** pro Block, Median-Zeit-Regel, Coinbase-Pruefung, Supply-Cap
- **Halving** alle 210.000 Bloecke, max. 21.000.000 GIBB
- **P2P-Node** mit HTTP-JSON-API, Peer-Gossip und Longest-Chain-Reorg
- **CLI** fuer Wallet, Mining, Ueberweisungen und Node-Betrieb
- **Persistenz** von Kette *und* Mempool in einer JSON-Datei
- **Tests** nur mit `unittest` (19 Tests, inkl. RFC-8032-Vektor)

## Voraussetzungen

Python 3.10 oder neuer. Sonst nichts.

## Schnellstart

```bash
git clone https://github.com/Iloteli/gibbcoin-original.git
cd gibbcoin-original
python -m gibbcoin wallet --new
```

Mining starten (10 Bloecke, dann Ende):

```bash
python -m gibbcoin mine --blocks 10
```

Guthaben ansehen:

```bash
python -m gibbcoin balance
```

Node mit Mining im Hintergrund:

```bash
python -m gibbcoin node --mine --throttle 0.8
```

`--throttle 0.8` heisst: sehr sparsam minen, damit der Rechner nutzbar bleibt. `0.0` ist Vollgas.

Zweiter Node auf demselben Rechner, der sich mit dem ersten verbindet:

```bash
python -m gibbcoin --data ~/.gibbcoin/chain2.json node --port 9334 --peer http://127.0.0.1:9333
```

Ueberweisen:

```bash
python -m gibbcoin send G... 1.5 --node http://127.0.0.1:9333
```

Tests:

```bash
python -m unittest discover -s tests -v
```

## Konsens-Parameter

| Parameter | Wert |
|---|---|
| Symbol | GIBB |
| Kleinste Einheit | 1 Gibbit = 0,00000001 GIBB |
| Hash | SHA-256d |
| Startziel | `2**240` (~65.000 Hashes pro Block) |
| Zielblockzeit | 30 Sekunden |
| Retarget | alle 20 Bloecke, max. Faktor 4 |
| Startbelohnung | 50 GIBB |
| Halving | alle 210.000 Bloecke |
| Maximalmenge | 21.000.000 GIBB |
| Mindestgebuehr | 1.000 Gibbits |
| Standard-Port | 9333 |

Alles steht in [`gibbcoin/params.py`](gibbcoin/params.py) und laesst sich fuer ein eigenes Netz anpassen — dann bitte auch `MAGIC` und `GENESIS_MESSAGE` aendern.

## HTTP-API

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/info` | Hoehe, Difficulty, Supply, Peers |
| GET | `/chain` | komplette Kette |
| GET | `/block/<hoehe>` | einzelner Block |
| GET | `/balance/<adresse>` | Guthaben und naechste Nonce |
| GET | `/history/<adresse>` | Transaktionen einer Adresse |
| GET | `/mempool` | unbestaetigte Transaktionen |
| GET/POST | `/peers` | Peers anzeigen / hinzufuegen |
| POST | `/tx` | Transaktion einreichen |
| POST | `/block` | Block einreichen |

## Aufbau

```
gibbcoin/
  params.py       Konsens-Parameter an einem Ort
  crypto.py       SHA-256, Ed25519, Base58Check
  transaction.py  Transaktionen, Signatur, Coinbase
  block.py        Block, Header, Merkle-Root, PoW-Pruefung
  chain.py        Validierung, Zustand, Difficulty, Persistenz, Reorg
  wallet.py       Schluesselverwaltung
  miner.py        CPU-Miner mit Throttle
  node.py         HTTP-API, Peer-Gossip, Sync
  cli.py          Kommandozeile
tests/
  test_gibbcoin.py
```

## Wie das Mining funktioniert

Ein Block gilt als gefunden, wenn `SHA256(SHA256(header)) <= target`. Der Header enthaelt Hoehe, Vorgaenger-Hash, Merkle-Root, Zeitstempel, Ziel und Nonce. Der Miner zaehlt die Nonce hoch, bis der Hash klein genug ist. Beim Startziel `2**240` braucht es im Mittel rund 65.000 Versuche — in Python etwa eine Zehntelsekunde.

Alle 20 Bloecke passt das Netz das Ziel an, damit im Schnitt alle 30 Sekunden ein Block entsteht. Nach oben ist das Ziel bei `MAX_TARGET` gedeckelt: leichter als die Startschwierigkeit wird es nie.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
