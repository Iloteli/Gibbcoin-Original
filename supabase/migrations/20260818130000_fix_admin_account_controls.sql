create extension if not exists pg_net with schema extensions;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED'
    )
  );

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
  v_old_role text;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Rollenänderung'
  );
begin
  v_admin_user_id := private.require_admin();
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_admin_user_id then raise exception 'cannot_change_own_role'; end if;
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
    v_admin_user_id,
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
    case when p_role = 'admin' then 'Du besitzt jetzt Administratorrechte.' else 'Deine Administratorrechte wurden entfernt.' end
  );
  return p_role;
end;
$$;

create or replace function public.admin_set_wallet_status(
  p_target_user_id uuid,
  p_status text,
  p_reason text default 'Administrative Sicherheitsmassnahme'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_admin_role text;
  v_target_role text;
  v_wallet public.wallets%rowtype;
  v_reason text := coalesce(
    nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''),
    'Administrative Sicherheitsmassnahme'
  );
  v_request_headers jsonb := coalesce(
    nullif(pg_catalog.current_setting('request.headers', true), '')::jsonb,
    '{}'::jsonb
  );
  v_edge_headers jsonb;
  v_authorization text;
  v_api_key text;
  v_request_id bigint;
begin
  v_admin_user_id := private.require_admin();
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_status not in ('active', 'locked') then raise exception 'invalid_wallet_status'; end if;
  if p_target_user_id = v_admin_user_id and p_status = 'locked' then raise exception 'cannot_lock_own_account'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;
  select p.role into v_target_role from public.profiles p where p.id = p_target_user_id;
  if v_target_role is null then raise exception 'user_not_found'; end if;
  if v_target_role = 'super_admin' then raise exception 'cannot_modify_super_admin'; end if;
  if v_admin_role = 'admin' and v_target_role = 'admin' then raise exception 'cannot_modify_peer_admin'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = p_target_user_id
  for update;

  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  v_authorization := v_request_headers ->> 'authorization';
  v_api_key := v_request_headers ->> 'apikey';
  if v_authorization is null or v_authorization = '' then
    raise exception 'authentication_header_required';
  end if;

  v_edge_headers := pg_catalog.jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', v_authorization
  );
  if v_api_key is not null and v_api_key <> '' then
    v_edge_headers := v_edge_headers || pg_catalog.jsonb_build_object('apikey', v_api_key);
  end if;

  select net.http_post(
    url := 'https://laduzigqgvvnrqcgfgab.supabase.co/functions/v1/admin-account-status',
    headers := v_edge_headers,
    body := pg_catalog.jsonb_build_object(
      'target_user_id', p_target_user_id,
      'status', p_status
    ),
    timeout_milliseconds := 10000
  ) into v_request_id;

  if v_request_id is null then raise exception 'account_status_dispatch_failed'; end if;

  if v_wallet.status <> p_status then
    update public.wallets set status = p_status where id = v_wallet.id;
    perform private.write_admin_audit(
      v_admin_user_id,
      p_target_user_id,
      case when p_status = 'locked' then 'ACCOUNT_LOCKED' else 'ACCOUNT_UNLOCKED' end,
      pg_catalog.jsonb_build_object('status', v_wallet.status),
      pg_catalog.jsonb_build_object('status', p_status),
      v_reason,
      pg_catalog.jsonb_build_object('auth_sync_request_id', v_request_id)
    );
    insert into public.notifications (user_id, kind, title, message)
    values (
      p_target_user_id,
      'account_status',
      case when p_status = 'locked' then 'Konto gesperrt' else 'Konto freigeschaltet' end,
      case when p_status = 'locked' then 'Ein Admin hat dein Konto gesperrt: ' else 'Dein Konto wurde freigeschaltet: ' end || v_reason
    );
  end if;

  return p_status;
end;
$$;

revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;

revoke all on function public.admin_set_wallet_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_wallet_status(uuid, text, text) to authenticated;
