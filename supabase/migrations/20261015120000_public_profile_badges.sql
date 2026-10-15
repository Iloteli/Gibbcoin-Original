-- Öffentliche Profile: Zähler für Abzeichen und Statistik (nur Summen, keine Details).
-- Gesendet/Empfangen, gespielte Runden, gemintete Blöcke, Handel am Markt und Mitgliedsnummer.
create or replace function public.get_public_profile_extras(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_joined timestamptz;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select w.created_at into v_joined from public.wallets w where w.user_id = p_user_id;
  if v_joined is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'profile_not_found'); end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'member_no', (select pg_catalog.count(*) from public.wallets w where w.created_at <= v_joined),
    'members', (select pg_catalog.count(*) from public.wallets),
    'sent', (select pg_catalog.count(*) from public.transactions t where t.sender_user_id = p_user_id and coalesce(t.type, '') not in ('GAME_ENTRY', 'MARKET_SELL')),
    'received', (select pg_catalog.count(*) from public.transactions t where t.receiver_user_id = p_user_id and t.sender_user_id is not null),
    'games', (select pg_catalog.count(*) from public.transactions t where t.sender_user_id = p_user_id and t.type = 'GAME_ENTRY'),
    'game_wins', (select pg_catalog.count(*) from public.transactions t where t.receiver_user_id = p_user_id and t.type = 'GAME_REWARD'),
    'blocks', (select pg_catalog.count(*) from public.transactions t where t.receiver_user_id = p_user_id and t.type = 'MINING_REWARD'),
    'trades', (select pg_catalog.count(*) from public.market_events e where e.user_id = p_user_id)
  );
end;
$$;
revoke all on function public.get_public_profile_extras(uuid) from public, anon;
grant execute on function public.get_public_profile_extras(uuid) to authenticated;

notify pgrst, 'reload schema';
