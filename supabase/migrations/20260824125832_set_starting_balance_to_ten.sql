-- New accounts start with 10 GIBB. Existing wallets are deliberately unchanged.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, email, avatar_url)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      pg_catalog.split_part(coalesce(new.email, 'GIBB Benutzer'), '@', 1)
    ),
    coalesce(new.email, ''),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  )
  on conflict (id) do nothing;

  insert into public.wallets (user_id, balance)
  values (new.id, 10)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;
