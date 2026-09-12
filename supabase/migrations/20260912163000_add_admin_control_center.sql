-- First-party administration controls.  External delivery (mail, push,
-- backups and impersonation) remains deliberately outside this migration.
create table if not exists private.admin_control_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb check (jsonb_typeof(value) = 'object'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table private.admin_control_settings enable row level security;
alter table private.admin_control_settings force row level security;
revoke all on table private.admin_control_settings from public, anon, authenticated;
insert into private.admin_control_settings(key, value) values
 ('maintenance', '{"enabled":false,"message":"Kurze Wartung – bitte versuche es später erneut.","until":null}'::jsonb),
 ('announcement', '{"enabled":false,"title":"","message":"","until":null}'::jsonb),
 ('health', '{"last_check_at":null,"status":"unknown"}'::jsonb)
on conflict (key) do nothing;

create table if not exists private.admin_user_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  daily_transfer_limit bigint check (daily_transfer_limit is null or daily_transfer_limit between 1 and 1000000000),
  daily_game_limit bigint check (daily_game_limit is null or daily_game_limit between 1 and 1000000000),
  max_transfer bigint check (max_transfer is null or max_transfer between 1 and 1000000000),
  updated_by uuid references auth.users(id) on delete set null, updated_at timestamptz not null default now()
);
create table if not exists private.admin_group_limits (
  group_id uuid primary key references public.group_wallets(id) on delete cascade,
  daily_limit bigint check (daily_limit is null or daily_limit between 1 and 1000000000),
  max_entry bigint check (max_entry is null or max_entry between 1 and 1000000000),
  updated_by uuid references auth.users(id) on delete set null, updated_at timestamptz not null default now()
);
alter table private.admin_user_limits enable row level security;
alter table private.admin_user_limits force row level security;
alter table private.admin_group_limits enable row level security;
alter table private.admin_group_limits force row level security;
revoke all on table private.admin_user_limits, private.admin_group_limits from public, anon, authenticated;

create table if not exists public.admin_classes (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  school_year text not null default '' check (char_length(school_year) <= 30),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.admin_class_members (
  class_id uuid references public.admin_classes(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  primary key (class_id, user_id)
);
alter table public.admin_classes enable row level security;
alter table public.admin_classes force row level security;
alter table public.admin_class_members enable row level security;
alter table public.admin_class_members force row level security;
revoke all on table public.admin_classes, public.admin_class_members from public, anon, authenticated;
grant select on public.admin_classes, public.admin_class_members to authenticated;
create policy admin_classes_read on public.admin_classes for select to authenticated using (active);
create policy admin_class_members_read on public.admin_class_members for select to authenticated using ((select auth.uid()) = user_id);

create table if not exists public.support_cases (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  subject text not null check (char_length(subject) between 3 and 120),
  body text not null check (char_length(body) between 3 and 5000),
  status text not null default 'open' check (status in ('open','in_progress','waiting','closed')),
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  assigned_to uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.support_cases enable row level security;
alter table public.support_cases force row level security;
revoke all on table public.support_cases from public, anon, authenticated;
grant select, insert on public.support_cases to authenticated;
create policy support_cases_own on public.support_cases for select to authenticated using ((select auth.uid()) = requester_id);
create policy support_cases_create on public.support_cases for insert to authenticated with check ((select auth.uid()) = requester_id);

create table if not exists public.admin_export_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'requested' check (status in ('requested','processing','ready','expired','rejected')),
  format text not null default 'json' check (format in ('json','csv')),
  created_at timestamptz not null default now(), completed_at timestamptz
);
create table if not exists public.privacy_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  request_type text not null check (request_type in ('access','deletion','correction')),
  status text not null default 'open' check (status in ('open','in_progress','completed','rejected')),
  note text check (note is null or char_length(note) <= 1000),
  created_at timestamptz not null default now(), resolved_at timestamptz
);
alter table public.admin_export_requests enable row level security;
alter table public.admin_export_requests force row level security;
alter table public.privacy_requests enable row level security;
alter table public.privacy_requests force row level security;
revoke all on table public.admin_export_requests, public.privacy_requests from public, anon, authenticated;
grant select, insert on public.admin_export_requests, public.privacy_requests to authenticated;
create policy export_own on public.admin_export_requests for select to authenticated using ((select auth.uid()) = requester_id);
create policy export_create on public.admin_export_requests for insert to authenticated with check ((select auth.uid()) = requester_id);
create policy privacy_own on public.privacy_requests for select to authenticated using ((select auth.uid()) = requester_id);
create policy privacy_create on public.privacy_requests for insert to authenticated with check ((select auth.uid()) = requester_id);

create or replace function public.get_public_admin_notice()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ declare m jsonb; a jsonb; begin
  select value into m from private.admin_control_settings where key = 'maintenance';
  select value into a from private.admin_control_settings where key = 'announcement';
  return jsonb_build_object('maintenance', m, 'announcement', a);
end $$;

create or replace function public.admin_list_control_center()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ declare r jsonb; begin
  perform private.require_admin();
  select jsonb_build_object(
    'settings', coalesce((select jsonb_object_agg(key,value) from private.admin_control_settings),'{}'::jsonb),
    'classes', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc) from public.admin_classes c),'[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.support_cases t),'[]'::jsonb),
    'exports', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.admin_export_requests e),'[]'::jsonb),
    'privacy', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.privacy_requests p),'[]'::jsonb),
    'shop', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.marketplace_items i),'[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.task_key) from public.daily_tasks t),'[]'::jsonb),
    'seasons', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at desc) from public.seasons s),'[]'::jsonb)
  ) into r;
  return r;
