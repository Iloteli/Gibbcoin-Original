-- Chain-Seite: jede einzelne Banküberweisung löschbar (auch bezahlte/offene).
-- Ohne ID ("alle löschen") werden weiterhin nur abgelehnte/stornierte entfernt.
create or replace function public.node_delete_bank_orders(p_key text, p_id uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_id is not null then
    delete from public.bank_orders where id = p_id;
  else
    delete from public.bank_orders where status in ('rejected', 'cancelled');
  end if;
  get diagnostics v_count = row_count;
  if p_id is not null and v_count = 0 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_deletable'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'deleted', v_count);
end;
$$;
revoke all on function public.node_delete_bank_orders(text, uuid) from public;
grant execute on function public.node_delete_bank_orders(text, uuid) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
