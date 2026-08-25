-- Make the intentional hidden-card policy explicit and cover the settings FK.
create policy blackjack_sessions_no_direct_read
  on public.blackjack_sessions for select to authenticated using (false);

create index game_settings_updated_by_idx
  on public.game_settings (updated_by)
  where updated_by is not null;
