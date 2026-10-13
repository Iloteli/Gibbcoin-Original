-- Owner-Rang = nur Support-Tickets bearbeiten.
-- * Alle Admin-Funktionen (private.require_admin) gehen nur noch für Ilja – praktisch nur über die
--   Chain-Seite (node_owner_call). Andere Owner und Admins haben keine Admin-Rechte mehr.
-- * Owner (super_admin) können auf der Hauptseite alle Support-Tickets sehen, beantworten und den
--   Status/die Priorität ändern.

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if exists (
    select 1 from auth.mfa_factors f
    where f.user_id = v_user_id and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
  select p.role, w.status into v_role, v_wallet_status
  from public.profiles p join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;
  if v_role not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  -- Admin-Funktionen nur noch für den Haupt-Owner (Ilja, über die Chain-Seite)
  if not private.is_ilja(v_user_id) then raise exception 'admin_required'; end if;
  if v_wallet_status <> 'active' then raise exception 'account_locked'; end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_admin() from public, anon, authenticated;

create or replace function private.require_support_owner()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if not exists (
    select 1 from public.profiles p join public.wallets w on w.user_id = p.id
    where p.id = v_user_id and p.role = 'super_admin' and w.status = 'active'
  ) then
    raise exception 'owner_required';
  end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_support_owner() from public, anon, authenticated;

-- Alle Tickets (neueste und offene zuerst)
create or replace function public.support_list_cases(p_status text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_support_owner();
  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', c.id, 'subject', c.subject, 'body', c.body, 'status', c.status, 'priority', c.priority,
      'created_at', c.created_at, 'updated_at', c.updated_at,
      'requester', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer'),
      'assigned', coalesce(nullif(a.username, ''), a.display_name)
    ) order by (c.status = 'closed'), c.updated_at desc)
    from (select * from public.support_cases where p_status is null or status = p_status order by updated_at desc limit 200) c
    left join public.profiles p on p.id = c.requester_id
    left join public.profiles a on a.id = c.assigned_to
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.support_list_cases(text) from public, anon;
grant execute on function public.support_list_cases(text) to authenticated;

-- Ticket bearbeiten und optional antworten (Antwort kommt als Mitteilung bei der Person an)
create or replace function public.support_update_case(p_case_id uuid, p_status text, p_priority text, p_reply text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_support_owner();
  v_case public.support_cases%rowtype;
  v_reply text := pg_catalog.left(pg_catalog.btrim(coalesce(p_reply, '')), 1000);
begin
  if p_status not in ('open', 'in_progress', 'waiting', 'closed') or p_priority not in ('low', 'normal', 'high', 'urgent') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  update public.support_cases set status = p_status, priority = p_priority, assigned_to = v_me, updated_at = pg_catalog.now()
  where id = p_case_id returning * into v_case;
  if v_case.id is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_reply <> '' or p_status = 'closed' then
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (v_case.requester_id, 'support',
              case when p_status = 'closed' then 'Support-Ticket abgeschlossen' else 'Antwort vom Support' end,
              '„' || v_case.subject || '“: ' || coalesce(nullif(v_reply, ''), 'Dein Ticket wurde abgeschlossen.'));
    exception when others then null;
    end;
  end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.support_update_case(uuid, text, text, text) from public, anon;
grant execute on function public.support_update_case(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';
