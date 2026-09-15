# Ilja als Haupt-Owner aktivieren

**Problem:** Ilja sieht im Admin-Panel die Ban- und Lösch-Buttons nicht.

**Ursache:** Iljas Rolle in der Datenbank ist `admin`, nicht `super_admin`.

## Lösung in Supabase

1. Öffnen Sie Supabase Editor → **`public` → `profiles` Tabelle**
2. Suchen Sie Iljas Konto (E-Mail: `ilja.podorieszach@icloud.com`)
3. **Ändern Sie die `role`-Spalte von `admin` auf `super_admin`**

## Automatische Erkennung

Nach dieser Änderung funktioniert alles automatisch:
- Der Code in `AdminPanel.tsx` (Zeile 219) prüft:
  ```typescript
  const isPrimaryOwner = currentRole === "super_admin" && 
    (currentUserId === PRIMARY_OWNER_USER_ID || 
     (currentUserEmail ?? "").toLowerCase() === PRIMARY_OWNER_EMAIL);
  ```
- Ilja wird über die E-Mail `ilja.podorieszach@icloud.com` erkannt
- Die Datenbank-Migration `20260915120000_add_ilja_as_primary_owner.sql` prüft auf beiden Seiten (User-ID und E-Mail)
- Ban- und Lösch-Buttons sind sofort sichtbar

## Aktionen, die dann verfügbar sind

- ✅ Konten **bannen/entbannen** (zeitlich oder dauerhaft)
- ✅ Konten **dauerhaft löschen**
- ✅ Auch andere **Owner-Konten** bannen/löschen (nur Haupt-Owner Robyn und Ilja)
