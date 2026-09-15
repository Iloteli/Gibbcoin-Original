-- Backend hardening for admin mutations, seasons, and payment configuration.
-- All changes are additive and preserve existing rows.

create or replace function private.ensure_current_season()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz := pg_catalog.date_trunc('month', clock_timestamp());
  v_end timestamptz := v_start + interval '1 month';
  v_slug text := 'campus-' || pg_catalog.to_char(v_start, 'YYYY-MM');
  v_id uuid;
begin
  perform pg_catalog.pg_advisory_xact_lock(938242);
  insert into public.seasons (slug, name, starts_at, ends_at)
  values (
    v_slug,
    'Campus Saison ' || pg_catalog.to_char(v_start, 'MM/YYYY'),
    v_start,
    v_end
  )
  on conflict (slug) do nothing;

  select s.id into v_id
  from public.seasons s
  where s.slug = v_slug;
  if v_id is null then raise exception 'season_creation_failed'; end if;
  return v_id;
end;
$$;

revoke all on function private.ensure_current_season() from public, anon, authenticated;

-- Prevent stale or guessed identifiers from being reported as successful admin
-- changes. The existing validation and PIN checks remain unchanged.
create or replace function public.admin_update_catalog(
  p_kind text, p_id text, p_values jsonb, p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_admin();
  pin_status text;
  changed integer;
  target_id uuid;
begin
  if p_kind not in ('shop', 'task', 'season')
     or jsonb_typeof(p_values) <> 'object'
  then
    return jsonb_build_object('ok', false, 'error', 'invalid_catalog');
  end if;
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then
    return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status);
  end if;

  if p_kind = 'shop' then
    begin
      target_id := p_id::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok', false, 'error', 'invalid_catalog_id');
    end;
    update public.marketplace_items
    set name = coalesce(nullif(left(p_values->>'name', 60), ''), name),
        description = coalesce(nullif(left(p_values->>'description', 180), ''), description),
        price = case when (p_values->>'price') ~ '^[0-9]+$'
          then greatest((p_values->>'price')::bigint, 1) else price end,
        active = coalesce((p_values->>'active')::boolean, active),
        updated_at = clock_timestamp()
    where id = target_id;
  elsif p_kind = 'task' then
    update public.daily_tasks
    set name = coalesce(nullif(left(p_values->>'name', 80), ''), name),
        description = coalesce(nullif(left(p_values->>'description', 180), ''), description),
        reward = case when (p_values->>'reward') ~ '^[0-9]+$'
          then greatest((p_values->>'reward')::bigint, 1) else reward end,
        target_count = case when (p_values->>'target_count') ~ '^[0-9]+$'
          then greatest((p_values->>'target_count')::integer, 1) else target_count end,
        active = coalesce((p_values->>'active')::boolean, active)
    where task_key = p_id;
  else
    begin
      target_id := p_id::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok', false, 'error', 'invalid_catalog_id');
    end;
    update public.seasons
    set name = coalesce(nullif(left(p_values->>'name', 60), ''), name),
        reward_first = case when (p_values->>'reward_first') ~ '^[0-9]+$'
          then greatest((p_values->>'reward_first')::bigint, 0) else reward_first end,
        reward_second = case when (p_values->>'reward_second') ~ '^[0-9]+$'
          then greatest((p_values->>'reward_second')::bigint, 0) else reward_second end,
        reward_third = case when (p_values->>'reward_third') ~ '^[0-9]+$'
          then greatest((p_values->>'reward_third')::bigint, 0) else reward_third end
    where id = target_id;
  end if;

  get diagnostics changed = row_count;
  if changed <> 1 then
    return jsonb_build_object('ok', false, 'error', 'catalog_not_found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_update_case(
  p_case_id uuid, p_status text, p_priority text, p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_admin();
  pin_status text;
  changed integer;
begin
  if p_status not in ('open', 'in_progress', 'waiting', 'closed')
     or p_priority not in ('low', 'normal', 'high', 'urgent')
  then
    return jsonb_build_object('ok', false, 'error', 'invalid_case');
  end if;
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then
    return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status);
  end if;
  update public.support_cases
  set status = p_status, priority = p_priority,
      assigned_to = actor, updated_at = clock_timestamp()
  where id = p_case_id;
  get diagnostics changed = row_count;
  if changed <> 1 then
    return jsonb_build_object('ok', false, 'error', 'case_not_found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Keep every public admin RPC unavailable to browser roles unless an earlier
-- migration explicitly grants authenticated execution. Service-role-only
-- delegation functions remain service-role-only.
do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'admin\_%' escape '\'
  loop
    execute format('revoke all on function %s from public, anon', fn.oid::regprocedure);
  end loop;
end;
$$;

revoke all on function public.admin_update_catalog(text, text, jsonb, text) from public, anon;
grant execute on function public.admin_update_catalog(text, text, jsonb, text) to authenticated;
revoke all on function public.admin_update_case(uuid, text, text, text) from public, anon;
grant execute on function public.admin_update_case(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
