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
