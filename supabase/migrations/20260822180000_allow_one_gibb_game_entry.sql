-- Let members play a round from the same normal wallet with as little as 1 GIBB.
alter table public.game_rounds
  drop constraint game_rounds_wager_check,
  add constraint game_rounds_wager_check check (wager between 1 and 1000);

alter table public.blackjack_sessions
  drop constraint blackjack_sessions_wager_check,
  add constraint blackjack_sessions_wager_check check (wager between 1 and 1000);

do $migration$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.play_instant_game(text,text,bigint)'::regprocedure::oid)
    into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager < 5') = 0 then
    raise exception 'play_instant_game wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager < 5', 'p_wager < 1');

  select pg_catalog.pg_get_functiondef('public.start_blackjack(bigint)'::regprocedure::oid)
    into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager < 5') = 0 then
    raise exception 'start_blackjack wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager < 5', 'p_wager < 1');
end;
$migration$;
