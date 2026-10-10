-- Abschluss für die SELBST GEHOSTETE Datenbank (nicht für die Supabase-Cloud).
-- Läuft nach allen Migrationen. Ergänzt Funktionen, die die App aufruft, die aber
-- nur in der Cloud angelegt wurden, plus die Gutschrift für Node-Mining.
-- Alles ist idempotent.

-- Nutzerliste für das Admin-Panel.
create or replace function public.admin_list_users(p_query text default '')
returns table (
  user_id uuid, username text, display_name text, role text, visual_role text,
  balance bigint, wallet_status text, locked_until timestamptz, lock_reason text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_needle text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
begin
  perform private.require_admin();
  return query
  select p.id, coalesce(p.username, ''), p.display_name, p.role, v.visual_role,
         w.balance, w.status, w.locked_until, w.lock_reason
  from public.profiles p
  join public.wallets w on w.user_id = p.id
  left join private.visual_demo_roles v on v.user_id = p.id
  where v_needle = ''
     or pg_catalog.strpos(pg_catalog.lower(coalesce(p.username, '')), v_needle) > 0
     or pg_catalog.strpos(pg_catalog.lower(p.display_name), v_needle) > 0
  order by p.display_name
  limit 500;
end;
$$;
revoke all on function public.admin_list_users(text) from public, anon;
grant execute on function public.admin_list_users(text) to authenticated;

-- Empfängersuche (Senden, Zahlungen): nur Benutzername und Anzeigename, nie E-Mail.
create or replace function public.search_users(p_query text)
returns table (user_id uuid, username text, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_needle text := pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(coalesce(p_query, '')), '@'));
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if pg_catalog.char_length(v_needle) < 2 then return; end if;
  return query
  select p.id, coalesce(p.username, ''), p.display_name
  from public.profiles p
  join public.wallets w on w.user_id = p.id and w.status = 'active'
  where p.id <> auth.uid()
    and p.email not like '%@gibbcoin.invalid'
    and (pg_catalog.strpos(pg_catalog.lower(coalesce(p.username, '')), v_needle) > 0
      or pg_catalog.strpos(pg_catalog.lower(p.display_name), v_needle) > 0)
  order by (pg_catalog.lower(coalesce(p.username, '')) = v_needle) desc, p.display_name
  limit 10;
end;
$$;
revoke all on function public.search_users(text) from public, anon;
grant execute on function public.search_users(text) to authenticated;

-- QR-Wallet: Empfänger über die Konto-ID auflösen.
create or replace function public.get_recipient(p_user_id uuid)
returns table (user_id uuid, username text, display_name text, wallet_code text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  return query
  select p.id, coalesce(p.username, ''), p.display_name,
         pg_catalog.upper(pg_catalog.right(pg_catalog.replace(w.id::text, '-', ''), 6))
  from public.profiles p
  join public.wallets w on w.user_id = p.id and w.status = 'active'
  where p.id = p_user_id and p.id <> auth.uid();
end;
$$;
revoke all on function public.get_recipient(uuid) from public, anon;
grant execute on function public.get_recipient(uuid) to authenticated;

-- Prüft die Hash-Kette mit derselben Formel wie private.append_transaction.
create or replace function public.verify_hash_chain()
returns table (valid boolean, checked bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  item record;
  v_previous text := pg_catalog.repeat('0', 64);
  v_expected text;
  v_count bigint := 0;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  for item in select t.sender_user_id, t.receiver_user_id, t.amount, t.created_at, t.previous_hash, t.hash
              from public.transactions t order by t.chain_index loop
    v_expected := pg_catalog.encode(extensions.digest(
      coalesce(item.sender_user_id::text, '') || coalesce(item.receiver_user_id::text, '') || item.amount::text ||
      pg_catalog.to_char(item.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || v_previous,
      'sha256'), 'hex');
    if item.previous_hash <> v_previous or item.hash <> v_expected then
      return query select false, v_count; return;
    end if;
    v_previous := item.hash;
    v_count := v_count + 1;
  end loop;
  return query select true, v_count;
end;
$$;
revoke all on function public.verify_hash_chain() from public, anon;
grant execute on function public.verify_hash_chain() to authenticated;

-- Mining über den Blockchain-Node: Belohnung aufs Website-Wallet (nur service_role, einmal pro Block).
create table if not exists private.node_mining_credits (
  block_hash text primary key,
  user_id uuid not null,
  amount bigint not null,
  height bigint,
  transaction_id uuid,
  created_at timestamptz not null default now()
);
revoke all on table private.node_mining_credits from public, anon, authenticated;

create or replace function public.node_credit_mining_reward(p_user_id uuid, p_amount bigint, p_block_hash text, p_height bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx uuid;
begin
  if p_user_id is null or p_block_hash is null or pg_catalog.char_length(p_block_hash) < 16 then raise exception 'invalid_request'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000 then raise exception 'invalid_amount'; end if;
  if exists (select 1 from private.node_mining_credits c where c.block_hash = p_block_hash) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now()
  where user_id = p_user_id and status = 'active';
  if not found then raise exception 'wallet_not_found'; end if;
  v_tx := private.append_transaction(null, p_user_id, p_amount, 'MINING_REWARD',
    'Blockchain-Node · Block #' || coalesce(p_height::text, '?') || ' gefunden');
  insert into private.node_mining_credits (block_hash, user_id, amount, height, transaction_id)
  values (p_block_hash, p_user_id, p_amount, p_height, v_tx);
  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_credit_mining_reward(uuid, bigint, text, bigint) from public, anon, authenticated;
grant execute on function public.node_credit_mining_reward(uuid, bigint, text, bigint) to service_role;

-- Platzhalter des alten Owner-Kontos: keine Rechte, gesperrt, kein Login.
do $$
begin
  set local session_replication_role = replica; -- Schutz-Trigger für diesen Schritt aussetzen
  update public.profiles set role = 'user'
  where id = 'd465d88f-0acb-4bff-ad55-945761acaeea' and email = 'platzhalter-owner@gibbcoin.invalid';
  update public.wallets set status = 'locked'
  where user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'
    and exists (select 1 from public.profiles p where p.id = 'd465d88f-0acb-4bff-ad55-945761acaeea' and p.email = 'platzhalter-owner@gibbcoin.invalid');
end;
$$;

notify pgrst, 'reload schema';
