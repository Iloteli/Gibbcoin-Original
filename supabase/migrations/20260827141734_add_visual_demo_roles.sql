-- Clearly labelled, visual-only demo badges for harmless team pranks.
-- These rows never change public.profiles.role and never grant permissions.

create table if not exists private.visual_demo_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  visual_role text not null check (visual_role in ('demo_admin', 'demo_owner')),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table private.visual_demo_roles enable row level security;
revoke all on table private.visual_demo_roles from public, anon, authenticated;

create or replace function public.get_my_visual_role()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_visual_role text;
begin
  select r.visual_role into v_visual_role
  from private.visual_demo_roles r
  where r.user_id = v_user_id;
  return v_visual_role;
end;
$$;

revoke all on function public.get_my_visual_role() from public, anon;
grant execute on function public.get_my_visual_role() to authenticated;

create or replace function public.admin_list_visual_roles()
returns table(user_id uuid, visual_role text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return query
  select r.user_id, r.visual_role
  from private.visual_demo_roles r
  order by r.updated_at desc, r.user_id;
end;
$$;

revoke all on function public.admin_list_visual_roles() from public, anon, authenticated;
grant execute on function public.admin_list_visual_roles() to authenticated;

create or replace function public.admin_set_visual_role(
  p_target_user_id uuid,
  p_visual_role text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_target_exists boolean;
begin
  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_required');
  end if;
  if p_target_user_id = v_admin_user_id then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_visual_role_self');
  end if;
  if p_visual_role is not null and p_visual_role not in ('demo_admin', 'demo_owner') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_visual_role');
  end if;

  select exists(
    select 1 from public.profiles p where p.id = p_target_user_id
  ) into v_target_exists;
  if not v_target_exists then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;

  if p_visual_role is null then
    delete from private.visual_demo_roles where user_id = p_target_user_id;
  else
    insert into private.visual_demo_roles(user_id, visual_role, updated_by)
    values (p_target_user_id, p_visual_role, v_admin_user_id)
    on conflict (user_id) do update
      set visual_role = excluded.visual_role,
          updated_by = excluded.updated_by,
          updated_at = now();
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'visual_role', p_visual_role);
end;
$$;

revoke all on function public.admin_set_visual_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_visual_role(uuid, text, text) to authenticated;
