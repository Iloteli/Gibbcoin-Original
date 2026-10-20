-- Bestenliste (Blockchain), robuste Version: gelöschte Konten ausblenden und aktuelle Benutzernamen zeigen.
-- Funktioniert auch, wenn die Funktion andere Leerzeichen/Zeilenumbrüche hat. Mehrfach ausführen ist sicher.
do $migration$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'leaderboard_current_names') > 0 then return; end if;
  v_new := pg_catalog.regexp_replace(v_def,
    'from\s+public\.blocks\s+where\s+miner_user_id\s+is\s+not\s+null',
    'from public.blocks where miner_user_id is not null and exists (select 1 from public.profiles lp where lp.id = miner_user_id) /* leaderboard_current_names */', 'i');
  if v_new = v_def then
    raise warning 'get_blockchain_overview: Bestenliste nicht gefunden – unverändert gelassen';
    return;
  end if;
  v_new := pg_catalog.regexp_replace(v_new,
    'max\(\s*miner_label\s*\)\s+as\s+miner_label',
    $r$coalesce((select nullif(lp.username, '') from public.profiles lp where lp.id = miner_user_id), max(miner_label)) as miner_label$r$, 'i');
  execute v_new;
end;
$migration$;

notify pgrst, 'reload schema';

select case when pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), 'leaderboard_current_names') > 0
  then 'OK: Bestenliste zeigt nur noch bestehende Konten' else 'FEHLER: Bestenliste nicht geändert – Ausgabe an Claude schicken' end as status;
