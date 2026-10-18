#!/usr/bin/env bash
# Übersicht über alle GIBB-Coin-Befehle auf dem Server.
#   gibb-help
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
VERSION="$(bash "$APP_DIR/deploy/version.sh" 2>/dev/null || echo "?")"
cat <<HELP

  GIBB Coin – Server-Befehle                         Version $VERSION
  ─────────────────────────────────────────────────────────────────────

  Updates
    sudo gibb-update                 neueste Version holen und alles neu starten
    sudo gibb-autoupdate [an|aus]    automatische Updates (alle 5 Min.) ein/aus
    gibb-version                     installierte Version anzeigen

  Sicherung
    sudo gibb-backup                 Sicherung jetzt erstellen
    sudo gibb-backup liste           vorhandene Sicherungen anzeigen
    sudo gibb-backup auto [an|aus]   tägliche Sicherung um 03:30 ein/aus
    sudo gibb-backup zurueck DATEI   Sicherung wiederherstellen

  Wartung & Besucher
    sudo gibb-wartung 30m "Text"     Wartungsmodus (s/m/h/d), z. B. 2h
    sudo gibb-wartung aus            Wartungsmodus beenden
    sudo gibb-neuladen               alle offenen Seiten neu laden

  Anmeldung & Sicherheit
    sudo gibb-code                   Server-Code für den Owner-Login (5 Min. gültig)
    sudo gibb-sudo [aus]             Knöpfe der Chain-Seite ohne sudo-Passwort (ein/aus)
    sudo gibb-chain-key              neuen Chain-Schlüssel für Supabase erzeugen

  Zustand prüfen
    systemctl status gibb-node       Chain-Server
    systemctl status gibb-website    Hauptseite
    sudo journalctl -u gibb-node -n 50 --no-pager    letzte Meldungen der Chain

HELP
