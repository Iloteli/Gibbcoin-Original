-- Close legacy transfer paths and raise the security baseline for group invites,
-- account deletion, MFA and administrative PIN attempts.

revoke all on function public.transfer_gibb(uuid, bigint)
from public, anon, authenticated;
drop function if exists public.transfer_gibb(uuid, bigint);

alter table public.group_wallets
  drop constraint if exists group_wallets_join_code_check;

update public.group_wallets
set join_code = upper(encode(extensions.gen_random_bytes(16), 'hex'));

alter table public.group_wallets
  add constraint group_wallets_join_code_check
  check (join_code ~ '^[A-F0-9]{32}$');

create or replace function public.create_group_wallet(p_name text, p_description text default null)
returns table(group_id uuid, join_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_group_id uuid;
  v_join_code text;
begin
  p_name := pg_catalog.btrim(coalesce(p_name, ''));
  p_description := nullif(pg_catalog.btrim(coalesce(p_description, '')), '');
  if pg_catalog.char_length(p_name) not between 3 and 60 then raise exception 'invalid_group_name'; end if;
  if pg_catalog.char_length(coalesce(p_description, '')) > 160 then raise exception 'description_too_long'; end if;
  if (select pg_catalog.count(*) from public.group_wallets g where g.owner_user_id = v_user_id) >= 10 then
    raise exception 'group_limit_reached';
  end if;

  loop
    v_join_code := upper(encode(extensions.gen_random_bytes(16), 'hex'));
    exit when not exists (select 1 from public.group_wallets g where g.join_code = v_join_code);
  end loop;

  insert into public.group_wallets(name, description, owner_user_id, join_code)
  values (p_name, p_description, v_user_id, v_join_code)
  returning id into v_group_id;

  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'owner');

  return query select v_group_id, v_join_code;
end;
$$;

create or replace function public.join_group_wallet(p_join_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_group_id uuid;
  v_code text := upper(pg_catalog.btrim(coalesce(p_join_code, '')));
begin
  if v_code !~ '^[A-F0-9]{32}$' then raise exception 'invalid_join_code'; end if;
  if (select pg_catalog.count(*) from public.group_wallet_members m where m.user_id = v_user_id) >= 30 then
    raise exception 'membership_limit_reached';
  end if;
  select g.id into v_group_id from public.group_wallets g where g.join_code = v_code;
  if v_group_id is null then raise exception 'group_not_found'; end if;
  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'member')
  on conflict (group_id, user_id) do nothing;
  return v_group_id;
end;
$$;

create or replace function private.assert_mfa_if_enrolled(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'authentication_required';
  end if;
  select p.role into v_role from public.profiles p where p.id = p_user_id;
  if v_role in ('admin', 'super_admin')
     and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
end;
$$;

create or replace function private.check_admin_pin(p_admin_user_id uuid, p_pin text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pin private.admin_pins%rowtype;
  v_failed_attempts smallint;
begin
  select ap.* into v_pin from private.admin_pins ap
  where ap.admin_user_id = p_admin_user_id for update;
  if v_pin.admin_user_id is null then return 'not_set'; end if;
  if v_pin.locked_until is not null and v_pin.locked_until > now() then return 'locked'; end if;

  if coalesce(p_pin, '') ~ '^[0-9]{4}$'
     and extensions.crypt(coalesce(p_pin, ''), v_pin.pin_hash) = v_pin.pin_hash then
    update private.admin_pins set failed_attempts = 0, locked_until = null, updated_at = now()
    where admin_user_id = p_admin_user_id;
    return 'ok';
  end if;

  v_failed_attempts := least(v_pin.failed_attempts + 1, 5);
  update private.admin_pins
  set failed_attempts = v_failed_attempts,
      locked_until = case when v_failed_attempts >= 5 then now() + interval '1 hour' else null end,
      updated_at = now()
  where admin_user_id = p_admin_user_id;
  return case when v_failed_attempts >= 5 then 'locked' else 'invalid' end;
end;
$$;

create or replace function private.anonymize_deleted_group_entries()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.group_wallet_entries
  set actor_label = case when actor_user_id = old.id then 'Gelöschtes Konto' else actor_label end,
      recipient_label = case when recipient_user_id = old.id then 'Gelöschtes Konto' else recipient_label end
  where actor_user_id = old.id or recipient_user_id = old.id;
  return old;
end;
$$;

revoke all on function private.anonymize_deleted_group_entries() from public, anon, authenticated;
drop trigger if exists before_auth_user_delete_anonymize_group_entries on auth.users;
create trigger before_auth_user_delete_anonymize_group_entries
before delete on auth.users
for each row execute procedure private.anonymize_deleted_group_entries();
