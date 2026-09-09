-- Jeder Benutzer darf die Plus/Minus-Statistik auf der Home-Ansicht selbst
-- zurücksetzen. Der Reset merkt sich nur einen Zeitpunkt: Guthaben,
-- Transaktionsverlauf und Hash-Kette bleiben unverändert.
create table if not exists private.wallet_stats_resets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reset_at timestamptz not null,
  updated_at timestamptz not null default now()
);

revoke all on table private.wallet_stats_resets
from public, anon, authenticated;

create or replace function public.my_wallet_stats_reset()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_since timestamptz;
begin
  select r.reset_at into v_since
  from private.wallet_stats_resets r
  where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object('ok', true, 'since', v_since);
end;
$$;

create or replace function public.reset_my_wallet_stats()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_reset_at timestamptz := pg_catalog.clock_timestamp();
begin
  insert into private.wallet_stats_resets (user_id, reset_at, updated_at)
  values (v_user_id, v_reset_at, v_reset_at)
  on conflict (user_id) do update
  set reset_at = excluded.reset_at,
      updated_at = excluded.updated_at;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'since', v_reset_at,
    'ledger_preserved', true,
    'balances_preserved', true
  );
end;
$$;

revoke all on function public.my_wallet_stats_reset()
from public, anon, authenticated;
grant execute on function public.my_wallet_stats_reset()
to authenticated;
revoke all on function public.reset_my_wallet_stats()
from public, anon, authenticated;
grant execute on function public.reset_my_wallet_stats()
to authenticated;
