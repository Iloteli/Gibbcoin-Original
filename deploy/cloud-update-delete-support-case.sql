-- Support-Fälle auf der Chain-Seite löschen (Admin-PIN nötig, wie beim Ändern).
create or replace function public.node_delete_support_case(p_key text, p_case uuid, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_pin text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_owner := private.node_act_as_owner();
  v_pin := private.check_admin_pin(v_owner, p_pin);
  if v_pin <> 'ok' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin); end if;
  delete from public.support_cases where id = p_case;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'case_not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_delete_support_case(text, uuid, text) from public;
grant execute on function public.node_delete_support_case(text, uuid, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
