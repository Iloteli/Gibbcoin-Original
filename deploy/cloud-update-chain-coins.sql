-- Coins geben und abziehen nur noch auf der Chain-Seite (Ilja).
-- * Hauptseite: admin_adjust_balance_secure lehnt jede Änderung ab.
-- * Chain-Seite: node_list_users / node_adjust_balance mit dem Schlüssel aus "sudo gibb-chain-key".

create or replace function private.node_key_ok(p_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_key is not null and exists (
    select 1 from private.node_settings_key k
    where k.singleton and k.key_hash = pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex')
  );
$$;
revoke all on function private.node_key_ok(text) from public, anon, authenticated;

-- Hauptseite: kein Coins geben/abziehen mehr
create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('ok', false, 'error', 'coins_on_chain_page'); $$;
revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text) from public, anon;
grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text) to authenticated;

-- Chain-Seite: alle Website-Benutzer mit Guthaben
create or replace function public.node_list_users(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'users', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', p.id, 'username', p.username, 'display_name', p.display_name, 'role', p.role,
      'balance', coalesce(w.balance, 0), 'status', coalesce(w.status, 'active')
    ) order by pg_catalog.lower(coalesce(nullif(p.username, ''), p.display_name, '')))
    from public.profiles p left join public.wallets w on w.user_id = p.id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_users(text) from public;
grant execute on function public.node_list_users(text) to anon, authenticated, service_role;

-- Chain-Seite: Coins geben (positiv) oder abziehen (negativ)
create or replace function public.node_adjust_balance(p_key text, p_user uuid, p_amount bigint, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_wallet public.wallets%rowtype;
  v_reason text := pg_catalog.left(coalesce(nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''), 'Chain-Seite'), 120);
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_user is null or p_amount is null or p_amount = 0 or pg_catalog.abs(p_amount) > 1000000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;

  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  select * into v_wallet from public.wallets where user_id = p_user for update;
  if v_wallet.id is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found'); end if;
  if p_amount < 0 and v_wallet.balance < -p_amount then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_balance', 'balance', v_wallet.balance);
  end if;

  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where id = v_wallet.id;
  if p_amount > 0 then
    v_tx := private.append_transaction(null, p_user, p_amount, 'ADMIN_MINT', 'Owner-Gutschrift · ' || v_reason);
  else
    v_tx := private.append_transaction(p_user, null, -p_amount, 'ADMIN_BURN', 'Owner-Abzug · ' || v_reason);
  end if;

  begin
    insert into public.notifications (user_id, kind, title, message)
    values (p_user, 'admin_adjustment',
            case when p_amount > 0 then 'Coins erhalten' else 'Coins abgezogen' end,
            case when p_amount > 0 then p_amount || ' GIBB wurden dir gutgeschrieben.' else (-p_amount) || ' GIBB wurden dir abgezogen.' end
              || ' Grund: ' || v_reason);
  exception when others then null; -- Mitteilung ist optional
  end;

  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx, 'balance', v_wallet.balance + p_amount);
end;
$$;
revoke all on function public.node_adjust_balance(text, uuid, bigint, text) from public;
grant execute on function public.node_adjust_balance(text, uuid, bigint, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
