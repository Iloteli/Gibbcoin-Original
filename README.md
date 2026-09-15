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

Die Formeln für Header, Merkle-Root und Nullbits sind in `app/lib/blockchain-core.js` und in den SQL-Funktionen `private.block_header`, `private.merkle_root` und `private.leading_zero_bits` identisch umgesetzt; `tests/blockchain.test.mjs` prüft die JavaScript-Seite gegen Node-Crypto. `scripts/simple-blockchain.mjs` ist ein eigenständiges Mini-Beispiel zum Verstehen des Prinzips (`node scripts/simple-blockchain.mjs`).

### Lokaler Blockchain-Node zum Testen

`blockchain-node/` ist ein eigenständiger Node ohne Abhängigkeiten (kein Supabase nötig) mit Verwaltungs-Website: Wallets anlegen, Coins senden (Mempool), Blöcke minen (einzeln oder Dauerbetrieb), Kette prüfen, Block manipulieren (Demo), Belohnung/Schwierigkeit einstellen. Header, Merkle-Root und Nullbits sind dieselben Formeln wie in der App.

```bash
pnpm chain
```

Danach `http://localhost:8787` öffnen. Daten liegen in `blockchain-node/data/chain.json` (nicht versioniert). Port über `PORT`, Datei über `CHAIN_FILE`. Für einen Server: `docker build -f blockchain-node/Dockerfile -t gibb-chain . && docker run -p 8787:8787 -v gibb-chain-data:/app/blockchain-node/data gibb-chain`.

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

Für einen vollständigen Auth-/Transfer-/Kauftest werden ein separates Supabase-Stagingprojekt, zwei Testkonten mit aktivierter MFA und – nur wenn Käufe aktiviert werden – ein Stripe-Testkonto benötigt. Prüfe Registrierung, E-Mail-Bestätigung, Login, MFA, Reload, Logout/erneuten Login ohne erneutes Startguthaben, Transfer in beide Richtungen, Einsatz- und Verlustlimits, Gruppeneinladung mit 32-stelligem Code, zeitlich begrenzte Sperren, Accountlöschung, Verlauf/CSV/Beleg, Hash-Prüfung, Leaderboards und mobile Ansicht. Stripe ist in der App standardmäßig deaktiviert und darf nur im Testmodus geprüft werden.
