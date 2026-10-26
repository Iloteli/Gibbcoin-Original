-- Eigene Supabase: Admin-Protokoll auch mit Zusatzangaben (metadata) schreiben.
-- Viele Admin-Funktionen (Konto löschen, bannen, Passwort-Reset, Coins …) rufen
-- private.write_admin_audit mit 7 Angaben auf; nachgebaut war nur die Variante mit 6.
-- Folge: "function private.write_admin_audit(uuid, uuid, unknown, jsonb, jsonb, text, jsonb) does not exist".
alter table public.admin_audit_logs add column if not exists metadata jsonb;

create or replace function private.write_admin_audit(
  p_admin_user_id uuid,
  p_target_user_id uuid,
  p_action text,
  p_old_value jsonb,
  p_new_value jsonb,
  p_reason text,
  p_metadata jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.admin_audit_logs (admin_user_id, target_user_id, action, old_value, new_value, reason, metadata)
  values (p_admin_user_id, p_target_user_id, p_action, p_old_value, p_new_value, p_reason, p_metadata)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.write_admin_audit(uuid, uuid, text, jsonb, jsonb, text, jsonb) from public, anon, authenticated;
