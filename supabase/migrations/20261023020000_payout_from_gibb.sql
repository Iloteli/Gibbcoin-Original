-- Auszahlen direkt aus GIBB: verkauft die GIBB zum aktuellen Kurs (wie "An die Bank verkaufen")
-- und fordert den Erlös sofort als Auszahlung an. Klappt die Auszahlung nicht, wird auch nichts verkauft.
create or replace function public.request_payout_gibb(p_gibb bigint, p_iban text, p_holder text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_sell jsonb;
  v_payout jsonb;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if p_gibb is null or p_gibb < 1 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount'); end if;
  if not coalesce((private.payout_settings() ->> 'enabled')::boolean, false) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'payouts_disabled'); end if;
  v_sell := public.market_sell(p_gibb);
  if not coalesce((v_sell ->> 'ok')::boolean, false) then return v_sell; end if;
  v_payout := public.request_payout((v_sell ->> 'rappen')::bigint, p_iban, p_holder);
  if not coalesce((v_payout ->> 'ok')::boolean, false) then
    -- Verkauf rückgängig machen (ganze Anfrage zurückrollen)
    raise exception 'payout_failed:%', coalesce(v_payout ->> 'error', 'unknown');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', (v_sell ->> 'rappen')::bigint);
end;
$$;
revoke all on function public.request_payout_gibb(bigint, text, text) from public, anon;
grant execute on function public.request_payout_gibb(bigint, text, text) to authenticated;

notify pgrst, 'reload schema';
