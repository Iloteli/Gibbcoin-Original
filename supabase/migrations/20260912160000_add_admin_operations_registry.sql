-- Central, private registry for the admin capabilities that are not account,
-- wallet, game-limit, report or audit-log controls.  The registry deliberately
-- stores configuration/status only; integrations must be wired separately.
create table if not exists private.admin_operations (
  operation_key text primary key check (operation_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  label text not null,
  description text not null,
  category text not null check (category in ('system','communication','data','moderation','economy','games')),
  status text not null default 'unavailable' check (status in ('enabled','disabled','configured','unavailable')),
  configuration jsonb not null default '{}'::jsonb check (jsonb_typeof(configuration) = 'object'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table private.admin_operations enable row level security;
alter table private.admin_operations force row level security;
revoke all on table private.admin_operations from public, anon, authenticated;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;
alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED',
      'STATS_RESET', 'ADMIN_OPERATION_CHANGED'
    )
  );

insert into private.admin_operations (operation_key, label, description, category)
values
 ('maintenance_mode','Wartungsmodus','Zugriff für Benutzer zeitweise pausieren.','system'),
 ('registration_policy','Registrierung','Neue Registrierungen und Einladungen steuern.','system'),
 ('login_policy','Anmelderichtlinie','Anmeldeversuche und Sitzungsdauer konfigurieren.','system'),
 ('password_policy','Passwortregeln','Mindestanforderungen für Passwörter dokumentieren.','system'),
 ('session_revocation','Sitzungen','Sitzungen eines Kontos serverseitig widerrufen.','system'),
 ('feature_flags','Funktionsschalter','Nicht-kritische Funktionen kontrolliert aktivieren.','system'),
 ('announcement_banner','Hinweisbanner','Einen globalen, zeitlich begrenzten Hinweis anzeigen.','communication'),
 ('email_delivery','E-Mail-Versand','E-Mail-Anbieter und Versandstatus verwalten.','communication'),
 ('push_delivery','Push-Versand','Push-Anbieter und Versandstatus verwalten.','communication'),
 ('notification_templates','Benachrichtigungsvorlagen','Vorlagen für Systemmeldungen verwalten.','communication'),
 ('backup_status','Backups','Status des externen Backup-Dienstes dokumentieren.','data'),
 ('restore_status','Wiederherstellung','Wiederherstellung nur als geprüften externen Vorgang markieren.','data'),
 ('data_export','Datenexport','Exportanfragen sicher erfassen und nachverfolgen.','data'),
 ('retention_policy','Aufbewahrung','Aufbewahrungsfristen und Löschläufe konfigurieren.','data'),
 ('privacy_requests','Datenschutzanfragen','Auskunfts- und Löschanfragen nachverfolgen.','data'),
 ('health_checks','Systemstatus','Abhängigkeiten und Erreichbarkeit prüfen.','system'),
 ('scheduled_jobs','Geplante Aufgaben','Geplante Wartungsaufgaben überwachen.','system'),
 ('api_integrations','API-Integrationen','Externe Integrationen mit Status und Endpunkt verwalten.','system'),
 ('webhook_delivery','Webhooks','Webhook-Zustellung und Wiederholungen überwachen.','system'),
 ('domain_allowlist','Domain-Freigaben','Erlaubte E-Mail-Domains konfigurieren.','system'),
 ('moderation_queue','Moderationswarteschlange','Gemeldete Inhalte zur Prüfung priorisieren.','moderation'),
 ('report_workflow','Meldungsworkflow','Zuständigkeiten und Fristen für Meldungen konfigurieren.','moderation'),
 ('user_impersonation','Supportzugriff','Supportzugriff nur als nicht aktivierte Konfiguration dokumentieren.','moderation'),
 ('economy_limits','Ökonomiegrenzen','Zusätzliche globale Wirtschaftsgrenzen konfigurieren.','economy'),
 ('refund_workflow','Erstattungen','Erstattungsanfragen kontrolliert erfassen.','economy'),
 ('purchase_reconciliation','Zahlungsabgleich','Zahlungsabgleich als externen Status überwachen.','economy'),
 ('leaderboard_moderation','Ranglistenmoderation','Auffällige Ranglisten-Einträge markieren.','games'),
 ('game_catalog','Spielekatalog','Spiele sichtbar oder vorübergehend deaktiviert konfigurieren.','games'),
 ('game_maintenance','Spielwartung','Spielwartungsfenster und Hinweise verwalten.','games'),
 ('fairness_monitoring','Fairness-Prüfung','Prüfstatus der serverseitigen Spielintegrität dokumentieren.','games')
on conflict (operation_key) do update set
 label = excluded.label, description = excluded.description, category = excluded.category;

create or replace function public.admin_list_operations()
returns table (
 operation_key text, label text, description text, category text,
 status text, configuration jsonb, updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.require_admin();
  return query
    select o.operation_key, o.label, o.description, o.category,
           o.status, o.configuration, o.updated_at
    from private.admin_operations o
    order by o.category, o.label;
end;
$$;

create or replace function public.admin_update_operation(
  p_operation_key text,
  p_status text,
  p_configuration jsonb default '{}'::jsonb,
  p_pin text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_actor uuid := private.require_admin();
  v_pin_status text;
  v_operation private.admin_operations%rowtype;
begin
  if p_operation_key is null or p_status not in ('enabled','disabled','configured','unavailable')
     or p_configuration is null or pg_catalog.jsonb_typeof(p_configuration) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_operation');
  end if;
  if pg_catalog.char_length(p_operation_key) > 64 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_operation');
  end if;
  v_pin_status := private.check_admin_pin(v_actor, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;
  select * into v_operation from private.admin_operations
    where operation_key = p_operation_key for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'operation_not_found');
  end if;
  update private.admin_operations
    set status = p_status, configuration = p_configuration,
        updated_by = v_actor, updated_at = pg_catalog.clock_timestamp()
    where operation_key = p_operation_key;
  if v_operation.status is distinct from p_status
     or v_operation.configuration is distinct from p_configuration then
    perform private.write_admin_audit(
      v_actor, null, 'ADMIN_OPERATION_CHANGED',
      pg_catalog.jsonb_build_object('operation_key', p_operation_key,
        'status', v_operation.status, 'configuration', v_operation.configuration),
      pg_catalog.jsonb_build_object('operation_key', p_operation_key,
        'status', p_status, 'configuration', p_configuration),
      'Admin-Operation geändert'
    );
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'operation_key', p_operation_key,
    'status', p_status, 'configuration', p_configuration);
end;
$$;

revoke all on function public.admin_list_operations() from public, anon;
grant execute on function public.admin_list_operations() to authenticated;
revoke all on function public.admin_update_operation(text, text, jsonb, text) from public, anon;
grant execute on function public.admin_update_operation(text, text, jsonb, text) to authenticated;
