-- 1) Owner dürfen anderen Ownern GIBB abziehen – nur Ilja ist davon ausgenommen.
--    Admins (ohne Owner-Rolle) dürfen weiterhin keinem Owner etwas abziehen.
-- 2) Die Chain-Seite (Node) liest die Einstellungen der Hauptseite über
--    public.get_shared_chain_settings() (nur Einstellungen, keine Kontodaten).

do $migration$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.admin_adjust_balance_secure(uuid, bigint, text, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'owner_coin_removal_v2') = 0 then
    v_new := pg_catalog.regexp_replace(
      v_def,
      $re$if\s+v_target_role\s*=\s*'super_admin'\s+and\s+p_target_user_id\s*<>\s*v_admin_user_id\s+then$re$,
      $rep$if v_target_role = 'super_admin' and p_target_user_id <> v_admin_user_id
       and (private.is_ilja(p_target_user_id) or v_admin_role is distinct from 'super_admin') then -- owner_coin_removal_v2$rep$
    );
    if v_new = v_def then
      raise exception 'admin_adjust_balance_secure: Owner-Prüfung nicht gefunden';
    end if;
    -- v_admin_role muss vor der Prüfung gesetzt sein
    if pg_catalog.strpos(v_new, 'into v_admin_role') = 0 then
      raise exception 'admin_adjust_balance_secure: v_admin_role wird nicht gesetzt';
    end if;
    execute v_new;
  end if;
end;
$migration$;

create or replace function public.get_shared_chain_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'blockchain', private.blockchain_settings(),
    'market', (select pg_catalog.jsonb_build_object(
      'price', s.price, 'sell_fee', s.sell_fee, 'enabled', s.enabled, 'max_trade', s.max_trade,
      'min_price', s.min_price, 'max_price', s.max_price
    ) from private.market_settings s where s.singleton)
  );
$$;
revoke all on function public.get_shared_chain_settings() from public;
grant execute on function public.get_shared_chain_settings() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
