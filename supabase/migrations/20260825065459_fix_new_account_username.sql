-- Registration failed because profiles.username is required in production,
-- while the signup trigger only inserted display_name, email and avatar_url.
-- Keep the column reproducible and always generate a valid, unique username.
alter table public.profiles
  add column if not exists username text;

update public.profiles p
set username = 'u' || pg_catalog.left(
  pg_catalog.replace(p.id::text, '-', ''),
  23
)
where p.username is null;

alter table public.profiles
  alter column username set not null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.profiles'::pg_catalog.regclass
      and c.conname = 'profiles_username_format_check'
  ) then
    alter table public.profiles
      add constraint profiles_username_format_check
      check (username ~ '^[a-z0-9][a-z0-9._-]{2,23}$');
  end if;
end;
$$;

create unique index if not exists profiles_username_lower_unique
  on public.profiles (pg_catalog.lower(username));

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email_name text := pg_catalog.lower(
    pg_catalog.split_part(coalesce(new.email, ''), '@', 1)
  );
  v_username text;
  v_display_name text;
begin
  v_username := pg_catalog.lower(pg_catalog.btrim(coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    v_email_name,
    ''
  )));
  v_username := pg_catalog.regexp_replace(v_username, '[^a-z0-9._-]+', '-', 'g');
  v_username := pg_catalog.regexp_replace(v_username, '^[^a-z0-9]+', '', 'g');
  v_username := pg_catalog.left(v_username, 24);

  if pg_catalog.char_length(v_username) < 3 then
    v_username := 'gibb_user';
  end if;

  if exists (
    select 1
    from public.profiles p
    where pg_catalog.lower(p.username) = v_username
  ) then
    v_username := pg_catalog.left(v_username, 15)
      || '_'
      || pg_catalog.left(pg_catalog.replace(new.id::text, '-', ''), 8);
  end if;

  v_display_name := pg_catalog.btrim(coalesce(
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(v_email_name, ''),
    v_username
  ));
  if pg_catalog.char_length(v_display_name) < 2 then
    v_display_name := 'GIBB Benutzer';
  end if;
  v_display_name := pg_catalog.left(v_display_name, 60);

  begin
    insert into public.profiles (id, username, display_name, email, avatar_url)
    values (
      new.id,
      v_username,
      v_display_name,
      coalesce(new.email, ''),
      nullif(new.raw_user_meta_data ->> 'avatar_url', '')
    )
    on conflict (id) do nothing;
  exception
    when unique_violation then
      -- A concurrent signup may claim the email-derived name. The UUID-based
      -- fallback remains valid and unique to this account.
      v_username := 'u' || pg_catalog.left(
        pg_catalog.replace(new.id::text, '-', ''),
        23
      );
      insert into public.profiles (id, username, display_name, email, avatar_url)
      values (
        new.id,
        v_username,
        v_display_name,
        coalesce(new.email, ''),
        nullif(new.raw_user_meta_data ->> 'avatar_url', '')
      )
      on conflict (id) do nothing;
  end;

  insert into public.wallets (user_id, balance)
  values (new.id, 10)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;
