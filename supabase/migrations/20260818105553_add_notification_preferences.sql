-- Persönliche In-App- und Browser-Benachrichtigungen.
create table if not exists public.notifications (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  title text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  notifications_enabled boolean not null default true,
  coins_received_enabled boolean not null default true,
  browser_notifications_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;

revoke all on table public.notifications from public, anon, authenticated;
grant select on table public.notifications to authenticated;
grant update (is_read) on table public.notifications to authenticated;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own
  on public.notifications for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists notifications_mark_own_read on public.notifications;
create policy notifications_mark_own_read
  on public.notifications for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on table public.notification_preferences from public, anon, authenticated;
grant select, insert on table public.notification_preferences to authenticated;
grant update (
  notifications_enabled,
  coins_received_enabled,
  browser_notifications_enabled
) on table public.notification_preferences to authenticated;

drop policy if exists notification_preferences_select_own on public.notification_preferences;
create policy notification_preferences_select_own
  on public.notification_preferences for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists notification_preferences_insert_own on public.notification_preferences;
create policy notification_preferences_insert_own
  on public.notification_preferences for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists notification_preferences_update_own on public.notification_preferences;
create policy notification_preferences_update_own
  on public.notification_preferences for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

insert into public.notification_preferences (user_id)
select id from auth.users
on conflict (user_id) do nothing;

create or replace function private.create_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function private.create_notification_preferences() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_notification_preferences on auth.users;
create trigger on_auth_user_created_notification_preferences
  after insert on auth.users
  for each row execute function private.create_notification_preferences();

create or replace function private.apply_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notifications_enabled boolean := true;
  v_coins_received_enabled boolean := true;
begin
  select p.notifications_enabled, p.coins_received_enabled
    into v_notifications_enabled, v_coins_received_enabled
  from public.notification_preferences p
  where p.user_id = new.user_id;

  if not coalesce(v_notifications_enabled, true) then
    return null;
  end if;

  if new.kind = 'transfer_received' and not coalesce(v_coins_received_enabled, true) then
    return null;
  end if;

  return new;
end;
$$;

revoke all on function private.apply_notification_preferences() from public, anon, authenticated;

drop trigger if exists apply_notification_preferences_before_insert on public.notifications;
create trigger apply_notification_preferences_before_insert
  before insert on public.notifications
  for each row execute function private.apply_notification_preferences();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'notifications'
    )
  then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;

alter table public.notifications force row level security;
alter table public.notification_preferences force row level security;
