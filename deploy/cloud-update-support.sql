-- GIBB Coin: Support (Owner bearbeiten Anliegen, gemeinsamer Support-Bereich). Kann mehrfach ausgeführt werden.

-- ===== 20261013230000_owner_support_only.sql =====
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

-- ===== 20261013250000_support_unified.sql =====
-- Ein gemeinsamer Support-Bereich: Tickets (support_cases) und gemeldete Transaktionen (abuse_reports).
-- Owner sehen und bearbeiten beides an einem Ort.

create or replace function public.support_list_all()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_support_owner();
  return coalesce((
    select pg_catalog.jsonb_agg(x.item order by (x.item ->> 'done')::boolean, x.updated_at desc)
    from (
      select c.updated_at, pg_catalog.jsonb_build_object(
        'kind', 'ticket', 'id', c.id, 'subject', c.subject, 'body', c.body, 'status', c.status, 'priority', c.priority,
        'created_at', c.created_at, 'updated_at', c.updated_at, 'done', c.status = 'closed',
        'requester', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer'),
        'assigned', coalesce(nullif(a.username, ''), a.display_name)
      ) as item
      from (select * from public.support_cases order by updated_at desc limit 200) c
      left join public.profiles p on p.id = c.requester_id
      left join public.profiles a on a.id = c.assigned_to
      union all
      select r.updated_at, pg_catalog.jsonb_build_object(
        'kind', 'report', 'id', r.id,
        'subject', 'Gemeldete Transaktion · ' || case r.category
          when 'suspicious_transfer' then 'Verdächtige Überweisung' when 'wrong_recipient' then 'Falscher Empfänger'
          when 'harassment' then 'Belästigung oder Druck' else 'Anderer Grund' end,
        'body', r.description, 'status', r.status, 'priority', 'normal',
        'created_at', r.created_at, 'updated_at', r.updated_at, 'done', r.status in ('resolved', 'dismissed'),
        'requester', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer'),
        'transaction', case when t.id is null then 'Transaktion nicht mehr verfügbar'
          else t.sender_label || ' → ' || t.receiver_label || ' · ' || t.amount || ' GIBB' end,
        'note', r.resolution_note
      )
      from (select * from public.abuse_reports order by updated_at desc limit 200) r
      left join public.profiles p on p.id = r.reporter_user_id
      left join public.transactions t on t.id = r.transaction_id
    ) x
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.support_list_all() from public, anon;
grant execute on function public.support_list_all() to authenticated;

-- Gemeldete Transaktion bearbeiten (Owner)
create or replace function public.support_update_report(p_report_id uuid, p_status text, p_reply text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_support_owner();
  v_reporter uuid;
  v_reply text := nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_reply, '')), 500), '');
begin
  if p_status not in ('open', 'reviewing', 'resolved', 'dismissed') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  update public.abuse_reports set status = p_status, resolution_note = coalesce(v_reply, resolution_note), reviewed_by = v_me, updated_at = pg_catalog.now()
  where id = p_report_id returning reporter_user_id into v_reporter;
  if v_reporter is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  begin
    insert into public.notifications (user_id, kind, title, message)
    values (v_reporter, 'report_status', 'Meldung aktualisiert',
      coalesce(v_reply, case p_status when 'reviewing' then 'Deine Meldung wird jetzt geprüft.' when 'resolved' then 'Deine Meldung wurde geprüft und abgeschlossen.' when 'dismissed' then 'Deine Meldung wurde geprüft und geschlossen.' else 'Deine Meldung ist wieder offen.' end));
  exception when others then null;
  end;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.support_update_report(uuid, text, text) from public, anon;
grant execute on function public.support_update_report(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
