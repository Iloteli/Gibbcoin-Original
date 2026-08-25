-- Keep direct Data API access explicitly closed. The authenticated RPCs are
-- the only supported entry points and validate auth.uid() on every call.
create policy "group_wallets_rpc_only"
on public.group_wallets for all to authenticated
using (false) with check (false);

create policy "group_wallet_members_rpc_only"
on public.group_wallet_members for all to authenticated
using (false) with check (false);

create policy "group_wallet_entries_rpc_only"
on public.group_wallet_entries for all to authenticated
using (false) with check (false);

create policy "abuse_reports_rpc_only"
on public.abuse_reports for all to authenticated
using (false) with check (false);

create index abuse_reports_reviewed_by_idx on public.abuse_reports(reviewed_by);
