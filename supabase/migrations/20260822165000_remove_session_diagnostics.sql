drop function if exists public.submit_session_timing_diagnostic(
  text, integer, text, text, text, text, text, text, text, text,
  bigint, bigint, bigint, timestamptz, timestamptz, integer, integer, text
);

drop function if exists public.submit_session_diagnostic(
  text, integer, text, text, text, text, text, text, text, text,
  integer, integer, text
);

drop table if exists public.session_diagnostics;
