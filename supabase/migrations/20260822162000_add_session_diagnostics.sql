create table if not exists public.session_diagnostics (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  app_version text,
  reported_status integer,
  reported_code text,
  reported_message text,
  jwt_alg text,
  jwt_kid text,
  jwt_iss text,
  jwt_aud text,
  jwt_role text,
  jwt_aal text,
  auth_status integer not null,
  data_status integer not null,
  data_error text
);

alter table public.session_diagnostics enable row level security;
revoke all on table public.session_diagnostics from anon, authenticated;
revoke all on sequence public.session_diagnostics_id_seq from anon, authenticated;

comment on table public.session_diagnostics is
  'Security-safe session diagnostics. Never stores access tokens, passwords, MFA codes, email addresses, user IDs or IP addresses.';
