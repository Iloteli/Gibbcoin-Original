# Eigene Blockchain — Server-Betrieb

Ein eigenständiger Blockchain-Node, der komplett auf deinem eigenen Server läuft
(kein Internet-/Drittanbieter-Dienst nötig) und dessen Mining speziell für
**schwache Geräte** (Raspberry Pi, alte Laptops, kleine VPS) optimiert ist:

- SHA-256 statt speicher-/rechenintensiver Algorithmen
- Niedrige Start-Difficulty (3), die sich automatisch an dein Gerät anpasst
  (Ziel: ca. 5 Sekunden pro Block — wird das Gerät überlastet, sinkt die
  Schwierigkeit automatisch wieder)
- Kein erzwungenes Multi-Threading — läuft sparsam auf einem einzelnen Kern

## 1. Installation auf dem Server

```bash
# Python 3 + pip sollten vorhanden sein
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## 2. Starten

```bash
python3 node.py --host 0.0.0.0 --port 5000
```

Der Server ist danach unter `http://<deine-server-ip>:5000` erreichbar.
Achte darauf, den Port in deiner Firewall freizugeben, falls nötig
(z. B. `ufw allow 5000/tcp`).

## 3. API-Endpunkte

| Methode | Pfad                | Zweck                                      |
|---------|---------------------|---------------------------------------------|
| GET     | `/status`           | Status des Nodes (Chain-Länge, Difficulty…) |
| GET     | `/chain`            | Komplette Blockchain anzeigen               |
| POST    | `/transactions/new` | Neue Transaktion einreichen                 |
| GET     | `/mine?miner=NAME`  | Ausstehende Transaktionen minen             |
| POST    | `/nodes/register`   | Andere Nodes (Server) bekanntmachen         |
| GET     | `/nodes/resolve`    | Konsens mit anderen Nodes herstellen        |

### Beispiele (curl)

```bash
# Transaktion einreichen
curl -X POST http://SERVER-IP:5000/transactions/new \
  -H "Content-Type: application/json" \
  -d '{"sender":"Alice","recipient":"Bob","amount":10}'

# Minen
curl "http://SERVER-IP:5000/mine?miner=MeinName"

# Chain ansehen
curl http://SERVER-IP:5000/chain
```

## 4. Dauerbetrieb mit systemd (empfohlen für Server)

Damit der Node auch nach einem Neustart automatisch läuft, lege
`/etc/systemd/system/blockchain-node.service` an:

```ini
[Unit]
Description=Eigenstaendiger Blockchain Node
After=network.target

[Service]
Type=simple
User=DEIN_BENUTZERNAME
WorkingDirectory=/pfad/zu/deinem/projekt
ExecStart=/pfad/zu/deinem/projekt/venv/bin/python3 node.py --host 0.0.0.0 --port 5000
Restart=on-failure
# Zusätzlicher Schutz für schwache Geräte: begrenzt CPU/RAM-Nutzung
CPUQuota=50%
MemoryMax=256M

[Install]
WantedBy=multi-user.target
```

Aktivieren:

```bash
sudo systemctl daemon-reload
sudo systemctl enable blockchain-node
sudo systemctl start blockchain-node
sudo systemctl status blockchain-node
```

`CPUQuota` und `MemoryMax` sind besonders auf schwacher Hardware nützlich,
damit das Mining nicht das ganze System blockiert.

## 5. Mehrere Server/Nodes verbinden (optional)

Läuft die Blockchain auf mehreren Servern, können sie sich synchronisieren:

```bash
curl -X POST http://SERVER-A:5000/nodes/register \
  -H "Content-Type: application/json" \
  -d '{"nodes": ["http://SERVER-B:5000"]}'

curl http://SERVER-A:5000/nodes/resolve
```

Der Konsens-Mechanismus wählt automatisch die längste gültige Chain im Netzwerk.

## 6. Produktions-Hinweis

Der eingebaute Flask-Server (`app.run(...)`) ist für Entwicklung/kleine Server
gedacht. Für höhere Zuverlässigkeit auf einem "echten" Server kannst du
optional **gunicorn** davorschalten (bei sehr schwachen Geräten aber nicht
zwingend nötig):

```bash
pip install gunicorn
gunicorn -w 1 -b 0.0.0.0:5000 node:app
```

(`-w 1` = 1 Worker-Prozess, schont schwache Hardware.)

## 7. Difficulty manuell anpassen

Falls dein Gerät sehr schwach ist und selbst Difficulty 1 zu lange dauert,
kannst du in `node.py` beim Start `Blockchain(difficulty=1)` setzen und/oder
`MIN_DIFFICULTY = 1` beibehalten — niedriger als 1 macht bei SHA-256 wenig Sinn,
da dann quasi jeder Hash sofort passt.
