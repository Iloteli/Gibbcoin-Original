-- Abgelehnte und stornierte Banküberweisungen löschen (bezahlte bleiben als Nachweis).
-- * Chain-Seite: einzeln oder alle auf einmal (mit dem Chain-Schlüssel).
-- * Hauptseite: die eigene abgelehnte/stornierte Bestellung aus der Liste entfernen.

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
  delete from public.bank_orders
  where status in ('rejected', 'cancelled') and (p_id is null or id = p_id);
  get diagnostics v_count = row_count;
  if p_id is not null and v_count = 0 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_deletable'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'deleted', v_count);
end;
$$;
revoke all on function public.node_delete_bank_orders(text, uuid) from public;
grant execute on function public.node_delete_bank_orders(text, uuid) to anon, authenticated, service_role;

create or replace function public.delete_my_bank_order(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  delete from public.bank_orders where id = p_id and user_id = v_me and status in ('rejected', 'cancelled');
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_deletable'); end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.delete_my_bank_order(uuid) from public, anon;
grant execute on function public.delete_my_bank_order(uuid) to authenticated;

notify pgrst, 'reload schema';
