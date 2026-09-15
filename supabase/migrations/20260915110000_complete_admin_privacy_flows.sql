-- Complete the admin/privacy flows with bounded reads and transactional writes.

create or replace function public.update_my_profile_atomic(
  p_username text,
  p_display_name text,
  p_bio text,
  p_profile_color text,
  p_avatar_url text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
  v_name text := pg_catalog.btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(pg_catalog.btrim(coalesce(p_bio, '')), '');
  v_color text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_profile_color, '')));
  v_avatar text := nullif(pg_catalog.btrim(coalesce(p_avatar_url, '')), '');
  v_current_avatar text;
begin
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_username');
  end if;
  if char_length(v_name) not between 2 and 60 then
    return jsonb_build_object('ok', false, 'error', 'invalid_display_name');
  end if;
  if v_bio is not null and char_length(v_bio) > 180 then
    return jsonb_build_object('ok', false, 'error', 'invalid_bio');
  end if;
  if v_color !~ '^#[0-9a-f]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_profile_color');
  end if;
  if exists (select 1 from public.profiles where lower(username) = v_username and id <> v_user_id) then
    return jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;
  select avatar_url into v_current_avatar from public.profiles where id = v_user_id for update;
  if v_avatar is distinct from v_current_avatar and v_avatar is not null
     and v_avatar !~ ('^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/avatars/'
       || v_user_id::text || '/[A-Za-z0-9._-]+$') then
    return jsonb_build_object('ok', false, 'error', 'invalid_avatar_url');
  end if;
  update public.profiles
  set username = v_username, display_name = v_name, bio = v_bio,
      profile_color = v_color, avatar_url = v_avatar, updated_at = clock_timestamp()
  where id = v_user_id;
  return jsonb_build_object('ok', true, 'username', v_username,
    'display_name', v_name, 'bio', v_bio, 'profile_color', v_color, 'avatar_url', v_avatar);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'username_taken');
end;
$$;

revoke all on function public.update_my_profile_atomic(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.update_my_profile_atomic(text,text,text,text,text) to authenticated;

create or replace function public.admin_add_class_member(p_class_id uuid, p_user_id uuid, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare actor uuid := private.require_admin(); pin_status text;
begin
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status); end if;
  if not exists (select 1 from public.admin_classes where id = p_class_id)
     or not exists (select 1 from auth.users where id = p_user_id) then
    return jsonb_build_object('ok', false, 'error', 'class_or_user_not_found');
  end if;
  insert into public.admin_class_members(class_id, user_id) values (p_class_id, p_user_id)
  on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_remove_class_member(p_class_id uuid, p_user_id uuid, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare actor uuid := private.require_admin(); pin_status text;
begin
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status); end if;
  delete from public.admin_class_members where class_id = p_class_id and user_id = p_user_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_list_control_center_page(p_page integer default 1, p_page_size integer default 12)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare actor uuid := private.require_admin(); v_page integer := greatest(coalesce(p_page, 1), 1);
v_size integer := least(greatest(coalesce(p_page_size, 12), 1), 50); r jsonb;
begin
  select jsonb_build_object(
    'classes', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('members', coalesce((select jsonb_agg(m.user_id) from public.admin_class_members m where m.class_id = c.id), '[]'::jsonb)) order by c.created_at desc) from public.admin_classes c
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.support_cases t
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'exports', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.admin_export_requests e
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'privacy', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.privacy_requests p
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'shop', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.marketplace_items i
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.task_key) from public.daily_tasks t
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'seasons', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at desc) from public.seasons s
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb)
  ) into r;
  return r;
end $$;

revoke all on function public.admin_add_class_member(uuid,uuid,text), public.admin_remove_class_member(uuid,uuid,text), public.admin_list_control_center_page(integer,integer) from public, anon;
grant execute on function public.admin_add_class_member(uuid,uuid,text), public.admin_remove_class_member(uuid,uuid,text), public.admin_list_control_center_page(integer,integer) to authenticated;
