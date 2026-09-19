-- Allow group owners to rename their wallet without exposing direct table writes.

create or replace function public.rename_group_wallet(p_group_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_name text := pg_catalog.btrim(coalesce(p_name, ''));
begin
  if pg_catalog.char_length(v_name) not between 3 and 60 then
    raise exception 'invalid_group_name';
  end if;

  if not exists (
    select 1
    from public.group_wallet_members m
    where m.group_id = p_group_id
      and m.user_id = v_user_id
      and m.role = 'owner'
  ) then
    raise exception 'group_owner_required';
  end if;

  update public.group_wallets
  set name = v_name, updated_at = pg_catalog.now()
  where id = p_group_id;

  if not found then
    raise exception 'group_not_found';
  end if;
end;
$$;

revoke all on function public.rename_group_wallet(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_group_wallet(uuid, text) to authenticated;
