alter table public.session_diagnostics
  add column if not exists jwt_iat bigint,
  add column if not exists jwt_exp bigint,
  add column if not exists edge_epoch bigint,
  add column if not exists auth_date timestamptz,
  add column if not exists data_date timestamptz;

create or replace function public.submit_session_timing_diagnostic(
  p_app_version text,
  p_reported_status integer,
  p_reported_code text,
  p_reported_message text,
  p_jwt_alg text,
  p_jwt_kid text,
  p_jwt_iss text,
  p_jwt_aud text,
  p_jwt_role text,
  p_jwt_aal text,
  p_jwt_iat bigint,
  p_jwt_exp bigint,
  p_edge_epoch bigint,
  p_auth_date timestamptz,
  p_data_date timestamptz,
  p_auth_status integer,
  p_data_status integer,
  p_data_error text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.session_diagnostics (
    app_version, reported_status, reported_code, reported_message,
    jwt_alg, jwt_kid, jwt_iss, jwt_aud, jwt_role, jwt_aal,
    jwt_iat, jwt_exp, edge_epoch, auth_date, data_date,
    auth_status, data_status, data_error
  ) values (
    left(p_app_version, 20), p_reported_status, left(p_reported_code, 100), left(p_reported_message, 300),
    left(p_jwt_alg, 30), left(p_jwt_kid, 100), left(p_jwt_iss, 200), left(p_jwt_aud, 100),
    left(p_jwt_role, 100), left(p_jwt_aal, 30), p_jwt_iat, p_jwt_exp, p_edge_epoch,
    p_auth_date, p_data_date, p_auth_status, p_data_status, left(p_data_error, 500)
  );
end;
$$;

revoke all on function public.submit_session_timing_diagnostic(text, integer, text, text, text, text, text, text, text, text, bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text) from public;
grant execute on function public.submit_session_timing_diagnostic(text, integer, text, text, text, text, text, text, text, text, bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text) to anon;

comment on function public.submit_session_timing_diagnostic(text, integer, text, text, text, text, text, text, text, text, bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text) is
  'Accepts bounded, non-secret JWT timing metadata and API response dates for session troubleshooting.';
