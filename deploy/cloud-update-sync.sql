-- GIBB Coin: Chain-Seite <-> Hauptseite synchron (Coins verwalten, Konten-Abgleich, Mining-Belohnungen).
-- Kann mehrfach ausgeführt werden.

-- ===== 20261013160000_admin_coin_grants_switch.sql =====
-- "Admin Coins geben" abschaltbar – standardmässig AUS.
-- Eingeschaltet wird es nur auf der Chain-Seite (Ilja); die überträgt den Schalter mit dem
-- Schlüssel der Chain-Seite über public.node_set_admin_features(). Coins abziehen bleibt möglich.

create or replace function private.admin_coin_grants_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value ->> 'coin_grants')::boolean
                   from private.admin_control_settings s where s.key = 'admin_features'), false);
$$;
revoke all on function private.admin_coin_grants_enabled() from public, anon, authenticated;

-- Für das Admin-Panel: ist Gutschreiben gerade erlaubt?
create or replace function public.get_admin_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('coin_grants', private.admin_coin_grants_enabled()); $$;
revoke all on function public.get_admin_features() from public, anon;
grant execute on function public.get_admin_features() to authenticated;

-- Chain-Seite -> Hauptseite (mit dem Schlüssel aus "sudo gibb-chain-key")
create or replace function public.node_set_admin_features(p_key text, p_features jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('admin_features',
          pg_catalog.jsonb_build_object('coin_grants', coalesce((p_features ->> 'coin_grants')::boolean, false)),
          null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true, 'coin_grants', private.admin_coin_grants_enabled());
end;
$$;
revoke all on function public.node_set_admin_features(text, jsonb) from public;
grant execute on function public.node_set_admin_features(text, jsonb) to anon, authenticated, service_role;

-- Gutschriften im Admin-Panel sperren, solange der Schalter aus ist.
do $migration$
declare
  v_def text;
  v_pos integer;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.admin_adjust_balance_secure(uuid, bigint, text, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'coin_grants_switch') = 0 then
    v_pos := pg_catalog.strpos(v_def, E'\nbegin\n');
    if v_pos = 0 then raise exception 'admin_adjust_balance_secure: Funktionsbeginn nicht gefunden'; end if;
    v_def := pg_catalog.left(v_def, v_pos + 6)
      || E'  -- coin_grants_switch: Gutschreiben nur, wenn auf der Chain-Seite eingeschaltet\n'
      || E'  if p_amount > 0 and not private.admin_coin_grants_enabled() then\n'
      || E'    return pg_catalog.jsonb_build_object(''ok'', false, ''error'', ''coin_grants_disabled'');\n'
      || E'  end if;\n'
      || pg_catalog.substr(v_def, v_pos + 7);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';

-- ===== 20261013170000_node_account_cleanup.sql =====
-- Chain-Seite räumt gelöschte Website-Konten auf: Sie fragt mit ihrem Schlüssel nach, welche
-- ihrer Website-Konten (sb_<uuid>) es noch gibt. Liefert nur IDs, die es noch gibt – keine Kontodaten.
create or replace function public.node_existing_users(p_key text, p_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_ids is null or pg_catalog.cardinality(p_ids) > 5000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_ids');
  end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'existing', coalesce((select pg_catalog.jsonb_agg(u.id) from auth.users u where u.id = any (p_ids)), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.node_existing_users(text, uuid[]) from public;
grant execute on function public.node_existing_users(text, uuid[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- ===== 20261013180000_chain_page_coin_admin.sql =====
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

-- ===== 20261013190000_node_mining_reward_key.sql =====
-- Chain-Seite und Hauptseite synchron halten:
-- Findet ein Website-Konto (sb_<uuid>) auf der Chain-Seite einen Block, wird die Belohnung mit dem
-- Schlüssel der Chain-Seite auf das Website-Wallet gebucht (einmal pro Block-Hash).
-- Die Guthaben der Chain-Seite werden danach regelmässig von der Hauptseite übernommen.

create table if not exists private.node_mining_credits (
  block_hash text primary key,
  user_id uuid,
  amount bigint not null,
  height bigint,
  transaction_id uuid,
  created_at timestamptz not null default now()
);
revoke all on table private.node_mining_credits from public, anon, authenticated;

create or replace function public.node_mining_reward(p_key text, p_user uuid, p_amount bigint, p_block_hash text, p_height bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_user is null or p_block_hash is null or pg_catalog.char_length(p_block_hash) < 16 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 10000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  if exists (select 1 from private.node_mining_credits c where c.block_hash = p_block_hash) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where user_id = p_user;
  if not found then
    -- Konto gibt es nicht mehr: als erledigt merken, damit es nicht ewig erneut versucht wird
    insert into private.node_mining_credits (block_hash, user_id, amount, height) values (p_block_hash, null, p_amount, p_height);
    return pg_catalog.jsonb_build_object('ok', true, 'skipped', 'wallet_not_found');
  end if;
  v_tx := private.append_transaction(null, p_user, p_amount, 'MINING_REWARD',
    'Chain-Seite · Block #' || coalesce(p_height::text, '?') || ' gefunden');
  insert into private.node_mining_credits (block_hash, user_id, amount, height, transaction_id)
  values (p_block_hash, p_user, p_amount, p_height, v_tx);
  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_mining_reward(text, uuid, bigint, text, bigint) from public;
grant execute on function public.node_mining_reward(text, uuid, bigint, text, bigint) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
