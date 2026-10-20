-- Chain-Seite: Bannen mit frei wählbarer Dauer und Konten überall abmelden.
-- Abmelden = alle Sitzungen der Hauptseite widerrufen (auth.sessions / Refresh-Tokens) und den Zeitpunkt merken;
-- die Hauptseite fragt ihn regelmässig ab (my_session_revoked_at) und meldet sich dann sofort ab.

create table if not exists private.session_revocations (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  revoked_at timestamptz not null default pg_catalog.now()
);
revoke all on table private.session_revocations from public, anon, authenticated;

create or replace function private.revoke_user_sessions(p_user uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  insert into private.session_revocations (user_id, revoked_at) values (p_user, pg_catalog.now())
  on conflict (user_id) do update set revoked_at = excluded.revoked_at;
  begin
    delete from auth.refresh_tokens where user_id = p_user::text;
  exception when others then null; -- ältere/abweichende Auth-Tabellen
  end;
  begin
    delete from auth.sessions where user_id = p_user;
  exception when others then null;
  end;
end;
$$;
revoke all on function private.revoke_user_sessions(uuid) from public, anon, authenticated;

-- Hauptseite: wurde meine Anmeldung widerrufen? (Zeitpunkt oder null)
create or replace function public.my_session_revoked_at()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select r.revoked_at from private.session_revocations r where r.user_id = auth.uid();
$$;
revoke all on function public.my_session_revoked_at() from public, anon;
grant execute on function public.my_session_revoked_at() to authenticated;

-- Chain-Seite: Konto überall abmelden (geschützte Konten wie Ilja ausgenommen)
create or replace function public.node_logout_user(p_key text, p_user uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or not exists (select 1 from public.profiles p where p.id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found'); end if;
  if private.is_protected_account(p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected'); end if;
  perform private.revoke_user_sessions(p_user);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_logout_user(text, uuid) from public;
grant execute on function public.node_logout_user(text, uuid) to anon, authenticated, service_role;

-- Bannen: Dauer frei wählbar (1 Minute bis 5 Jahre, null = dauerhaft); Bann meldet das Konto auch sofort ab
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
  if p_minutes is not null and (p_minutes < 1 or p_minutes > 2628000) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_lock_duration'); end if;
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
    if p_status = 'locked' then perform private.revoke_user_sessions(p_user); end if;
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'status', p_status, 'locked_until', v_until);
end;
$$;
revoke all on function public.node_set_account_status(text, uuid, text, integer, text) from public;
grant execute on function public.node_set_account_status(text, uuid, text, integer, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
