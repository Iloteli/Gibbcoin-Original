-- Einzelne Konten können dauerhaft vor Bannen und Löschen geschützt werden.
-- Der Schutz hängt an der unveränderlichen User-ID, nicht am Benutzernamen:
-- Benutzernamen sind selbst änderbar und wären damit fälschbar.
--
-- Durchgesetzt wird der Schutz auf Datenbankebene, nicht in der Edge Function.
-- Damit greift er für jeden Weg: admin_apply_wallet_status, dessen v2-Variante,
-- direkte service_role-Updates und jede künftige Funktion.
create table if not exists private.protected_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null default 'Dauerhaft geschütztes Konto',
  added_at timestamptz not null default now()
);

revoke all on table private.protected_accounts
from public, anon, authenticated;

create or replace function private.is_protected_account(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.protected_accounts a
    where a.user_id = p_user_id
  );
$$;

revoke all on function private.is_protected_account(uuid)
from public, anon, authenticated;

-- Sperren verhindern: greift auf der Tabelle selbst, egal wer schreibt.
-- Entsperren bleibt jederzeit erlaubt.
create or replace function private.protect_account_from_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'locked'
     and old.status is distinct from 'locked'
     and private.is_protected_account(new.user_id)
  then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;
  return new;
end;
$$;

revoke all on function private.protect_account_from_ban()
from public, anon, authenticated;

drop trigger if exists protect_account_from_ban on public.wallets;
create trigger protect_account_from_ban
before update on public.wallets
for each row
execute function private.protect_account_from_ban();

-- Löschen verhindern: derselbe Trigger, der schon Owner-Konten schützt.
-- Die bestehenden Regeln bleiben unverändert, der Schutz kommt davor.
create or replace function private.protect_owner_auth_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target_role text;
  v_actor_user_id uuid;
  v_actor_role text;
  v_actor_status text;
  v_actor_is_primary_owner boolean := false;
begin
  if private.is_protected_account(old.id) then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;

  select p.role into v_target_role
  from public.profiles p
  where p.id = old.id;

  select a.actor_user_id, p.role, w.status
  into v_actor_user_id, v_actor_role, v_actor_status
  from private.account_deletion_authorizations a
  join public.profiles p on p.id = a.actor_user_id
  join public.wallets w on w.user_id = a.actor_user_id
  where a.target_user_id = old.id
    and a.expires_at >= now()
    and a.consumed_at is null;

  v_actor_is_primary_owner := private.is_primary_owner(v_actor_user_id);

  if v_actor_user_id is null
     or v_actor_user_id = old.id
     or coalesce(v_actor_role, '') not in ('admin', 'super_admin')
     or coalesce(v_actor_status, '') <> 'active'
     or (v_actor_role = 'super_admin' and not v_actor_is_primary_owner) then
    raise exception using errcode = '42501', message = 'account_deletion_not_authorized';
  end if;

  if v_target_role = 'super_admin' and not v_actor_is_primary_owner then
    raise exception using errcode = '42501', message = 'owner_account_is_protected';
  end if;

  if v_target_role = 'admin' and v_actor_role <> 'super_admin' then
    raise exception using errcode = '42501', message = 'admin_account_is_protected';
  end if;

  update private.account_deletion_authorizations
  set consumed_at = now()
  where target_user_id = old.id;

  return old;
end;
$$;

revoke all on function private.protect_owner_auth_deletion()
from public, anon, authenticated;

-- Die Schutzliste ist bewusst leer. Ein Konto wird geschützt, indem seine
-- User-ID hier eingetragen wird, zum Beispiel:
--   insert into private.protected_accounts (user_id, reason)
--   values ('00000000-0000-0000-0000-000000000000'::uuid, 'Ilja')
--   on conflict (user_id) do nothing;

notify pgrst, 'reload schema';
