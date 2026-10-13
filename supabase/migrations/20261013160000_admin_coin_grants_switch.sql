-- "Admin Coins geben" abschaltbar – standardmässig AUS.
-- Eingeschaltet wird es nur auf der Chain-Seite (Ilja); die überträgt den Schalter mit dem
-- Schlüssel der Chain-Seite über public.node_set_admin_features(). Coins abziehen bleibt möglich.

create or replace function private.admin_coin_grants_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value ->> 'coin_grants')::boolean
                   from private.admin_control_settings s where s.key = 'admin_features'), false);
$$;
revoke all on function private.admin_coin_grants_enabled() from public, anon, authenticated;

-- Für das Admin-Panel: ist Gutschreiben gerade erlaubt?
create or replace function public.get_admin_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('coin_grants', private.admin_coin_grants_enabled()); $$;
revoke all on function public.get_admin_features() from public, anon;
grant execute on function public.get_admin_features() to authenticated;

-- Chain-Seite -> Hauptseite (mit dem Schlüssel aus "sudo gibb-chain-key")
create or replace function public.node_set_admin_features(p_key text, p_features jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('admin_features',
          pg_catalog.jsonb_build_object('coin_grants', coalesce((p_features ->> 'coin_grants')::boolean, false)),
          null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true, 'coin_grants', private.admin_coin_grants_enabled());
end;
$$;
revoke all on function public.node_set_admin_features(text, jsonb) from public;
grant execute on function public.node_set_admin_features(text, jsonb) to anon, authenticated, service_role;

-- Gutschriften im Admin-Panel sperren, solange der Schalter aus ist.
do $migration$
declare
  v_def text;
  v_pos integer;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.admin_adjust_balance_secure(uuid, bigint, text, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'coin_grants_switch') = 0 then
    v_pos := pg_catalog.strpos(v_def, E'\nbegin\n');
    -- Andere Schreibweise (z. B. in der Cloud): überspringen – 20261013180000 ersetzt die Funktion ohnehin.
    if v_pos = 0 then raise notice 'admin_adjust_balance_secure übersprungen'; return; end if;
    v_def := pg_catalog.left(v_def, v_pos + 6)
      || E'  -- coin_grants_switch: Gutschreiben nur, wenn auf der Chain-Seite eingeschaltet\n'
      || E'  if p_amount > 0 and not private.admin_coin_grants_enabled() then\n'
      || E'    return pg_catalog.jsonb_build_object(''ok'', false, ''error'', ''coin_grants_disabled'');\n'
      || E'  end if;\n'
      || pg_catalog.substr(v_def, v_pos + 7);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';
