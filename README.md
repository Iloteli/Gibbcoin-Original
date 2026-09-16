# GIBB Coin

Eine sichere Beta der internen GIBB-Schulwährung. GIBB Coins sind kein gesetzliches Zahlungsmittel, nicht auszahlbar und nur innerhalb der App nutzbar. Die „Blockchain“ besteht aus einer SHA-256-Hash-Kette pro Transaktion und darüber liegenden Proof-of-Work-Blöcken innerhalb der App – sie ist keine dezentrale öffentliche Blockchain.

Produktive Website: `https://gibb-coin-schulwallet.pxfyvkgcs6.chatgpt.site/`. Diese ChatGPT Site ist die offizielle öffentliche Web-App; Änderungen werden zusätzlich auf GitHub versioniert.

## Einrichtung

1. In Supabase ein neues Projekt erstellen.
2. Alle Migrationen aus `supabase/migrations/` in ihrer Dateireihenfolge anwenden.
3. Unter **Authentication → Providers → Google** den Google-Provider aktivieren und Client-ID/Client-Secret eintragen.
4. In der Google Cloud Console folgende autorisierte Redirect URI hinterlegen:

   `https://PROJECT.supabase.co/auth/v1/callback`

5. Unter **Authentication → URL Configuration** `https://gibb-coin-schulwallet.pxfyvkgcs6.chatgpt.site/` als Site URL und `https://gibb-coin-schulwallet.pxfyvkgcs6.chatgpt.site/**` als Redirect URL eintragen. Für lokale Entwicklung zusätzlich `http://localhost:3000/**` erlauben.
6. `.env.example` nach `.env.local` kopieren und Projekt-URL sowie öffentlichen Anon-Key einsetzen. Der Anon-Key darf öffentlich sein; Service-Role-Key und Google-Secret gehören niemals in den Client.

Ein Google-Konto ist nicht erforderlich: Die Login-Seite unterstützt zusätzlich echte Supabase-Anmeldung und Registrierung per E-Mail und Passwort. Wenn E-Mail-Bestätigungen aktiviert sind, muss ein neues Konto zuerst den Link aus der Bestätigungs-E-Mail öffnen.

Benachrichtigungen lassen sich pro Benutzer ein- und ausschalten. Für empfangene Coins gibt es einen eigenen Schalter; neue Nachrichten erscheinen live in der App. Optionale Browser-Meldungen werden nur nach ausdrücklicher Browser-Freigabe angezeigt.

## Stripe und TWINT einrichten

1. Stripe-Händlerkonto vollständig verifizieren und im Dashboard **TWINT** sowie Karten aktivieren. TWINT setzt CHF und eine öffentlich erreichbare Website mit Impressum, Adresse und Kontaktangaben voraus.
2. Die beiden Edge Functions `create-checkout-session` und `stripe-webhook` deployen. Für `stripe-webhook` bleibt die JWT-Prüfung laut `supabase/config.toml` aus, weil Stripe keinen Benutzer-JWT sendet; stattdessen wird jede Anfrage mit dem Stripe-Signatur-Secret geprüft.
3. In den Supabase Function Secrets setzen: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` und `APP_URL`. `SUPABASE_URL`, `SUPABASE_ANON_KEY` und `SUPABASE_SERVICE_ROLE_KEY` stellt Supabase bereit. Diese Werte niemals als `NEXT_PUBLIC_...` veröffentlichen.
4. Im Stripe Dashboard einen Webhook für `https://PROJECT.supabase.co/functions/v1/stripe-webhook` anlegen und mindestens `checkout.session.completed` sowie `checkout.session.async_payment_succeeded` abonnieren.
5. Zuerst mit Stripe-Testschlüsseln und dem TWINT-Testflow prüfen. Erst nach Prüfung von Impressum, Kaufbedingungen, Rückerstattungen, Datenschutz, Steuern und Minderjährigenschutz Live-Schlüssel verwenden.

Auszahlungen aus Stripe/TWINT gehen an das im verifizierten Stripe-Händlerkonto hinterlegte Bankkonto. Eine private TWINT-Telefonnummer kann nicht als automatisches Checkout-Auszahlungsziel verwendet werden, weil sie keine signierte Zahlungsbestätigung für die sichere Coin-Gutschrift bereitstellt.

Die Pakete sind serverseitig fix: 100 GIBB = CHF 1.00, 300 GIBB = CHF 3.00, 750 GIBB = CHF 7.50. Der Browser kann Preis oder Coinmenge nicht verändern.

## Lokal starten und prüfen

```bash
pnpm install
pnpm lint
pnpm test
pnpm dev
```

Benötigt wird Node.js 22 oder neuer. Die GitHub-Prüfung verwendet ausdrücklich Node.js 22 und führt Installation, Lint, Build und Tests bei jedem Pull Request aus.

