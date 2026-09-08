# Gibbcoin

Eine kleine, lehrreiche Blockchain-Implementierung in Python — inklusive
REST-API und Wallet-Website ("GIBB Coin – Dein Campus Wallet").

- unveränderliche `Block`- und `Transaction`-Datenklassen
- deterministische SHA-256-Hashberechnung
- Proof-of-Work mit konfigurierbarer Schwierigkeit
- Mining-Belohnung für den Miner
- Kontostand- und Transaktionshistorie pro Adresse
- Persistenz (Speichern/Laden der Chain als JSON)
- Prüfung von Transaktionen und der gesamten Chain
- Tests gegen Manipulation und ungültige Eingaben

## Projektstruktur

- `gibbcoin.py` enthält die einzige kanonische Blockchain-Implementierung.
- `api.py` ist das FastAPI-Backend, das `gibbcoin.py` als REST-API für die
  Website bereitstellt.
- `index.html` ist die Wallet-Website (Kontostand, Senden, Minen,
  Transaktionshistorie), spricht per `fetch()` mit `api.py`.
- `test_gibbcoin.py` enthält die automatisierten Tests.
- `Code/blockchain.py` ist ein Kompatibilitäts-Import für ältere Beispiele
  und verwendet dieselben Klassen wie `gibbcoin.py`.
- `requirements.txt` listet die Python-Abhängigkeiten für die API.

## API + Website lokal starten

Voraussetzung ist Python 3.10 oder neuer.

```bash
pip install -r requirements.txt
uvicorn api:app --reload --port 8000
```

Die API läuft dann unter `http://localhost:8000`. Öffne anschließend
`index.html` direkt im Browser (Doppelklick reicht) — sie verbindet sich
standardmäßig mit `http://localhost:8000`.

### API-Endpunkte

| Methode | Pfad                          | Zweck                                      |
|---------|-------------------------------|---------------------------------------------|
| GET     | `/api/chain`                  | Vollständige Chain als JSON                 |
| GET     | `/api/balance/{address}`      | Kontostand einer Adresse                    |
| GET     | `/api/transactions/{address}` | Transaktionshistorie (bestätigt + offen)    |
| POST    | `/api/transactions`           | Neue Transaktion in den Mempool legen       |
| POST    | `/api/mine`                   | Offene Transaktionen minen, Belohnung gibt's|
| GET     | `/api/status`                 | Blockanzahl, Gültigkeit, offene Tx-Anzahl   |

Die Chain wird nach jeder Änderung automatisch in `chain_data.json`
gespeichert.

## Website online stellen (z.B. gibb-coin.kbb8vy5sjy.workers.dev)

`index.html` kann so wie sie ist z.B. auf Cloudflare Pages/Workers
deployt werden. Das API-Backend (`api.py`) muss dafür separat gehostet
werden (z.B. Render, Railway, Fly.io oder ein eigener Server), da Cloudflare
Workers selbst keine Python-Laufzeit für FastAPI bietet.

Sobald die API unter einer öffentlichen URL läuft, in `index.html` ganz
unten im `<script>`-Block die Zeile anpassen:

```js
const API_BASE = window.GIBBCOIN_API_BASE || "https://DEINE-API-URL";
```

## Tests

```bash
python -m unittest -v
```

Dies ist eine Lernimplementierung, keine produktionsreife Kryptowährung:
Es gibt noch keine Wallet-Signaturen und kein echtes Netzwerk-Konsens-Modell
zwischen mehreren Knoten — die Chain lebt in einer einzigen API-Instanz.
