-- Ilja ist Haupt-Owner und geschützt; Owner-Rechte können vergeben und entzogen werden.
--
-- * Haupt-Owner ist nur noch Ilja (ilja.podorieszach@icloud.com). Nur er darf Owner-Rechte
--   vergeben/entziehen sowie andere Owner sperren oder löschen.
-- * Iljas Owner-Rolle kann NIE entzogen werden; Ilja kann weder gesperrt (Wallet oder Login)
--   noch gelöscht werden. Owner werden darf er jederzeit.
-- * Andere Owner sind nicht geschützt: Ilja kann sie herabstufen, sperren oder löschen.

create or replace function private.is_ilja(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null and exists (
    select 1 from auth.users u
    where u.id = p_user_id and pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
  );
$$;
revoke all on function private.is_ilja(uuid) from public, anon, authenticated;

create or replace function private.is_primary_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_ilja(p_user_id)
     and exists (select 1 from public.profiles p where p.id = p_user_id and p.role = 'super_admin');
$$;
revoke all on function private.is_primary_owner(uuid) from public, anon, authenticated;

-- Geschützt: Einträge der Schutzliste plus immer Ilja.
create table if not exists private.protected_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now()
);
create or replace function private.is_protected_account(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null and (
    exists (select 1 from private.protected_accounts a where a.user_id = p_user_id)
    or private.is_ilja(p_user_id)
  );
$$;
revoke all on function private.is_protected_account(uuid) from public, anon, authenticated;

-- Login-Sperre (auth.users.banned_until) für geschützte Konten verhindern.
create or replace function private.protect_account_from_auth_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.banned_until is not null
     and new.banned_until > pg_catalog.now()
     and new.banned_until is distinct from old.banned_until
     and private.is_protected_account(new.id) then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_account_from_auth_ban on auth.users;
create trigger protect_account_from_auth_ban before update of banned_until on auth.users
  for each row execute function private.protect_account_from_auth_ban();

-- Iljas Owner-Rolle und Profil schützen (gilt für alle Wege, auch direktes SQL).
create or replace function private.protect_ilja_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if private.is_ilja(old.id) then
      raise exception using errcode = '42501', message = 'account_is_protected';
    end if;
    return old;
  end if;
  if old.role = 'super_admin' and new.role is distinct from 'super_admin' and private.is_ilja(old.id) then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_ilja_profile on public.profiles;
create trigger protect_ilja_profile before update of role or delete on public.profiles
  for each row execute function private.protect_ilja_profile();

-- Rollenänderungen über die App nur über admin_set_role (setzt die Freigabe).
create or replace function private.prevent_api_profile_role_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_api_request boolean := nullif(pg_catalog.current_setting('request.jwt', true), '') is not null
    or nullif(pg_catalog.current_setting('request.jwt.claims', true), '') is not null;
  v_authorized boolean := coalesce(pg_catalog.current_setting('gibbcoin.owner_role_change', true), '') = 'authorized';
begin
  if new.role is distinct from old.role and v_api_request and not v_authorized then
    raise exception using errcode = '42501', message = 'owner_only_role_change';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_protect_role_from_api on public.profiles;
create trigger profiles_protect_role_from_api before update of role on public.profiles
  for each row execute function private.prevent_api_profile_role_changes();

-- Rollen setzen: Admins/Owner verwalten user/admin; nur Ilja vergibt und entzieht Owner.
create or replace function public.admin_set_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text default 'Administrative Rollenänderung'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_admin_role text;
  v_old_role text;
  v_reason text := coalesce(nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''), 'Administrative Rollenänderung');
begin
  v_admin_user_id := private.require_admin();
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;
  if v_admin_role <> 'super_admin' then raise exception 'owner_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_admin_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin', 'super_admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role from public.profiles p where p.id = p_target_user_id for update;
  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = p_role then return p_role; end if;
  -- Owner-Rechte vergeben oder entziehen: nur der Haupt-Owner (Ilja)
  if (v_old_role = 'super_admin' or p_role = 'super_admin') and not private.is_primary_owner(v_admin_user_id) then
    raise exception 'primary_owner_required';
  end if;
  if v_old_role = 'super_admin' and private.is_ilja(p_target_user_id) then
    raise exception 'account_is_protected';
  end if;

  perform pg_catalog.set_config('gibbcoin.owner_role_change', 'authorized', true);
  update public.profiles set role = p_role where id = p_target_user_id;
  perform pg_catalog.set_config('gibbcoin.owner_role_change', '', true);

  perform private.write_admin_audit(
    v_admin_user_id, p_target_user_id, 'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role), pg_catalog.jsonb_build_object('role', p_role), v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id, 'role_changed',
    case p_role when 'super_admin' then 'Owner-Rechte erhalten' when 'admin' then 'Administratorrechte erhalten' else 'Rechte entfernt' end,
    case p_role when 'super_admin' then 'Du bist jetzt Owner.' when 'admin' then 'Du besitzt jetzt Administratorrechte.' else 'Deine Admin- bzw. Owner-Rechte wurden entfernt.' end
  );
  return p_role;
end;
$$;
revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
