do $$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef(p.oid)
    into v_definition
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'play_casino_game'
    and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_game_key text, p_choice text, p_wager bigint';

  if v_definition is not null then
    v_definition := pg_catalog.replace(v_definition, '(\\.[0-9])', '(\.[0-9])');
    execute v_definition;
  end if;
end;
$$;
