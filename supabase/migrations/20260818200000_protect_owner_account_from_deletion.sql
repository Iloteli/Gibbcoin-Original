-- Absolute last line of defence for the Owner account. This trigger runs for
-- every Auth deletion, including service-role and Dashboard initiated deletes.

create or replace function private.protect_owner_auth_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.profiles p
    where p.id = old.id
      and p.role = 'super_admin'
  ) then
    raise exception using
      errcode = '42501',
      message = 'owner_account_is_protected';
  end if;

  return old;
end;
$$;

revoke all on function private.protect_owner_auth_deletion()
from public, anon, authenticated;

drop trigger if exists protect_owner_auth_deletion on auth.users;
create trigger protect_owner_auth_deletion
  before delete on auth.users
  for each row execute procedure private.protect_owner_auth_deletion();
