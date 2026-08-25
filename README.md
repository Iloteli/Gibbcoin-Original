# GIBB Coin

Eine sichere Beta der internen GIBB-Schulwährung. GIBB Coins sind kein gesetzliches Zahlungsmittel, nicht auszahlbar und nur innerhalb der App nutzbar. Die „Blockchain“ ist eine SHA-256-Hash-Kette und keine dezentrale öffentliche Blockchain.

Produktive Website: `https://gibb-coin.kbb8vy5sjy.workers.dev/`. Jeder Push auf `main` wird nach erfolgreichen Tests automatisch über Cloudflare veröffentlicht.

## Einrichtung

1. In Supabase ein neues Projekt erstellen.
2. Alle Migrationen aus `supabase/migrations/` in ihrer Dateireihenfolge anwenden.
3. Unter **Authentication → Providers → Google** den Google-Provider aktivieren und Client-ID/Client-Secret eintragen.
4. In der Google Cloud Console folgende autorisierte Redirect URI hinterlegen:

   `https://PROJECT.supabase.co/auth/v1/callback`

5. Unter **Authentication → URL Configuration** `https://gibb-coin.kbb8vy5sjy.workers.dev/` als Site URL und `https://gibb-coin.kbb8vy5sjy.workers.dev/**` als Redirect URL eintragen. Für lokale Entwicklung zusätzlich `http://localhost:3000/**` erlauben.
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

## Lokal starten

```bash
pnpm install
pnpm dev
```

## Sicherheitsmodell

- Ein `auth.users`-Trigger legt Profil und Wallet atomar an. `UNIQUE(user_id)` verhindert mehrfaches Startguthaben.
- Der Client besitzt keinerlei `INSERT`-, `UPDATE`- oder `DELETE`-Rechte auf Wallets und Transaktionen.
- Der Browser besitzt auch keine Schreibrechte auf Rollen. Manipulierte DevTools-, JavaScript- oder REST-Aufrufe können weder Coins erzeugen noch den eigenen Benutzer zum Admin machen.
- Transfers laufen nur über `transfer_gibb`. Eine transaktionsweite Advisory-Sperre und Row Locks verhindern Double Spending und konkurrierende Hash-Verzweigungen.
- RLS erlaubt ausschließlich das eigene Profil, Wallet und eigene Transaktionen zu lesen.
- Die Empfängersuche gibt nur Namen, Avatar und eine maskierte E-Mail zurück.
- Interne Datenbankfehler werden in der UI nicht offengelegt.
- Bezahlte Coins werden nur durch einen signierten Stripe-Webhook gutgeschrieben. Eindeutige Event- und Checkout-IDs machen Webhook-Wiederholungen idempotent.
- `admin_set_role` prüft die aktuelle Rolle serverseitig; ein normaler Nutzer kann die RPC zwar anfragen, erhält aber immer `admin_required`.
- Eine Kontosperre sperrt Wallet und Supabase-Auth-Konto gemeinsam über die JWT-geschützte Edge Function `admin-account-status`. Gesperrte Admins verlieren zusätzlich sofort ihre Admin-RPC-Rechte.
- Jeder Admin richtet einen eigenen vierstelligen PIN ein. Der PIN wird ausschließlich als bcrypt-Hash gespeichert, nach fünf Fehlversuchen 15 Minuten gesperrt und bei jeder Coin-Gutschrift im Adminpanel erneut verlangt.
- Die alten Admin-Endpunkte für direkte Guthabenänderungen sind für Browserkonten gesperrt. Nur die PIN-geschützten Endpunkte können Admin-Coins gutschreiben oder einen Kontostand setzen.

## Manueller Abnahmetest

Für einen vollständigen OAuth-/Transfer-/Kauftest werden ein eingerichtetes Supabase-Projekt, zwei echte Google-Konten und ein Stripe-Testkonto benötigt. Prüfe Login, Reload, Logout/erneuten Login ohne erneute 200 GIBB, Transfer in beide Richtungen, zu hohe/ungültige Beträge, Karte und TWINT im Test-Checkout, Webhook-Wiederholung ohne doppelte Gutschrift, Verlauf, Hash-Prüfung und mobile Ansicht.