end $$;

create or replace function public.admin_update_catalog(
  p_kind text, p_id text, p_values jsonb, p_pin text
) returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; begin
  if p_kind not in ('shop','task','season') or jsonb_typeof(p_values) <> 'object' then
    return jsonb_build_object('ok',false,'error','invalid_catalog');
  end if;
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  if p_kind = 'shop' then
    update public.marketplace_items set
      name = coalesce(nullif(left(p_values->>'name',60),''),name),
      description = coalesce(nullif(left(p_values->>'description',180),''),description),
      price = case when (p_values->>'price') ~ '^[0-9]+$' then greatest((p_values->>'price')::bigint,1) else price end,
      active = coalesce((p_values->>'active')::boolean,active), updated_at=clock_timestamp()
    where id=p_id::uuid;
  elsif p_kind = 'task' then
    update public.daily_tasks set
      name = coalesce(nullif(left(p_values->>'name',80),''),name),
      description = coalesce(nullif(left(p_values->>'description',180),''),description),
      reward = case when (p_values->>'reward') ~ '^[0-9]+$' then greatest((p_values->>'reward')::bigint,1) else reward end,
      target_count = case when (p_values->>'target_count') ~ '^[0-9]+$' then greatest((p_values->>'target_count')::integer,1) else target_count end,
      active = coalesce((p_values->>'active')::boolean,active)
    where task_key=p_id;
  else
    update public.seasons set
      name = coalesce(nullif(left(p_values->>'name',60),''),name),
      reward_first = case when (p_values->>'reward_first') ~ '^[0-9]+$' then greatest((p_values->>'reward_first')::bigint,0) else reward_first end,
      reward_second = case when (p_values->>'reward_second') ~ '^[0-9]+$' then greatest((p_values->>'reward_second')::bigint,0) else reward_second end,
      reward_third = case when (p_values->>'reward_third') ~ '^[0-9]+$' then greatest((p_values->>'reward_third')::bigint,0) else reward_third end
    where id=p_id::uuid;
  end if;
  return jsonb_build_object('ok',true);
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','invalid_catalog_id');
end $$;

create or replace function public.admin_update_control(
  p_key text, p_value jsonb, p_pin text
) returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); pin_status text; begin
  if p_key not in ('maintenance','announcement','health') or jsonb_typeof(p_value) <> 'object' then
    return jsonb_build_object('ok',false,'error','invalid_control');
  end if;
  pin_status := private.check_admin_pin(actor,p_pin);
  if pin_status <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||pin_status); end if;
  insert into private.admin_control_settings(key,value,updated_by,updated_at)
    values(p_key,p_value,actor,clock_timestamp())
    on conflict(key) do update set value=excluded.value,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  return jsonb_build_object('ok',true,'key',p_key,'value',p_value);
