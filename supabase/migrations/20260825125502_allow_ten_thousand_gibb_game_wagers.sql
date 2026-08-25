-- Wager-based games accept 1..10,000 GIBB. Dino Run keeps its fixed 150 GIBB
-- entry, so game_rounds still permits zero for historic free Dino runs.
alter table public.game_rounds
  drop constraint if exists game_rounds_wager_check;
alter table public.game_rounds
  add constraint game_rounds_wager_check check (wager between 0 and 10000);

alter table public.game_rounds
  drop constraint if exists game_rounds_payout_check;
alter table public.game_rounds
  add constraint game_rounds_payout_check check (payout between 0 and 2500000);

alter table public.blackjack_sessions
  drop constraint if exists blackjack_sessions_wager_check;
alter table public.blackjack_sessions
  add constraint blackjack_sessions_wager_check check (wager between 1 and 10000);

alter table public.blackjack_sessions
  drop constraint if exists blackjack_sessions_payout_check;
alter table public.blackjack_sessions
  add constraint blackjack_sessions_payout_check check (payout between 0 and 25000);

alter table public.poker_sessions
  drop constraint if exists poker_sessions_wager_check;
alter table public.poker_sessions
  add constraint poker_sessions_wager_check check (wager between 1 and 10000);

alter table public.poker_sessions
  drop constraint if exists poker_sessions_payout_check;
alter table public.poker_sessions
  add constraint poker_sessions_payout_check check (payout between 0 and 2500000);

do $$
declare
  v_definition text;
begin
  select pg_catalog.pg_get_functiondef('public.play_instant_game(text,text,bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager > 1000') = 0 then
    raise exception 'play_instant_game wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager > 1000', 'p_wager > 10000');

  select pg_catalog.pg_get_functiondef('public.start_blackjack(bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager > 1000') = 0 then
    raise exception 'start_blackjack wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager > 1000', 'p_wager > 10000');

  select pg_catalog.pg_get_functiondef('public.start_poker(bigint)'::pg_catalog.regprocedure)
  into v_definition;
  if pg_catalog.strpos(v_definition, 'p_wager > 1000') = 0 then
    raise exception 'start_poker wager guard changed unexpectedly';
  end if;
  execute pg_catalog.replace(v_definition, 'p_wager > 1000', 'p_wager > 10000');
end;
$$;

revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.start_blackjack(bigint)
from public, anon, authenticated;
revoke all on function public.start_poker(bigint)
from public, anon, authenticated;

grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.start_blackjack(bigint)
to authenticated;
grant execute on function public.start_poker(bigint)
to authenticated;
