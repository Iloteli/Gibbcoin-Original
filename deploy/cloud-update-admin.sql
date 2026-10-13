-- Admin-Bereich auf der Chain-Seite.
-- Die Chain-Seite (Ilja, mit Server-Code angemeldet) ruft die bestehenden Admin-Funktionen mit dem
-- Chain-Schlüssel auf – ausgeführt als Iljas Owner-Konto. Geschützte Aktionen verlangen weiterhin
-- den Admin-PIN (p_pin), so wie bisher im Admin-Panel der Hauptseite.

create or replace function private.node_owner_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select u.id from auth.users u where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com' limit 1; $$;
revoke all on function private.node_owner_id() from public, anon, authenticated;

-- Als Owner auftreten (nur innerhalb der laufenden Anfrage)
create or replace function private.node_act_as_owner()
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid := private.node_owner_id();
begin
  if v_owner is null then raise exception 'owner_not_found'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', v_owner::text, true);
  perform pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  perform pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_owner, 'role', 'authenticated', 'aal', 'aal2', 'amr', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('method', 'totp')))::text, true);
  return v_owner;
end;
$$;
revoke all on function private.node_act_as_owner() from public, anon, authenticated;

-- Allgemeiner Aufruf erlaubter Admin-Funktionen
create or replace function public.node_owner_call(p_key text, p_fn text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_args text;
  v_rows jsonb;
  v_table boolean;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_fn is null or p_fn not in (
    'admin_list_users', 'admin_pin_status', 'admin_coin_stats', 'admin_list_visual_roles', 'admin_list_account_locks',
    'admin_verify_pin', 'admin_set_pin', 'owner_reset_admin_pin', 'admin_set_role', 'admin_set_visual_role', 'admin_reset_coin_stats',
    'admin_list_operations', 'admin_list_control_center_page', 'admin_list_transfer_approvals', 'admin_update_operation',
    'admin_update_control', 'admin_create_class', 'admin_update_case', 'admin_update_catalog', 'admin_run_health_check',
    'admin_set_transfer_threshold', 'get_game_center_state', 'get_dino_admin_state', 'get_global_game_limits',
    'admin_set_game_enabled', 'admin_set_dino_game_settings', 'admin_set_global_game_limits',
    'admin_list_audit_logs', 'admin_visitor_stats', 'admin_add_class_member', 'admin_remove_class_member'
  ) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'function_not_allowed');
  end if;
  if p_args is not null and pg_catalog.jsonb_typeof(p_args) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_args');
  end if;

  perform private.node_act_as_owner();
  select pg_catalog.string_agg(pg_catalog.format('%I => %L', e.key, e.value), ', ')
  into v_args
  from pg_catalog.jsonb_each_text(coalesce(p_args, '{}'::jsonb)) e
  where e.key ~ '^p_[a-z_]+$';

  begin
    execute pg_catalog.format(
      'select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r)), ''[]''::jsonb) from public.%I(%s) r',
      p_fn, coalesce(v_args, '')
    ) into v_rows;
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  -- Tabellen-Funktion (mehrere Zeilen/Spalten) oder einfacher Rückgabewert?
  select bool_or(p.proretset or t.typtype = 'c' or p.prorettype = 'pg_catalog.record'::pg_catalog.regtype)
  into v_table
  from pg_catalog.pg_proc p join pg_catalog.pg_type t on t.oid = p.prorettype
  where p.pronamespace = 'public'::pg_catalog.regnamespace and p.proname = p_fn;
  return pg_catalog.jsonb_build_object('ok', true, 'fn', p_fn, 'table', coalesce(v_table, true), 'rows', v_rows);
end;
$$;
revoke all on function public.node_owner_call(text, text, jsonb) from public;
grant execute on function public.node_owner_call(text, text, jsonb) to anon, authenticated, service_role;

-- Bannen / Entbannen (Login und Wallet). Ilja selbst kann nicht gebannt werden.
create or replace function public.node_set_account_status(p_key text, p_user uuid, p_status text, p_minutes integer, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_until timestamptz;
  v_reason text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or p_status not in ('active', 'locked') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  if p_minutes is not null and p_minutes not in (60, 1440, 10080) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_lock_duration'); end if;
  v_owner := private.node_act_as_owner();
  if p_user = v_owner then return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_lock_own_account'); end if;
  if p_status = 'locked' and private.is_protected_account(p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected');
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found'); end if;
  v_until := case when p_status = 'locked' and p_minutes is not null then pg_catalog.now() + pg_catalog.make_interval(mins => p_minutes) end;
  v_reason := case when p_status = 'locked'
    then coalesce(nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_reason, '')), 120), ''), 'Konto auf der Chain-Seite gebannt')
    else 'Bann auf der Chain-Seite aufgehoben' end;
  begin
    update auth.users set banned_until = case when p_status = 'locked' then coalesce(v_until, pg_catalog.now() + interval '100 years') end
    where id = p_user;
    perform public.admin_apply_wallet_status_v2(v_owner, p_user, p_status, v_reason, v_until);
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'status', p_status, 'locked_until', v_until);
end;
$$;
revoke all on function public.node_set_account_status(text, uuid, text, integer, text) from public;
grant execute on function public.node_set_account_status(text, uuid, text, integer, text) to anon, authenticated, service_role;

-- Konto endgültig löschen (mit Admin-PIN). Geschützte Konten (Ilja) bleiben.
create or replace function public.node_delete_account(p_key text, p_user uuid, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_auth jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_owner := private.node_act_as_owner();
  if p_user is null or p_user = v_owner or private.is_protected_account(p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected');
  end if;
  v_auth := public.admin_authorize_account_deletion(v_owner, p_user, p_pin);
  if not coalesce((v_auth ->> 'ok')::boolean, false) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', coalesce(v_auth ->> 'error', 'account_delete_not_authorized'));
  end if;
  begin
    delete from auth.users where id = p_user;
    perform public.admin_finalize_account_deletion(v_owner, p_user);
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'display_name', v_auth ->> 'display_name');
end;
$$;
revoke all on function public.node_delete_account(text, uuid, text) from public;
grant execute on function public.node_delete_account(text, uuid, text) to anon, authenticated, service_role;

-- Passwort-Reset: liefert die E-Mail-Adresse (die Chain-Seite löst den Versand bei Supabase Auth aus)
create or replace function public.node_password_reset(p_key text, p_user uuid, p_sent boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_auth jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_owner := private.node_act_as_owner();
  if coalesce(p_sent, false) then
    begin
      perform public.admin_record_password_reset(v_owner, p_user);
    exception when others then null; -- nur Protokoll
    end;
    return pg_catalog.jsonb_build_object('ok', true);
  end if;
  v_auth := public.admin_authorize_password_reset(v_owner, p_user);
  if not coalesce((v_auth ->> 'ok')::boolean, false) or (v_auth ->> 'email') is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', coalesce(v_auth ->> 'error', 'password_reset_not_authorized'));
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'email', v_auth ->> 'email', 'display_name', v_auth ->> 'display_name');
end;
$$;
revoke all on function public.node_password_reset(text, uuid, boolean) from public;
grant execute on function public.node_password_reset(text, uuid, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
