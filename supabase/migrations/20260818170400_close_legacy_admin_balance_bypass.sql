-- The current UI uses the PIN-protected adjustment endpoint. The older
-- absolute-balance RPC is no longer needed in browsers and could otherwise
-- bypass the Owner-only rule for coin removal.
revoke all on function public.admin_set_balance_secure(uuid, bigint, text, text)
from public, anon, authenticated;

grant execute on function public.admin_set_balance_secure(uuid, bigint, text, text)
to service_role;