## Sicheres Staging vor Produktion

Die Workflow-Datei `.github/workflows/staging-supabase.yml` ist absichtlich nur manuell startbar und verweigert die produktive Projekt-ID. Im GitHub-Environment `staging` werden drei Secrets benötigt: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID` für ein separates Testprojekt und `SUPABASE_DB_PASSWORD`. Erst nach erfolgreichem Test werden Änderungen separat für Produktion freigegeben.

Vor einer Live-Migration ist ein Datenbank-Backup Pflicht. Die aktuelle Sicherheitsmigration rotiert bestehende Gruppencodes auf 32 Hex-Zeichen, verlangt für privilegierte Adminaktionen eine bestätigte MFA-Sitzung (`aal2`) und entzieht der alten RPC `transfer_gibb` alle Browserrechte.

## Blockchain und Mining

Über der Transaktions-Hash-Kette liegt seit Migration `20260915090000_add_gibb_blockchain.sql` eine echte Blockstruktur:

- `public.blocks` versiegelt unbestätigte Transaktionen zu Blöcken mit Merkle-Root, Vorgänger-Hash, Zeitstempel, Schwierigkeit und Nonce. Der Genesis-Block wird von der Migration selbst erzeugt und enthält alle bis dahin vorhandenen Transaktionen.
- Blöcke werden im Browser gefunden (Tab **Blockchain**): Ein Web Worker rechnet SHA-256 über den Block-Header, bis der Hash die geforderten führenden Nullbits erreicht. Der Server prüft in `submit_mined_block` Header, Merkle-Root, Zeitstempel und Proof of Work exakt nach und schreibt die Belohnung als `MINING_REWARD` über den bestehenden Ledger-Pfad. Der Browser kann weder Belohnung noch Schwierigkeit beeinflussen.
- Die Schwierigkeit regelt sich automatisch auf die Ziel-Blockzeit ein (Standard 120 s) und sinkt schrittweise, wenn die Kette stillsteht. Pro Miner gilt nach einem Treffer eine Pause.
- `verify_blockchain()` rechnet alle Blöcke serverseitig nach; `get_block_transactions()` zeigt pro Block nur Hashes und Zeitpunkte, keine Beträge oder Beteiligten.
- Admins steuern Belohnung, Ziel-Blockzeit, Schwierigkeitsgrenzen und Pause im Blockchain-Tab (Admin-PIN nötig, Änderungen landen im Audit-Log). Mining lässt sich dort abschalten.

Die Formeln für Header, Merkle-Root und Nullbits sind in `app/lib/blockchain-core.js` und in den SQL-Funktionen `private.block_header`, `private.merkle_root` und `private.leading_zero_bits` identisch umgesetzt; `tests/blockchain.test.mjs` prüft die JavaScript-Seite gegen Node-Crypto. `scripts/simple-blockchain.py` ist ein eigenständiges Mini-Beispiel zum Verstehen des Prinzips (`python scripts/simple-blockchain.py`).

### Auf einem Debian-Server installieren

Ein fertiges Installationsskript richtet alles ein (Node.js, Build, zwei systemd-Dienste, die beim Booten starten):

```bash
git clone https://github.com/Iloteli/Gibbcoin-Original.git
cd Gibbcoin-Original
sudo bash deploy/install-debian.sh
```

Danach laufen dauerhaft: die Website auf Port 3000 (`gibb-website.service`) und der Blockchain-Node mit Reserve-Miner auf Port 8787 (`gibb-node.service`). Die Browser der Besucher erreichen den Node automatisch unter derselben Domain wie die Website (Port 8787). Status/Logs: `systemctl status gibb-node gibb-website`, `journalctl -u gibb-node -f`. Aktualisieren nach Änderungen: `sudo bash deploy/update-debian.sh` (holt den neuesten Stand von GitHub, baut neu und startet die Dienste neu). Ports/Benutzer sind über Umgebungsvariablen einstellbar (`WEBSITE_PORT`, `NODE_PORT`, `RUN_USER`). Für Port 80/HTTPS einen Reverse-Proxy (nginx/Caddy) vor die Website setzen.

### Beide Websites mit GitHub synchron halten

Die GibbCoin-Website (`app/`) und die Blockchain-Website (`blockchain-node/`) liegen im selben Repo und laufen damit immer dieselbe Version. Um lokal exakt den Stand von `Iloteli/Gibbcoin-Original` (main) zu übernehmen und neu zu bauen:

```bash
pnpm deploy
```

Das holt den aktuellen GitHub-Stand (`git reset --hard` auf main – lokale, nicht committete Änderungen werden dabei verworfen), installiert bei Bedarf Abhängigkeiten und baut die Website neu. Mit `pnpm deploy -- --run` werden zusätzlich beide Server gestartet (Website auf 3000, Node auf 8787).

### Lokaler Blockchain-Node zum Testen

`blockchain-node/` ist ein eigenständiger Node ohne Abhängigkeiten (kein Supabase nötig) mit Verwaltungs-Website: Wallets anlegen, Coins senden (Mempool), Kette prüfen, Block manipulieren (Demo), Belohnung/Schwierigkeit einstellen. **Gemint wird im Browser der Nutzer** (Web Worker auf dem eigenen Prozessor): Der Server gibt nur Blockvorlagen heraus (`POST /api/template`) und prüft eingereichte Nonces vollständig nach (`POST /api/submit`) – er rechnet selbst keinen einzigen Hash. Header, Merkle-Root und Nullbits sind dieselben Formeln wie in der App.

```bash
pnpm chain
```

Danach `http://localhost:8787` öffnen.