end $$;

create or replace function public.admin_run_health_check(p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; result jsonb; begin
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  result := jsonb_build_object(
    'database', jsonb_build_object('status','ok','checked_at',clock_timestamp()),
    'wallets', jsonb_build_object('status',case when exists(select 1 from public.wallets) then 'ok' else 'warning' end),
    'transactions', jsonb_build_object('status',case when exists(select 1 from public.transactions) then 'ok' else 'warning' end),
    'catalog', jsonb_build_object('status',case when exists(select 1 from public.marketplace_items where active) then 'ok' else 'warning' end)
  );
  update private.admin_control_settings set value=jsonb_build_object('last_check_at',clock_timestamp(),'status','ok','checks',result),updated_by=actor,updated_at=clock_timestamp() where key='health';
  return jsonb_build_object('ok',true,'checks',result);
end $$;

create or replace function public.admin_create_class(p_name text,p_school_year text,p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; c public.admin_classes%rowtype; begin
  if char_length(trim(coalesce(p_name,''))) not between 2 and 80 then return jsonb_build_object('ok',false,'error','invalid_class'); end if;
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  insert into public.admin_classes(name,school_year,created_by) values(trim(p_name),coalesce(trim(p_school_year),''),actor) returning * into c;
  return jsonb_build_object('ok',true,'class',to_jsonb(c));
end $$;

create or replace function public.admin_update_case(p_case_id uuid,p_status text,p_priority text,p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; begin
  if p_status not in ('open','in_progress','waiting','closed') or p_priority not in ('low','normal','high','urgent') then return jsonb_build_object('ok',false,'error','invalid_case'); end if;
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  update public.support_cases set status=p_status,priority=p_priority,assigned_to=actor,updated_at=clock_timestamp() where id=p_case_id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.request_data_export(p_format text default 'json')
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare u uuid := private.require_active_user(); r public.admin_export_requests%rowtype; begin
  if p_format not in ('json','csv') then raise exception 'invalid_export_format'; end if;
  insert into public.admin_export_requests(requester_id,format) values(u,p_format) returning * into r;
  return jsonb_build_object('ok',true,'request',to_jsonb(r));
end $$;
create or replace function public.create_privacy_request(p_type text,p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare u uuid := private.require_active_user(); r public.privacy_requests%rowtype; begin
  if p_type not in ('access','deletion','correction') then raise exception 'invalid_privacy_request'; end if;
  insert into public.privacy_requests(requester_id,request_type,note) values(u,p_type,left(p_note,1000)) returning * into r;
  return jsonb_build_object('ok',true,'request',to_jsonb(r));
end $$;

revoke all on function public.get_public_admin_notice() from public, anon; grant execute on function public.get_public_admin_notice() to authenticated;
revoke all on function public.admin_list_control_center() from public, anon; grant execute on function public.admin_list_control_center() to authenticated;
revoke all on function public.admin_update_catalog(text,text,jsonb,text) from public, anon; grant execute on function public.admin_update_catalog(text,text,jsonb,text) to authenticated;
revoke all on function public.admin_update_control(text,jsonb,text) from public, anon; grant execute on function public.admin_update_control(text,jsonb,text) to authenticated;
revoke all on function public.admin_run_health_check(text) from public, anon; grant execute on function public.admin_run_health_check(text) to authenticated;
revoke all on function public.admin_create_class(text,text,text) from public, anon; grant execute on function public.admin_create_class(text,text,text) to authenticated;
revoke all on function public.admin_update_case(uuid,text,text,text) from public, anon; grant execute on function public.admin_update_case(uuid,text,text,text) to authenticated;
revoke all on function public.request_data_export(text) from public, anon; grant execute on function public.request_data_export(text) to authenticated;
revoke all on function public.create_privacy_request(text,text) from public, anon; grant execute on function public.create_privacy_request(text,text) to authenticated;
