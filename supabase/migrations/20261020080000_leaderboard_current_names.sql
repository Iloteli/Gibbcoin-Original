-- Bestenliste (Blockchain): aktueller Benutzername statt des Namens beim Minen,
-- gelöschte Konten fallen heraus (ihre Blöcke bleiben in der Kette gültig).
do $migration$
declare
  v_def text;
  v_old text := $o$    select miner_user_id, max(miner_label) as miner_label, count(*) as blocks, sum(reward) as reward
    from public.blocks where miner_user_id is not null
    group by miner_user_id order by count(*) desc, sum(reward) desc limit 5$o$;
  v_new text := $n$    select b.miner_user_id, coalesce(nullif(max(p.username), ''), max(p.display_name), max(b.miner_label)) as miner_label, count(*) as blocks, sum(b.reward) as reward
    from public.blocks b join public.profiles p on p.id = b.miner_user_id -- leaderboard_current_names
    group by b.miner_user_id order by count(*) desc, sum(b.reward) desc limit 5$n$;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'leaderboard_current_names') > 0 then return; end if;
  if pg_catalog.strpos(v_def, v_old) = 0 then
    raise warning 'get_blockchain_overview: Bestenliste nicht gefunden – unverändert gelassen';
    return;
  end if;
  execute pg_catalog.replace(v_def, v_old, v_new);
end;
$migration$;

notify pgrst, 'reload schema';
