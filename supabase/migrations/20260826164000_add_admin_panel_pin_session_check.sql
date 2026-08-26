-- Verify the personal Admin PIN once when the Admin panel is opened.
-- The browser keeps the entered PIN only in component memory and still sends it
-- to every protected mutation, so all existing server-side checks remain active.

create or replace function public.admin_verify_pin(p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.admin_verify_pin(text) from public, anon;
grant execute on function public.admin_verify_pin(text) to authenticated;

comment on function public.admin_verify_pin(text) is
  'Verifies the current Admin PIN when entering the Admin panel; no session or plaintext PIN is persisted server-side.';
