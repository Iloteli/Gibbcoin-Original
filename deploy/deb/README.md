# GIBB Coin – .deb-Installer

Ein einziges Paket, das auf deinem Debian/Ubuntu-Server **alles** einrichtet:
Node.js + pnpm, holt die App aus dem Git-Repo, baut sie und startet zwei
systemd-Dienste (starten automatisch beim Booten, Neustart bei Absturz):

- `gibb-node` – Blockchain-Node + API + Reserve-Miner (Port **8787**)
- `gibb-website` – GibbCoin-Website (Port **3000**)

## Installieren

Die Datei `gibbcoin_1.0.0_all.deb` auf den Server kopieren und:

```bash
sudo apt install ./gibbcoin_1.0.0_all.deb
```

`apt` zieht die Abhängigkeiten (`curl`, `git`, `ca-certificates`, `gnupg`) und
führt danach automatisch die Einrichtung aus (Node installieren, App bauen,
Dienste starten). Das dauert beim ersten Mal einige Minuten.

Danach erreichbar unter `http://DEIN-SERVER:3000` (Website) und
`http://DEIN-SERVER:8787` (Node). Beim ersten Öffnen der Node-Seite als
**ilja** registrieren – der erste Nutzer wird automatisch Owner.

## Einstellungen

Ports, Git-Branch usw. in `/etc/default/gibbcoin` ändern, dann:

```bash
sudo gibbcoin-update
```

## Aktualisieren

```bash
sudo gibbcoin-update
```

Holt den neuesten Stand aus dem Repo, baut neu und startet die Dienste neu.

## Entfernen

```bash
sudo apt remove gibbcoin      # Dienste stoppen/entfernen, App bleibt
sudo apt purge  gibbcoin      # zusätzlich /opt/gibbcoin, Config und Benutzer löschen
```

## Paket selbst neu bauen

Ohne `dpkg-deb` – nur Node nötig:

```bash
node deploy/deb/build-deb.mjs
```

Erzeugt `deploy/gibbcoin_<version>_all.deb`. Quellen liegen unter
`deploy/deb/` (`control/` = Metadaten & Wartungsskripte, `payload/` = Dateien
die auf dem Server landen, `build-deb.mjs` = Packer).
