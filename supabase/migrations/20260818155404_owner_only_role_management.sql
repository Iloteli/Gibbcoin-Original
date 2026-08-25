do $$
declare
  v_owner_user_id uuid := 'd465d88f-0acb-4bff-ad55-945761acaeea';
  v_old_role text;
begin
  select p.role
  into v_old_role
  from public.profiles p
  where p.id = v_owner_user_id
  for update;

  if v_old_role is null then
    raise exception 'owner_account_not_found';
  end if;

  if v_old_role <> 'super_admin' then
    update public.profiles
    set role = 'super_admin'
    where id = v_owner_user_id;

    perform private.write_admin_audit(
      v_owner_user_id,
      v_owner_user_id,
      'ROLE_CHANGED',
      pg_catalog.jsonb_build_object('role', v_old_role),
      pg_catalog.jsonb_build_object('role', 'super_admin'),
      'Owner-Konto eingerichtet'
    );

    insert into public.notifications (user_id, kind, title, message)
    values (
      v_owner_user_id,
      'role_changed',
      'Ownerrechte aktiviert',
      'Du bist jetzt Owner. Nur du kannst Adminrechte vergeben oder entfernen.'
    );
  end if;
end;
$$;

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
  v_owner_user_id uuid;
  v_actor_role text;
  v_old_role text;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Rollenänderung'
  );
begin
  v_owner_user_id := private.require_admin();

  select p.role into v_actor_role
  from public.profiles p
  where p.id = v_owner_user_id;

  if v_actor_role <> 'super_admin' then raise exception 'owner_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_owner_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = p_target_user_id
  for update;

  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_old_role = p_role then return p_role; end if;

  update public.profiles set role = p_role where id = p_target_user_id;
  perform private.write_admin_audit(
    v_owner_user_id,
    p_target_user_id,
    'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role),
    pg_catalog.jsonb_build_object('role', p_role),
    v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id,
    'role_changed',
    case when p_role = 'admin' then 'Administratorrechte erhalten' else 'Administratorrechte entfernt' end,
    case when p_role = 'admin' then 'Der Owner hat dir Administratorrechte gegeben.' else 'Der Owner hat deine Administratorrechte entfernt.' end
  );
  return p_role;
end;
$$;

revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;