**Konto anmelden & lokal minen von der echten Website.** Im Blockchain-Tab der echten GibbCoin-Website (localhost:3000) meldet sich das aktuell angemeldete Konto automatisch beim lokalen Node an (`POST /api/register`) und erscheint dadurch sofort auf der Blockchain-Website – auch ohne Service-Role-Key. Ein Button startet für genau dieses Konto einen lokalen Miner auf dem PC, auf dem der Node läuft (`POST /api/local-miner`), mit Live-Anzeige von Hashrate, gefundenen Blöcken und Guthaben. Der Node erlaubt dafür CORS. Läuft der Node nicht, zeigt die Karte einen Hinweis und die Node-Adresse ist einstellbar.

**Website-Konten automatisch spiegeln.** Der Node kann die Konten der echten GibbCoin-Website (Supabase) automatisch übernehmen und in `chain.json` speichern. Weil die Row-Level-Security das Auflisten aller Nutzer mit dem öffentlichen Schlüssel verhindert, braucht der Node den **Service-Role-Key** des Supabase-Projekts. Diesen Secret-Key niemals ins Repository legen: entweder als Umgebungsvariablen `SUPABASE_URL` und `SUPABASE_SERVICE_ROLE_KEY`, oder in der gitignorierten Datei `blockchain-node/supabase.local.json` (Vorlage: `supabase.local.example.json`). Ist er hinterlegt, spiegelt der Node beim Start und danach alle 60 s alle Profile als Konten (Adresse `sb_<user-id>`, Guthaben aus Supabase); auf der Website zeigt eine Statusleiste den Stand und einen „Jetzt synchronisieren"-Knopf. Ohne Key läuft der Node normal mit eigenen Wallets weiter.

**Markt & Kurs (echtes Orderbuch).** Jedes Wallet hat neben GIBB ein faires, gleiches Startguthaben in Rappen (interne Recheneinheit, 1 GIBB startet bei 1 Rappen = 0.01 CHF). Über die Blockchain-Website stellt man echte Kauf-/Verkaufsaufträge (Limit-Orders); passen zwei zusammen, wird gehandelt. Der Kurs ist der Preis des letzten echten Handels – er entsteht ausschliesslich aus Angebot und Nachfrage, nichts wird simuliert. GIBB kommen aus dem Mining, dadurch trifft echtes Angebot auf echte Nachfrage. Admin-Einstellungen (Startpreis, Startguthaben, Gebühr, Min-Order, Markt an/aus) sind auf der Website konfigurierbar; Standard ist gebührenfrei. Der Rahmen ist bewusst eine interne Einheit ohne Auszahlung; eine spätere Unterlegung mit echtem Geld (Stripe/TWINT) ist vorgesehen. API: `GET /api/market`, `POST /api/order`, `POST /api/order-cancel`.

**Lokaler Miner auf dem eigenen PC** (nutzt alle Prozessorkerne, ~0,5 MH/s pro Kern):

```bash
pnpm miner -- --name "Mein PC"
```

Beim ersten Start legt der Miner ein Wallet auf dem Node an und zeigt die Adresse; danach mit `--wallet Gxxxx` weiterverwenden. Optionen: `--server http://host:8787` (entfernter Node), `--threads 4`. Der Miner holt Blockvorlagen, sucht die Nonce lokal und reicht Treffer ein; der Node prüft alles nach. Mehrere PCs können gleichzeitig minen – die Schwierigkeit passt sich an. Daten liegen in `blockchain-node/data/chain.json` (nicht versioniert). Port über `PORT`, Datei über `CHAIN_FILE`. Für einen Server: `docker build -f blockchain-node/Dockerfile -t gibb-chain . && docker run -p 8787:8787 -v gibb-chain-data:/app/blockchain-node/data gibb-chain`.

## Sicherheitsmodell

Für die Produktivdatenbank gibt es `.github/workflows/production-supabase.yml`. Der Workflow ist ebenfalls nur manuell startbar, verlangt beim Start die Eingabe `MIGRATE` und eine Backup-Bestätigung, läuft im GitHub-Environment `production` und wendet Migrationen erst nach Lint, Build, Tests und einem Trockenlauf an. Benötigt werden dort `SUPABASE_ACCESS_TOKEN` und `SUPABASE_PROJECT_ID`. Der projektgebundene, kurzlebige Token erlaubt der Supabase CLI einen temporären Datenbank-Login, sodass kein dauerhaftes Datenbankpasswort in GitHub gespeichert werden muss. Diese Werte gehören ausschliesslich in die GitHub-Secrets, niemals ins Repository.

- Ein `auth.users`-Trigger legt Profil und Wallet atomar an. `UNIQUE(user_id)` verhindert mehrfaches Startguthaben.
- Der Client besitzt keinerlei `INSERT`-, `UPDATE`- oder `DELETE`-Rechte auf Wallets und Transaktionen.
- Der Browser besitzt auch keine Schreibrechte auf Rollen. Manipulierte DevTools-, JavaScript- oder REST-Aufrufe können weder Coins erzeugen noch den eigenen Benutzer zum Admin machen.
- Transfers laufen nur über `transfer_coins`. Die stillgelegte Alt-RPC `transfer_gibb` besitzt keine Browserrechte mehr. Eine transaktionsweite Advisory-Sperre und Row Locks verhindern Double Spending und konkurrierende Hash-Verzweigungen.
- RLS erlaubt ausschließlich das eigene Profil, Wallet und eigene Transaktionen zu lesen.
- Die Empfängersuche gibt nur Namen, Avatar und eine maskierte E-Mail zurück.
- Interne Datenbankfehler werden in der UI nicht offengelegt.
- Die Plus/Minus-Statistik auf der Home-Ansicht kann jeder Benutzer über `reset_my_wallet_stats` selbst zurücksetzen. Gespeichert wird nur ein Zeitpunkt pro Benutzer in `private.wallet_stats_resets`; Guthaben, Transaktionsverlauf und Hash-Kette bleiben unverändert.
- Bezahlte Coins werden nur durch einen signierten Stripe-Webhook gutgeschrieben. Eindeutige Event- und Checkout-IDs machen Webhook-Wiederholungen idempotent.
- `admin_set_role` prüft die aktuelle Rolle serverseitig; ein normaler Nutzer kann die RPC zwar anfragen, erhält aber immer `admin_required`.
- Eine Kontosperre sperrt Wallet und Supabase-Auth-Konto gemeinsam über die JWT-geschützte Edge Function `admin-account-status`. Gesperrte Admins verlieren zusätzlich sofort ihre Admin-RPC-Rechte.
- Jeder Admin richtet einen eigenen vierstelligen PIN ein. Der PIN wird ausschließlich als bcrypt-Hash gespeichert und nach fünf Fehlversuchen 15 Minuten gesperrt. Er wird einmal beim Öffnen des Adminpanel-Tabs abgefragt; beim Verlassen des Tabs verfällt die Freigabe sofort.
- Die alten Admin-Endpunkte für direkte Guthabenänderungen sind für Browserkonten gesperrt. Nur die PIN-geschützten Endpunkte können Admin-Coins gutschreiben oder einen Kontostand setzen.
- Für privilegierte Adminaktionen ist zusätzlich eine vollständig bestätigte MFA-Sitzung erforderlich.
- Spiele zeigen Regeln und Auszahlungen offen an. Verdeckte Ergebnismanipulationen sind serverseitig deaktiviert; freiwillige Einsatz-, Verlust-, Pausen- und Selbstausschlussgrenzen werden vor jedem Spiel geprüft.
- Profile, tägliche Aufgaben, Challenges, kosmetische Shop-Artikel, Saisons und Zeit-Leaderboards werden serverseitig gespeichert. Coins, Belohnungen und Käufe können nicht allein durch Browsercode verändert werden.

## Manueller Abnahmetest

Für einen vollständigen Auth-/Transfer-/Kauftest werden ein separates Supabase-Stagingprojekt, zwei Testkonten mit aktivierter MFA und – nur wenn Käufe aktiviert werden – ein Stripe-Testkonto benötigt. Prüfe Registrierung, E-Mail-Bestätigung, Login, MFA, Reload, Logout/erneuten Login ohne erneutes Startguthaben, Transfer in beide Richtungen, Einsatz- und Verlustlimits, Gruppeneinladung mit 32-stelligem Code, zeitlich begrenzte Sperren, Accountlöschung, Verlauf/CSV/Beleg, Hash-Prüfung, Leaderboards und mobile Ansicht. Stripe ist in der App standardmäßig deaktiviert und darf nur im Testmodus geprüft werden
