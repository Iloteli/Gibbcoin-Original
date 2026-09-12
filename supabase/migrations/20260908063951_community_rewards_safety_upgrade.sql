-- Community, rewards, fair-play, safety, seasonal and profile upgrade.
-- All browser-facing mutations stay behind authenticated RPCs and RLS.

-- Every admin surface, including read-only account inventory, requires a
-- currently verified aal2 session. This intentionally replaces opt-in MFA.
create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then raise exception 'mfa_required'; end if;
  select p.role, w.status into v_role, v_wallet_status
  from public.profiles p join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;
  if v_role not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  if v_wallet_status <> 'active' then raise exception 'account_locked'; end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_admin() from public, anon, authenticated;

-- Retire the obsolete unrestricted transfer endpoint. All transfers use the
-- newer validated transfer_coins RPC.
do $$
begin
  if pg_catalog.to_regprocedure('public.transfer_gibb(uuid,bigint)') is not null then
    execute 'revoke all on function public.transfer_gibb(uuid,bigint) from public, anon, authenticated';
  end if;
end;
$$;

-- Rotate short group join codes and require 128-bit (32 hex character) codes.
alter table public.group_wallets drop constraint if exists group_wallets_join_code_check;
update public.group_wallets
set join_code = pg_catalog.upper(pg_catalog.encode(extensions.gen_random_bytes(16), 'hex'));
alter table public.group_wallets add constraint group_wallets_join_code_check
  check (join_code ~ '^[A-F0-9]{32}$');

create or replace function public.create_group_wallet(p_name text, p_description text default null)
returns table(group_id uuid, join_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_group_id uuid;
  v_join_code text;
  v_attempts integer := 0;
begin
  p_name := pg_catalog.btrim(coalesce(p_name, ''));
  p_description := nullif(pg_catalog.btrim(coalesce(p_description, '')), '');
  if pg_catalog.char_length(p_name) not between 3 and 60 then raise exception 'invalid_group_name'; end if;
  if pg_catalog.char_length(coalesce(p_description, '')) > 160 then raise exception 'description_too_long'; end if;
  if (select pg_catalog.count(*) from public.group_wallets g where g.owner_user_id = v_user_id) >= 10 then raise exception 'group_limit_reached'; end if;
  loop
    v_attempts := v_attempts + 1;
    v_join_code := pg_catalog.upper(pg_catalog.encode(extensions.gen_random_bytes(16), 'hex'));
    exit when not exists (select 1 from public.group_wallets g where g.join_code = v_join_code);
    if v_attempts >= 5 then raise exception 'join_code_generation_failed'; end if;
  end loop;
  insert into public.group_wallets(name, description, owner_user_id, join_code)
  values (p_name, p_description, v_user_id, v_join_code) returning id into v_group_id;
  insert into public.group_wallet_members(group_id, user_id, role) values (v_group_id, v_user_id, 'owner');
  return query select v_group_id, v_join_code;
end;
$$;

create or replace function public.join_group_wallet(p_join_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_group_id uuid;
  v_code text := pg_catalog.upper(pg_catalog.btrim(coalesce(p_join_code, '')));
begin
  if v_code !~ '^[A-F0-9]{32}$' then raise exception 'invalid_join_code'; end if;
  if (select pg_catalog.count(*) from public.group_wallet_members m where m.user_id = v_user_id) >= 30 then raise exception 'membership_limit_reached'; end if;
  select g.id into v_group_id from public.group_wallets g where g.join_code = v_code;
  if v_group_id is null then raise exception 'group_not_found'; end if;
  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'member') on conflict (group_id, user_id) do nothing;
  return v_group_id;
end;
$$;
revoke all on function public.create_group_wallet(text, text) from public, anon, authenticated;
grant execute on function public.create_group_wallet(text, text) to authenticated;
revoke all on function public.join_group_wallet(text) from public, anon, authenticated;
grant execute on function public.join_group_wallet(text) to authenticated;

alter table public.profiles
  add column if not exists bio text,
  add column if not exists profile_color text not null default '#35e070',
  add column if not exists equipped_title text;

alter table public.profiles drop constraint if exists profiles_bio_check;
alter table public.profiles add constraint profiles_bio_check
  check (bio is null or pg_catalog.char_length(bio) <= 180);
alter table public.profiles drop constraint if exists profiles_profile_color_check;
alter table public.profiles add constraint profiles_profile_color_check
  check (profile_color ~ '^#[0-9a-fA-F]{6}$');
alter table public.profiles drop constraint if exists profiles_equipped_title_check;
alter table public.profiles add constraint profiles_equipped_title_check
  check (equipped_title is null or pg_catalog.char_length(equipped_title) between 2 and 40);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 2097152,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read" on storage.objects
for select to public
using (bucket_id = 'avatars');

drop policy if exists "avatars_insert_own" on storage.objects;
create policy "avatars_insert_own" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own" on storage.objects
for update to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own" on storage.objects
for delete to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create or replace function public.update_my_profile(
  p_display_name text,
  p_bio text,
  p_profile_color text,
  p_avatar_url text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_name text := pg_catalog.btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(pg_catalog.btrim(coalesce(p_bio, '')), '');
  v_color text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_profile_color, '')));
  v_avatar text := nullif(pg_catalog.btrim(coalesce(p_avatar_url, '')), '');
  v_current_avatar text;
begin
  if pg_catalog.char_length(v_name) not between 2 and 60 then raise exception 'invalid_display_name'; end if;
  if v_bio is not null and pg_catalog.char_length(v_bio) > 180 then raise exception 'invalid_bio'; end if;
  if v_color !~ '^#[0-9a-f]{6}$' then raise exception 'invalid_profile_color'; end if;

  select p.avatar_url into v_current_avatar
  from public.profiles p where p.id = v_user_id;

  if v_avatar is distinct from v_current_avatar
     and v_avatar is not null
     and v_avatar !~ (
       '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/avatars/'
       || v_user_id::text || '/[A-Za-z0-9._-]+$'
     )
  then raise exception 'invalid_avatar_url'; end if;

  update public.profiles
  set display_name = v_name,
      bio = v_bio,
      profile_color = v_color,
      avatar_url = v_avatar,
      updated_at = now()
  where id = v_user_id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'display_name', v_name,
    'bio', v_bio,
    'profile_color', v_color,
    'avatar_url', v_avatar
  );
end;
$$;

revoke all on function public.update_my_profile(text, text, text, text) from public, anon, authenticated;
grant execute on function public.update_my_profile(text, text, text, text) to authenticated;

-- Daily tasks and one-time achievements.
create table if not exists public.daily_tasks (
  task_key text primary key,
  name text not null check (pg_catalog.char_length(name) between 2 and 60),
  description text not null check (pg_catalog.char_length(description) between 3 and 160),
  target_count integer not null check (target_count > 0),
  reward bigint not null check (reward > 0 and reward <= 500),
  active boolean not null default true,
  sort_order smallint not null default 0
);

create table if not exists public.daily_task_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  task_key text not null references public.daily_tasks(task_key) on delete cascade,
  task_date date not null default current_date,
  progress integer not null check (progress >= 0),
  reward bigint not null check (reward > 0),
  transaction_id uuid not null references public.transactions(id),
  created_at timestamptz not null default now(),
  primary key (user_id, task_key, task_date)
);

create table if not exists public.daily_rewards (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reward_date date not null default current_date,
  amount bigint not null check (amount > 0 and amount <= 100),
  transaction_id uuid not null references public.transactions(id),
  created_at timestamptz not null default now(),
  unique (user_id, reward_date)
);

create table if not exists public.challenges (
  id uuid primary key default extensions.gen_random_uuid(),
  slug text not null unique,
  name text not null check (pg_catalog.char_length(name) between 2 and 60),
  description text not null check (pg_catalog.char_length(description) between 3 and 180),
  target_count integer not null check (target_count > 0),
  reward bigint not null check (reward > 0 and reward <= 1000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.user_challenges (
  user_id uuid not null references auth.users(id) on delete cascade,
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  claimed_at timestamptz not null default now(),
  primary key (user_id, challenge_id)
);

alter table public.daily_tasks enable row level security;
alter table public.daily_tasks force row level security;
alter table public.daily_task_claims enable row level security;
alter table public.daily_task_claims force row level security;
revoke all on table public.daily_tasks, public.daily_task_claims from public, anon, authenticated;
grant select on table public.daily_tasks, public.daily_task_claims to authenticated;

drop policy if exists daily_tasks_read_active on public.daily_tasks;
create policy daily_tasks_read_active on public.daily_tasks
for select to authenticated using (active = true);
drop policy if exists daily_task_claims_read_own on public.daily_task_claims;
create policy daily_task_claims_read_own on public.daily_task_claims
for select to authenticated using ((select auth.uid()) = user_id);

insert into public.daily_tasks (task_key, name, description, target_count, reward, sort_order)
values
  ('daily_transfer', 'Coins senden', 'Sende heute mindestens einmal Coins an eine andere Person.', 1, 10, 1),
  ('daily_play', 'Eine Runde spielen', 'Schliesse heute eine serverbestätigte Spielrunde ab.', 1, 10, 2),
  ('daily_play_three', 'Drei Runden spielen', 'Schliesse heute drei serverbestätigte Spielrunden ab.', 3, 20, 3)
on conflict (task_key) do update
set name = excluded.name,
    description = excluded.description,
    target_count = excluded.target_count,
    reward = excluded.reward,
    active = true,
    sort_order = excluded.sort_order;

insert into public.challenges (slug, name, description, target_count, reward, active)
values
  ('send_3', 'Teamplayer', 'Sende insgesamt dreimal Coins.', 3, 30, true),
  ('receive_2', 'Gut vernetzt', 'Erhalte zweimal Coins von anderen Personen.', 2, 25, true),
  ('marketplace_first', 'Erster Style', 'Kaufe deinen ersten Gegenstand im Campus-Shop.', 1, 20, true),
  ('play_5', 'Game-Starter', 'Schliesse fünf Spielrunden ab.', 5, 35, true),
  ('win_2', 'Gewinnserie', 'Gewinne zwei serverbestätigte Spielrunden.', 2, 40, true),
  ('dino_1000', 'Dino-Profi', 'Erreiche mindestens 1’000 Punkte in Dino Run.', 1000, 50, true)
on conflict (slug) do update
set name = excluded.name,
    description = excluded.description,
    target_count = excluded.target_count,
    reward = excluded.reward,
    active = true;

alter table public.challenges enable row level security;
alter table public.challenges force row level security;
alter table public.user_challenges enable row level security;
alter table public.user_challenges force row level security;
alter table public.daily_rewards enable row level security;
alter table public.daily_rewards force row level security;
revoke all on table public.challenges, public.user_challenges, public.daily_rewards from public, anon, authenticated;
grant select on table public.challenges, public.user_challenges, public.daily_rewards to authenticated;
drop policy if exists challenges_read_active on public.challenges;
create policy challenges_read_active on public.challenges
for select to authenticated using (active = true);
drop policy if exists user_challenges_read_own on public.user_challenges;
create policy user_challenges_read_own on public.user_challenges
for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists daily_rewards_read_own on public.daily_rewards;
create policy daily_rewards_read_own on public.daily_rewards
for select to authenticated using ((select auth.uid()) = user_id);

create or replace function private.daily_task_progress(p_user_id uuid, p_task_key text, p_date date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case p_task_key
    when 'daily_transfer' then (
      select count(*)::integer from public.transactions t
      where t.sender_user_id = p_user_id and t.type = 'TRANSFER'
        and t.created_at >= p_date::timestamptz
        and t.created_at < (p_date + 1)::timestamptz
    )
    when 'daily_play' then (
      select count(*)::integer from public.game_rounds r
      where r.user_id = p_user_id
        and r.created_at >= p_date::timestamptz
        and r.created_at < (p_date + 1)::timestamptz
    )
    when 'daily_play_three' then (
      select count(*)::integer from public.game_rounds r
      where r.user_id = p_user_id
        and r.created_at >= p_date::timestamptz
        and r.created_at < (p_date + 1)::timestamptz
    )
    else 0
  end;
$$;
revoke all on function private.daily_task_progress(uuid, text, date) from public, anon, authenticated;

create or replace function public.get_daily_tasks()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_tasks jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'task_key', d.task_key,
    'name', d.name,
    'description', d.description,
    'target_count', d.target_count,
    'progress', least(d.target_count, private.daily_task_progress(v_user_id, d.task_key, current_date)),
    'reward', d.reward,
    'claimed', exists (
      select 1 from public.daily_task_claims c
      where c.user_id = v_user_id and c.task_key = d.task_key and c.task_date = current_date
    )
  ) order by d.sort_order), '[]'::jsonb)
  into v_tasks from public.daily_tasks d where d.active;
  return pg_catalog.jsonb_build_object('ok', true, 'date', current_date, 'tasks', v_tasks);
end;
$$;

create or replace function public.claim_daily_task(p_task_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_task public.daily_tasks%rowtype;
  v_progress integer;
  v_wallet_id uuid;
  v_transaction_id uuid;
begin
  select d.* into v_task from public.daily_tasks d
  where d.task_key = p_task_key and d.active;
  if v_task.task_key is null then raise exception 'daily_task_not_found'; end if;
  if exists (
    select 1 from public.daily_task_claims c
    where c.user_id = v_user_id and c.task_key = v_task.task_key and c.task_date = current_date
  ) then raise exception 'daily_task_already_claimed'; end if;

  v_progress := private.daily_task_progress(v_user_id, v_task.task_key, current_date);
  if v_progress < v_task.target_count then raise exception 'daily_task_not_completed'; end if;

  select w.id into v_wallet_id from public.wallets w
  where w.user_id = v_user_id and w.status = 'active' for update;
  if v_wallet_id is null then raise exception 'wallet_locked'; end if;
  if exists (
    select 1 from public.daily_task_claims c
    where c.user_id = v_user_id and c.task_key = v_task.task_key and c.task_date = current_date
  ) then raise exception 'daily_task_already_claimed'; end if;

  update public.wallets set balance = balance + v_task.reward where id = v_wallet_id;
  v_transaction_id := private.append_transaction(
    null, v_user_id, v_task.reward, 'CHALLENGE_REWARD', 'Tagesaufgabe: ' || v_task.name
  );
  insert into public.daily_task_claims (
    user_id, task_key, task_date, progress, reward, transaction_id
  ) values (
    v_user_id, v_task.task_key, current_date, v_progress, v_task.reward, v_transaction_id
  );
  insert into public.notifications (user_id, kind, title, message)
  values (v_user_id, 'daily_task', 'Tagesaufgabe abgeschlossen',
    v_task.name || ': +' || v_task.reward || ' GIBB');

  return pg_catalog.jsonb_build_object('ok', true, 'reward', v_task.reward, 'transaction_id', v_transaction_id);
end;
$$;

revoke all on function public.get_daily_tasks() from public, anon, authenticated;
grant execute on function public.get_daily_tasks() to authenticated;
revoke all on function public.claim_daily_task(text) from public, anon, authenticated;
grant execute on function public.claim_daily_task(text) to authenticated;

create or replace function public.claim_daily_reward()
returns table(amount bigint, cycle_day integer, transaction_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_claim_count integer;
  v_cycle_day integer;
  v_amount bigint;
  v_wallet_id uuid;
  v_transaction_id uuid;
begin
  select w.id into v_wallet_id from public.wallets w
  where w.user_id = v_user_id and w.status = 'active' for update;
  if v_wallet_id is null then raise exception 'wallet_locked'; end if;
  if exists (
    select 1 from public.daily_rewards r
    where r.user_id = v_user_id and r.reward_date = current_date
  ) then raise exception 'daily_reward_already_claimed'; end if;

  select count(*)::integer into v_claim_count
  from public.daily_rewards r where r.user_id = v_user_id;
  v_cycle_day := (v_claim_count % 7) + 1;
  v_amount := (array[5, 10, 15, 20, 25, 30, 50]::bigint[])[v_cycle_day];

  update public.wallets set balance = balance + v_amount where id = v_wallet_id;
  v_transaction_id := private.append_transaction(
    null, v_user_id, v_amount, 'DAILY_REWARD', 'Tagesbonus Tag ' || v_cycle_day
  );
  insert into public.daily_rewards (user_id, reward_date, amount, transaction_id)
  values (v_user_id, current_date, v_amount, v_transaction_id);
  insert into public.notifications (user_id, kind, title, message)
  values (v_user_id, 'daily_reward', 'Tagesbonus abgeholt', '+' || v_amount || ' GIBB wurden gutgeschrieben.');

  return query select v_amount, v_cycle_day, v_transaction_id;
end;
$$;

revoke all on function public.claim_daily_reward() from public, anon, authenticated;
grant execute on function public.claim_daily_reward() to authenticated;

create or replace function public.get_challenge_progress()
returns table (challenge_id uuid, progress integer, target_count integer, claimed boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
begin
  return query
  select c.id,
    least(c.target_count,
      case c.slug
        when 'send_3' then (select count(*)::integer from public.transactions t where t.sender_user_id = v_user_id and t.type = 'TRANSFER')
        when 'receive_2' then (select count(*)::integer from public.transactions t where t.receiver_user_id = v_user_id and t.type = 'TRANSFER')
        when 'marketplace_first' then (select count(*)::integer from public.purchases p where p.user_id = v_user_id)
        when 'play_5' then (select count(*)::integer from public.game_rounds r where r.user_id = v_user_id)
        when 'win_2' then (select count(*)::integer from public.game_rounds r where r.user_id = v_user_id and r.payout > r.wager)
        when 'dino_1000' then coalesce((select max(d.score)::integer from public.dino_run_sessions d where d.user_id = v_user_id), 0)
        else 0
      end
    ) as progress,
    c.target_count,
    exists (
      select 1 from public.user_challenges uc
      where uc.user_id = v_user_id and uc.challenge_id = c.id
    ) as claimed
  from public.challenges c
  where c.active = true
  order by c.created_at, c.slug;
end;
$$;

create or replace function public.claim_challenge(p_challenge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_challenge public.challenges%rowtype;
  v_progress integer := 0;
  v_wallet_id uuid;
  v_transaction_id uuid;
begin
  select c.* into v_challenge from public.challenges c
  where c.id = p_challenge_id and c.active = true;
  if v_challenge.id is null then raise exception 'challenge_not_found'; end if;
  if exists (
    select 1 from public.user_challenges
    where user_id = v_user_id and challenge_id = p_challenge_id
  ) then raise exception 'challenge_already_claimed'; end if;

  case v_challenge.slug
    when 'send_3' then select count(*)::integer into v_progress from public.transactions where sender_user_id = v_user_id and type = 'TRANSFER';
    when 'receive_2' then select count(*)::integer into v_progress from public.transactions where receiver_user_id = v_user_id and type = 'TRANSFER';
    when 'marketplace_first' then select count(*)::integer into v_progress from public.purchases where user_id = v_user_id;
    when 'play_5' then select count(*)::integer into v_progress from public.game_rounds where user_id = v_user_id;
    when 'win_2' then select count(*)::integer into v_progress from public.game_rounds where user_id = v_user_id and payout > wager;
    when 'dino_1000' then select coalesce(max(score), 0)::integer into v_progress from public.dino_run_sessions where user_id = v_user_id;
    else v_progress := 0;
  end case;
  if v_progress < v_challenge.target_count then raise exception 'challenge_not_completed'; end if;

  select w.id into v_wallet_id from public.wallets w
  where w.user_id = v_user_id and w.status = 'active' for update;
  if v_wallet_id is null then raise exception 'wallet_locked'; end if;
  insert into public.user_challenges (user_id, challenge_id) values (v_user_id, p_challenge_id);
  update public.wallets set balance = balance + v_challenge.reward where id = v_wallet_id;
  v_transaction_id := private.append_transaction(
    null, v_user_id, v_challenge.reward, 'CHALLENGE_REWARD', v_challenge.name
  );
  insert into public.notifications (user_id, kind, title, message)
  values (v_user_id, 'challenge', 'Erfolg freigeschaltet',
    v_challenge.name || ': +' || v_challenge.reward || ' GIBB');
  return v_transaction_id;
end;
$$;

revoke all on function public.get_challenge_progress() from public, anon, authenticated;
grant execute on function public.get_challenge_progress() to authenticated;
revoke all on function public.claim_challenge(uuid) from public, anon, authenticated;
grant execute on function public.claim_challenge(uuid) to authenticated;

-- Cosmetic shop and equipping.
create table if not exists public.marketplace_items (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (pg_catalog.char_length(name) between 2 and 60),
  description text not null check (pg_catalog.char_length(description) between 3 and 180),
  price bigint not null check (price > 0 and price <= 1000000),
  icon text not null default '◆' check (pg_catalog.char_length(icon) between 1 and 12),
  active boolean not null default true,
  stock integer check (stock is null or stock >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.purchases (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id uuid not null references public.marketplace_items(id) on delete restrict,
  price bigint not null check (price > 0),
  transaction_id uuid not null references public.transactions(id),
  created_at timestamptz not null default now()
);

alter table public.marketplace_items
  add column if not exists kind text not null default 'title',
  add column if not exists cosmetic_value text;
alter table public.marketplace_items drop constraint if exists marketplace_items_kind_check;
alter table public.marketplace_items add constraint marketplace_items_kind_check
  check (kind in ('title', 'color'));
alter table public.marketplace_items drop constraint if exists marketplace_items_cosmetic_value_check;
alter table public.marketplace_items add constraint marketplace_items_cosmetic_value_check
  check (cosmetic_value is null or pg_catalog.char_length(cosmetic_value) between 2 and 40);

create unique index if not exists marketplace_items_name_unique
  on public.marketplace_items (name);
update public.marketplace_items
set active = false, updated_at = now()
where cosmetic_value is null;

-- Historical marketplace purchases may legitimately contain repeated items.
-- New purchases are serialized by the wallet/item row locks in
-- buy_marketplace_item(), so preserve the existing ledger instead of forcing a
-- destructive de-duplication here.

alter table public.marketplace_items enable row level security;
alter table public.marketplace_items force row level security;
alter table public.purchases enable row level security;
alter table public.purchases force row level security;
revoke all on table public.marketplace_items, public.purchases from public, anon, authenticated;
grant select on table public.marketplace_items, public.purchases to authenticated;
drop policy if exists marketplace_items_read_active on public.marketplace_items;
create policy marketplace_items_read_active on public.marketplace_items
for select to authenticated using (active = true);
drop policy if exists purchases_read_own on public.purchases;
create policy purchases_read_own on public.purchases
for select to authenticated using ((select auth.uid()) = user_id);

insert into public.marketplace_items (name, description, price, icon, active, stock, kind, cosmetic_value)
values
  ('Campus-Pionier', 'Ein sichtbarer Titel für dein Profil.', 40, '◆', true, 9999, 'title', 'Campus-Pionier'),
  ('Dino-Legende', 'Ein Titel für mutige Dino-Runner.', 75, '▰', true, 9999, 'title', 'Dino-Legende'),
  ('Neon Mint', 'Mintfarbener Profil-Akzent.', 30, '●', true, 9999, 'color', '#35e070'),
  ('Electric Blue', 'Blauer Profil-Akzent.', 30, '◎', true, 9999, 'color', '#39a8ff'),
  ('Royal Gold', 'Goldener Profil-Akzent.', 60, '♛', true, 9999, 'color', '#f5c451')
on conflict (name) do update
set description = excluded.description,
    price = excluded.price,
    icon = excluded.icon,
    active = excluded.active,
    stock = greatest(public.marketplace_items.stock, excluded.stock),
    kind = excluded.kind,
    cosmetic_value = excluded.cosmetic_value,
    updated_at = now();

create or replace function public.buy_marketplace_item(p_item_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_item public.marketplace_items%rowtype;
  v_transaction_id uuid;
begin
  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id for update;
  select i.* into v_item from public.marketplace_items i where i.id = p_item_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_item.id is null or not v_item.active then raise exception 'item_not_available'; end if;
  if exists (select 1 from public.purchases p where p.user_id = v_user_id and p.item_id = p_item_id) then
    raise exception 'item_already_owned';
  end if;
  if v_item.stock <= 0 then raise exception 'item_sold_out'; end if;
  if v_wallet.balance < v_item.price then raise exception 'insufficient_balance'; end if;

  update public.wallets set balance = balance - v_item.price where id = v_wallet.id;
  update public.marketplace_items set stock = stock - 1 where id = v_item.id;
  v_transaction_id := private.append_transaction(v_user_id, null, v_item.price, 'MARKETPLACE', v_item.name);
  insert into public.purchases (user_id, item_id, price, transaction_id)
  values (v_user_id, v_item.id, v_item.price, v_transaction_id);
  insert into public.notifications (user_id, kind, title, message)
  values (v_user_id, 'marketplace', 'Shop-Kauf erfolgreich', v_item.name || ' gehört jetzt dir.');
  return v_transaction_id;
end;
$$;

create or replace function public.equip_marketplace_item(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_item public.marketplace_items%rowtype;
begin
  select i.* into v_item
  from public.marketplace_items i
  join public.purchases p on p.item_id = i.id and p.user_id = v_user_id
  where i.id = p_item_id;
  if v_item.id is null then raise exception 'item_not_owned'; end if;

  if v_item.kind = 'title' then
    update public.profiles set equipped_title = v_item.cosmetic_value, updated_at = now()
    where id = v_user_id;
  elsif v_item.kind = 'color' then
    if v_item.cosmetic_value !~ '^#[0-9a-fA-F]{6}$' then raise exception 'invalid_cosmetic'; end if;
    update public.profiles set profile_color = pg_catalog.lower(v_item.cosmetic_value), updated_at = now()
    where id = v_user_id;
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'kind', v_item.kind, 'value', v_item.cosmetic_value);
end;
$$;

revoke all on function public.buy_marketplace_item(uuid) from public, anon, authenticated;
grant execute on function public.buy_marketplace_item(uuid) to authenticated;
revoke all on function public.equip_marketplace_item(uuid) from public, anon, authenticated;
grant execute on function public.equip_marketplace_item(uuid) to authenticated;

-- Fair-play integrity and personal safety limits.
alter table public.game_rounds
  add column if not exists fairness_nonce uuid not null default extensions.gen_random_uuid(),
  add column if not exists fairness_hash text;

create table if not exists public.player_safety_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  max_wager bigint check (max_wager is null or max_wager between 1 and 1000000000000),
  daily_loss_limit bigint check (daily_loss_limit is null or daily_loss_limit between 1 and 1000000000000),
  cooldown_seconds integer not null default 0 check (cooldown_seconds between 0 and 3600),
  break_until timestamptz,
  last_round_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.player_safety_settings enable row level security;
alter table public.player_safety_settings force row level security;
revoke all on table public.player_safety_settings from public, anon, authenticated;
grant select on table public.player_safety_settings to authenticated;
drop policy if exists player_safety_read_own on public.player_safety_settings;
create policy player_safety_read_own on public.player_safety_settings
for select to authenticated using ((select auth.uid()) = user_id);

create or replace function private.prepare_fair_game_round()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_safety public.player_safety_settings%rowtype;
  v_daily_loss bigint := 0;
  v_payload text;
begin
  if new.game_key in ('blackjack', 'poker', 'dino_run') then
    new.fairness_nonce := coalesce(new.fairness_nonce, extensions.gen_random_uuid());
    v_payload := pg_catalog.concat_ws('|',
      new.id::text, new.user_id::text, new.game_key, coalesce(new.choice, ''),
      new.wager::text, new.payout::text, new.result::text, new.fairness_nonce::text
    );
    new.fairness_hash := pg_catalog.encode(extensions.digest(v_payload, 'sha256'), 'hex');
    return new;
  end if;

  select s.* into v_safety
  from public.player_safety_settings s
  where s.user_id = new.user_id
  for update;

  if v_safety.user_id is not null then
    if v_safety.break_until is not null and v_safety.break_until > clock_timestamp() then
      raise exception 'player_break_active';
    end if;
    if v_safety.max_wager is not null and new.wager > v_safety.max_wager then
      raise exception 'player_wager_limit';
    end if;
    if v_safety.cooldown_seconds > 0
       and v_safety.last_round_at is not null
       and v_safety.last_round_at + pg_catalog.make_interval(secs => v_safety.cooldown_seconds) > clock_timestamp()
    then raise exception 'player_cooldown'; end if;

    if v_safety.daily_loss_limit is not null then
      select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint into v_daily_loss
      from public.game_rounds r
      where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;
      if v_daily_loss + greatest(new.wager - new.payout, 0) > v_safety.daily_loss_limit then
        raise exception 'player_daily_loss_limit';
      end if;
    end if;

    update public.player_safety_settings
    set last_round_at = clock_timestamp(), updated_at = clock_timestamp()
    where user_id = new.user_id;
  end if;

  new.fairness_nonce := coalesce(new.fairness_nonce, extensions.gen_random_uuid());
  v_payload := pg_catalog.concat_ws('|',
    new.id::text, new.user_id::text, new.game_key, coalesce(new.choice, ''),
    new.wager::text, new.payout::text, new.result::text, new.fairness_nonce::text
  );
  new.fairness_hash := pg_catalog.encode(extensions.digest(v_payload, 'sha256'), 'hex');
  return new;
end;
$$;
revoke all on function private.prepare_fair_game_round() from public, anon, authenticated;

create or replace function private.enforce_session_safety()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_safety public.player_safety_settings%rowtype;
  v_daily_loss bigint := 0;
begin
  select s.* into v_safety
  from public.player_safety_settings s
  where s.user_id = new.user_id
  for update;
  if v_safety.user_id is null then return new; end if;
  if v_safety.break_until is not null and v_safety.break_until > clock_timestamp() then
    raise exception 'player_break_active';
  end if;
  if v_safety.max_wager is not null and new.wager > v_safety.max_wager then
    raise exception 'player_wager_limit';
  end if;
  if v_safety.cooldown_seconds > 0
     and v_safety.last_round_at is not null
     and v_safety.last_round_at + pg_catalog.make_interval(secs => v_safety.cooldown_seconds) > clock_timestamp()
  then raise exception 'player_cooldown'; end if;
  if v_safety.daily_loss_limit is not null then
    select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint into v_daily_loss
    from public.game_rounds r
    where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;
    if v_daily_loss + new.wager > v_safety.daily_loss_limit then
      raise exception 'player_daily_loss_limit';
    end if;
  end if;
  update public.player_safety_settings
  set last_round_at = clock_timestamp(), updated_at = clock_timestamp()
  where user_id = new.user_id;
  return new;
end;
$$;
revoke all on function private.enforce_session_safety() from public, anon, authenticated;

drop trigger if exists prepare_fair_game_round_before_insert on public.game_rounds;
create trigger prepare_fair_game_round_before_insert
before insert on public.game_rounds
for each row execute function private.prepare_fair_game_round();

drop trigger if exists enforce_blackjack_session_safety on public.blackjack_sessions;
create trigger enforce_blackjack_session_safety
before insert on public.blackjack_sessions
for each row execute function private.enforce_session_safety();
drop trigger if exists enforce_poker_session_safety on public.poker_sessions;
create trigger enforce_poker_session_safety
before insert on public.poker_sessions
for each row execute function private.enforce_session_safety();
drop trigger if exists enforce_dino_session_safety on public.dino_run_sessions;
create trigger enforce_dino_session_safety
before insert on public.dino_run_sessions
for each row execute function private.enforce_session_safety();

update public.game_rounds r
set fairness_hash = pg_catalog.encode(extensions.digest(pg_catalog.concat_ws('|',
  r.id::text, r.user_id::text, r.game_key, coalesce(r.choice, ''),
  r.wager::text, r.payout::text, r.result::text, r.fairness_nonce::text
), 'sha256'), 'hex')
where r.fairness_hash is null;

alter table public.game_rounds alter column fairness_hash set not null;
alter table public.game_rounds drop constraint if exists game_rounds_fairness_hash_check;
alter table public.game_rounds add constraint game_rounds_fairness_hash_check
  check (pg_catalog.char_length(fairness_hash) = 64);
create index if not exists game_rounds_game_created_user_idx
  on public.game_rounds (game_key, created_at desc, user_id);

create or replace function public.get_my_player_safety()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_settings public.player_safety_settings%rowtype;
  v_daily_loss bigint := 0;
begin
  select s.* into v_settings from public.player_safety_settings s where s.user_id = v_user_id;
  select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint into v_daily_loss
  from public.game_rounds r where r.user_id = v_user_id and r.created_at >= current_date::timestamptz;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'max_wager', v_settings.max_wager,
    'daily_loss_limit', v_settings.daily_loss_limit,
    'daily_loss', v_daily_loss,
    'loss_today', v_daily_loss,
    'cooldown_seconds', coalesce(v_settings.cooldown_seconds, 0),
    'break_until', v_settings.break_until,
    'last_round_at', v_settings.last_round_at
  );
end;
$$;

create or replace function public.update_my_player_safety(
  p_max_wager bigint,
  p_daily_loss_limit bigint,
  p_cooldown_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
begin
  if p_max_wager is not null and p_max_wager not between 1 and 1000000000000 then raise exception 'invalid_max_wager'; end if;
  if p_daily_loss_limit is not null and p_daily_loss_limit not between 1 and 1000000000000 then raise exception 'invalid_daily_loss_limit'; end if;
  if coalesce(p_cooldown_seconds, 0) not between 0 and 3600 then raise exception 'invalid_cooldown'; end if;
  insert into public.player_safety_settings (user_id, max_wager, daily_loss_limit, cooldown_seconds)
  values (v_user_id, p_max_wager, p_daily_loss_limit, coalesce(p_cooldown_seconds, 0))
  on conflict (user_id) do update
  set max_wager = excluded.max_wager,
      daily_loss_limit = excluded.daily_loss_limit,
      cooldown_seconds = excluded.cooldown_seconds,
      updated_at = now();
  return public.get_my_player_safety();
end;
$$;

create or replace function public.start_my_game_break(p_minutes integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_until timestamptz;
begin
  if p_minutes not in (15, 60, 1440, 10080) then raise exception 'invalid_break_duration'; end if;
  v_until := clock_timestamp() + pg_catalog.make_interval(mins => p_minutes);
  insert into public.player_safety_settings (user_id, break_until)
  values (v_user_id, v_until)
  on conflict (user_id) do update
  set break_until = greatest(public.player_safety_settings.break_until, excluded.break_until),
      updated_at = now();
  return pg_catalog.jsonb_build_object('ok', true, 'break_until', v_until);
end;
$$;

revoke all on function public.get_my_player_safety() from public, anon, authenticated;
grant execute on function public.get_my_player_safety() to authenticated;
revoke all on function public.update_my_player_safety(bigint, bigint, integer) from public, anon, authenticated;
grant execute on function public.update_my_player_safety(bigint, bigint, integer) to authenticated;
revoke all on function public.start_my_game_break(integer) from public, anon, authenticated;
grant execute on function public.start_my_game_break(integer) to authenticated;

-- Permanently disable the old hidden outcome manipulation API.
update private.coin_flip_prank_settings set enabled = false, updated_at = now();
update private.game_prank_settings set enabled = false, target_user_id = null, updated_at = now();
revoke all on function public.admin_set_coin_flip_prank(boolean, integer, text) from public, anon, authenticated;
revoke all on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text) from public, anon, authenticated;
revoke all on function public.get_coin_flip_prank_admin_state() from public, anon, authenticated;
revoke all on function public.get_effective_visual_pranks() from public, anon, authenticated;
revoke all on function public.play_visual_prank_game(text, text, bigint) from public, anon, authenticated;

create or replace function public.get_dino_admin_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_setting private.dino_game_settings%rowtype;
begin
  perform private.require_admin();
  select d.* into v_setting from private.dino_game_settings d where d.singleton;
  return pg_catalog.jsonb_build_object(
    'speed_level', coalesce(v_setting.speed_level, 1),
    'difficulty_level', coalesce(v_setting.difficulty_level, 1)
  );
end;
$$;
revoke all on function public.get_dino_admin_state() from public, anon, authenticated;
grant execute on function public.get_dino_admin_state() to authenticated;

create or replace function public.get_game_center_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_balance bigint;
  v_settings jsonb;
  v_rounds jsonb;
  v_blackjack jsonb;
  v_poker jsonb;
begin
  select w.balance into v_balance from public.wallets w where w.user_id = v_user_id;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'game_key', s.game_key, 'label', s.label, 'enabled', s.enabled, 'updated_at', s.updated_at
  ) order by s.sort_order), '[]'::jsonb)
  into v_settings from public.game_settings s;

  select coalesce(pg_catalog.jsonb_agg(row_data order by created_at desc), '[]'::jsonb)
  into v_rounds
  from (
    select r.created_at, pg_catalog.jsonb_build_object(
      'id', r.id, 'game_key', r.game_key, 'choice', r.choice,
      'wager', r.wager, 'payout', r.payout, 'result', r.result,
      'fairness_hash', r.fairness_hash, 'created_at', r.created_at
    ) as row_data
    from public.game_rounds r
    where r.user_id = v_user_id
    order by r.created_at desc
    limit 8
  ) recent;

  select pg_catalog.jsonb_build_object(
    'id', b.id, 'wager', b.wager, 'player_cards', pg_catalog.to_jsonb(b.player_cards),
    'dealer_cards', pg_catalog.to_jsonb(b.dealer_cards[1:1]), 'dealer_hidden', true,
    'status', b.status, 'payout', b.payout, 'player_score', private.blackjack_score(b.player_cards)
  ) into v_blackjack from public.blackjack_sessions b
  where b.user_id = v_user_id and b.status = 'active'
  order by b.created_at desc limit 1;

  select pg_catalog.jsonb_build_object(
    'id', p.id, 'wager', p.wager, 'cards', pg_catalog.to_jsonb(p.cards),
    'status', p.status, 'payout', p.payout
  ) into v_poker from public.poker_sessions p
  where p.user_id = v_user_id and p.status = 'active'
  order by p.created_at desc limit 1;

  return pg_catalog.jsonb_build_object(
    'balance', v_balance, 'settings', v_settings, 'recent_rounds', v_rounds,
    'blackjack', v_blackjack, 'poker', v_poker
  );
end;
$$;
revoke all on function public.get_game_center_state() from public, anon, authenticated;
grant execute on function public.get_game_center_state() to authenticated;

-- Daily, weekly and all-time online leaderboards.
create or replace function public.get_game_leaderboard(p_game_key text, p_period text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_key text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  v_period text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_period, 'all')));
  v_since timestamptz;
  v_entries jsonb;
  v_me jsonb;
begin
  if v_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel', 'high_card', 'poker', 'plinko',
    'dino_run', 'slots', 'baccarat', 'keno', 'wheel', 'mines', 'bingo', 'crash'
  ) then raise exception 'invalid_game'; end if;
  if v_period not in ('today', 'week', 'all') then raise exception 'invalid_period'; end if;
  v_since := case v_period
    when 'today' then current_date::timestamptz
    when 'week' then pg_catalog.date_trunc('week', clock_timestamp())
    else null
  end;

  with aggregated as (
    select r.user_id, count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      coalesce(sum(r.wager), 0)::bigint as wagered,
      coalesce(sum(r.payout), 0)::bigint as payout,
      coalesce(sum(r.payout - r.wager), 0)::bigint as net,
      coalesce(max(r.payout), 0)::bigint as best_score,
      max(r.created_at) as updated_at
    from public.game_rounds r
    where r.game_key = v_key and (v_since is null or r.created_at >= v_since)
    group by r.user_id
  ), ranked as (
    select row_number() over (order by a.net desc, a.best_score desc, a.wins desc, a.updated_at asc, a.user_id)::integer as position,
      a.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      a.plays, a.wins, a.wagered, a.payout, a.net, a.best_score, a.updated_at,
      a.user_id = v_user_id as is_me
    from aggregated a left join public.profiles p on p.id = a.user_id
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'plays', r.plays, 'wins', r.wins, 'wagered', r.wagered, 'payout', r.payout,
    'net', r.net, 'best_score', r.best_score, 'updated_at', r.updated_at, 'is_me', r.is_me
  ) order by r.position) filter (where r.position <= 10), '[]'::jsonb)
  into v_entries from ranked r;

  with aggregated as (
    select r.user_id, count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      coalesce(sum(r.wager), 0)::bigint as wagered,
      coalesce(sum(r.payout), 0)::bigint as payout,
      coalesce(sum(r.payout - r.wager), 0)::bigint as net,
      coalesce(max(r.payout), 0)::bigint as best_score,
      max(r.created_at) as updated_at
    from public.game_rounds r
    where r.game_key = v_key and (v_since is null or r.created_at >= v_since)
    group by r.user_id
  ), ranked as (
    select row_number() over (order by a.net desc, a.best_score desc, a.wins desc, a.updated_at asc, a.user_id)::integer as position,
      a.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      a.plays, a.wins, a.wagered, a.payout, a.net, a.best_score, a.updated_at,
      a.user_id = v_user_id as is_me
    from aggregated a left join public.profiles p on p.id = a.user_id
  )
  select pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'plays', r.plays, 'wins', r.wins, 'wagered', r.wagered, 'payout', r.payout,
    'net', r.net, 'best_score', r.best_score, 'updated_at', r.updated_at, 'is_me', r.is_me
  ) into v_me from ranked r where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'game_key', v_key, 'period', v_period,
    'entries', v_entries, 'my_entry', coalesce(v_me, 'null'::jsonb)
  );
end;
$$;
revoke all on function public.get_game_leaderboard(text, text) from public, anon, authenticated;
grant execute on function public.get_game_leaderboard(text, text) to authenticated;

create or replace function public.get_dino_leaderboard(p_period text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_period text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_period, 'all')));
  v_since timestamptz;
  v_entries jsonb;
  v_me jsonb;
begin
  if v_period not in ('today', 'week', 'all') then raise exception 'invalid_period'; end if;
  v_since := case v_period
    when 'today' then current_date::timestamptz
    when 'week' then pg_catalog.date_trunc('week', clock_timestamp())
    else null
  end;
  with best as (
    select distinct on (d.user_id) d.user_id, d.score, d.reward_total, d.finished_at
    from public.dino_run_sessions d
    where d.status = 'finished' and d.finished_at is not null
      and (v_since is null or d.finished_at >= v_since)
    order by d.user_id, d.score desc, d.finished_at asc
  ), ranked as (
    select row_number() over (order by b.score desc, b.finished_at asc, b.user_id)::integer as position,
      b.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      b.score, b.reward_total, b.finished_at, b.user_id = v_user_id as is_me
    from best b left join public.profiles p on p.id = b.user_id
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'score', r.score, 'reward_total', r.reward_total, 'finished_at', r.finished_at,
    'is_me', r.is_me
  ) order by r.position) filter (where r.position <= 10), '[]'::jsonb)
  into v_entries from ranked r;

  with best as (
    select distinct on (d.user_id) d.user_id, d.score, d.reward_total, d.finished_at
    from public.dino_run_sessions d
    where d.status = 'finished' and d.finished_at is not null
      and (v_since is null or d.finished_at >= v_since)
    order by d.user_id, d.score desc, d.finished_at asc
  ), ranked as (
    select row_number() over (order by b.score desc, b.finished_at asc, b.user_id)::integer as position,
      b.user_id, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      b.score, b.reward_total, b.finished_at, b.user_id = v_user_id as is_me
    from best b left join public.profiles p on p.id = b.user_id
  )
  select pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'score', r.score, 'reward_total', r.reward_total, 'finished_at', r.finished_at,
    'is_me', r.is_me
  ) into v_me from ranked r where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'period', v_period, 'entries', v_entries,
    'my_entry', coalesce(v_me, 'null'::jsonb)
  );
end;
$$;
revoke all on function public.get_dino_leaderboard(text) from public, anon, authenticated;
grant execute on function public.get_dino_leaderboard(text) to authenticated;

-- Monthly seasons with server-computed points and claimable podium rewards.
create table if not exists public.seasons (
  id uuid primary key default extensions.gen_random_uuid(),
  slug text not null unique,
  name text not null check (pg_catalog.char_length(name) between 3 and 60),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reward_first bigint not null default 300 check (reward_first >= 0),
  reward_second bigint not null default 150 check (reward_second >= 0),
  reward_third bigint not null default 75 check (reward_third >= 0),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create table if not exists public.season_rewards (
  season_id uuid not null references public.seasons(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  final_rank integer not null check (final_rank between 1 and 3),
  amount bigint not null check (amount > 0),
  transaction_id uuid not null references public.transactions(id),
  claimed_at timestamptz not null default now(),
  primary key (season_id, user_id)
);
alter table public.seasons enable row level security;
alter table public.seasons force row level security;
alter table public.season_rewards enable row level security;
alter table public.season_rewards force row level security;
revoke all on table public.seasons, public.season_rewards from public, anon, authenticated;
grant select on table public.seasons, public.season_rewards to authenticated;
drop policy if exists seasons_read_authenticated on public.seasons;
create policy seasons_read_authenticated on public.seasons
for select to authenticated using (true);
drop policy if exists season_rewards_read_own on public.season_rewards;
create policy season_rewards_read_own on public.season_rewards
for select to authenticated using ((select auth.uid()) = user_id);

create or replace function private.ensure_current_season()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz := pg_catalog.date_trunc('month', clock_timestamp());
  v_end timestamptz := pg_catalog.date_trunc('month', clock_timestamp()) + interval '1 month';
  v_id uuid;
begin
  insert into public.seasons (slug, name, starts_at, ends_at)
  values (
    'campus-' || pg_catalog.to_char(v_start, 'YYYY-MM'),
    'Campus Saison ' || pg_catalog.to_char(v_start, 'MM/YYYY'),
    v_start, v_end
  )
  on conflict (slug) do update set name = excluded.name
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.ensure_current_season() from public, anon, authenticated;

create or replace function public.get_season_state()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_season_id uuid := private.ensure_current_season();
  v_season public.seasons%rowtype;
  v_entries jsonb;
  v_me jsonb;
begin
  select s.* into v_season from public.seasons s where s.id = v_season_id;
  with scores as (
    select r.user_id,
      count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      coalesce(sum(r.payout - r.wager), 0)::bigint as net,
      (count(*) + count(*) filter (where r.payout > r.wager) * 20
        + greatest(coalesce(sum(r.payout - r.wager), 0), 0) / 10)::bigint as points
    from public.game_rounds r
    where r.created_at >= v_season.starts_at and r.created_at < v_season.ends_at
    group by r.user_id
  ), ranked as (
    select row_number() over (order by s.points desc, s.wins desc, s.plays desc, s.user_id)::integer as position,
      s.*, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      s.user_id = v_user_id as is_me
    from scores s left join public.profiles p on p.id = s.user_id
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'points', r.points, 'plays', r.plays, 'wins', r.wins, 'net', r.net, 'is_me', r.is_me
  ) order by r.position) filter (where r.position <= 10), '[]'::jsonb)
  into v_entries from ranked r;

  with scores as (
    select r.user_id, count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      coalesce(sum(r.payout - r.wager), 0)::bigint as net,
      (count(*) + count(*) filter (where r.payout > r.wager) * 20
        + greatest(coalesce(sum(r.payout - r.wager), 0), 0) / 10)::bigint as points
    from public.game_rounds r
    where r.created_at >= v_season.starts_at and r.created_at < v_season.ends_at
    group by r.user_id
  ), ranked as (
    select row_number() over (order by s.points desc, s.wins desc, s.plays desc, s.user_id)::integer as position,
      s.*, coalesce(nullif(p.username, ''), nullif(p.display_name, ''), 'GIBB Spieler') as username,
      s.user_id = v_user_id as is_me
    from scores s left join public.profiles p on p.id = s.user_id
  )
  select pg_catalog.jsonb_build_object(
    'rank', r.position, 'user_id', r.user_id, 'username', r.username,
    'points', r.points, 'plays', r.plays, 'wins', r.wins, 'net', r.net, 'is_me', r.is_me
  ) into v_me from ranked r where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'season', pg_catalog.jsonb_build_object(
      'id', v_season.id, 'name', v_season.name,
      'starts_at', v_season.starts_at, 'ends_at', v_season.ends_at,
      'rewards', pg_catalog.jsonb_build_array(v_season.reward_first, v_season.reward_second, v_season.reward_third)
    ),
    'entries', v_entries,
    'my_entry', coalesce(v_me, 'null'::jsonb)
  );
end;
$$;

create or replace function public.claim_previous_season_reward()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_season public.seasons%rowtype;
  v_rank integer;
  v_amount bigint;
  v_wallet_id uuid;
  v_transaction_id uuid;
begin
  select s.* into v_season from public.seasons s
  where s.ends_at <= clock_timestamp()
  order by s.ends_at desc limit 1;
  if v_season.id is null then raise exception 'no_finished_season'; end if;
  if exists (select 1 from public.season_rewards r where r.season_id = v_season.id and r.user_id = v_user_id) then
    raise exception 'season_reward_already_claimed';
  end if;

  with scores as (
    select r.user_id, count(*)::bigint as plays,
      count(*) filter (where r.payout > r.wager)::bigint as wins,
      (count(*) + count(*) filter (where r.payout > r.wager) * 20
        + greatest(coalesce(sum(r.payout - r.wager), 0), 0) / 10)::bigint as points
    from public.game_rounds r
    where r.created_at >= v_season.starts_at and r.created_at < v_season.ends_at
    group by r.user_id
  ), ranked as (
    select row_number() over (order by s.points desc, s.wins desc, s.plays desc, s.user_id)::integer as position,
      s.user_id from scores s
  )
  select r.position into v_rank from ranked r where r.user_id = v_user_id;
  if v_rank is null or v_rank > 3 then raise exception 'no_season_reward'; end if;
  v_amount := case v_rank when 1 then v_season.reward_first when 2 then v_season.reward_second else v_season.reward_third end;
  if v_amount <= 0 then raise exception 'no_season_reward'; end if;

  select w.id into v_wallet_id from public.wallets w
  where w.user_id = v_user_id and w.status = 'active' for update;
  if v_wallet_id is null then raise exception 'wallet_locked'; end if;
  if exists (select 1 from public.season_rewards r where r.season_id = v_season.id and r.user_id = v_user_id) then
    raise exception 'season_reward_already_claimed';
  end if;
  update public.wallets set balance = balance + v_amount where id = v_wallet_id;
  v_transaction_id := private.append_transaction(null, v_user_id, v_amount, 'CHALLENGE_REWARD', v_season.name);
  insert into public.season_rewards (season_id, user_id, final_rank, amount, transaction_id)
  values (v_season.id, v_user_id, v_rank, v_amount, v_transaction_id);
  return pg_catalog.jsonb_build_object('ok', true, 'rank', v_rank, 'reward', v_amount, 'season', v_season.name);
end;
$$;

revoke all on function public.get_season_state() from public, anon, authenticated;
grant execute on function public.get_season_state() to authenticated;
revoke all on function public.claim_previous_season_reward() from public, anon, authenticated;
grant execute on function public.claim_previous_season_reward() to authenticated;

-- Timed account locks. Auth bans are synchronized by the admin Edge Function.
alter table public.wallets
  add column if not exists locked_until timestamptz,
  add column if not exists lock_reason text;
alter table public.wallets drop constraint if exists wallets_lock_reason_check;
alter table public.wallets add constraint wallets_lock_reason_check
  check (lock_reason is null or pg_catalog.char_length(lock_reason) <= 120);

create or replace function public.refresh_my_wallet_status()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_wallet public.wallets%rowtype;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  update public.wallets
  set status = 'active', locked_until = null, lock_reason = null, updated_at = now()
  where user_id = v_user_id and status = 'locked'
    and locked_until is not null and locked_until <= clock_timestamp();
  select w.* into v_wallet from public.wallets w where w.user_id = v_user_id;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  return pg_catalog.jsonb_build_object(
    'status', v_wallet.status, 'locked_until', v_wallet.locked_until, 'lock_reason', v_wallet.lock_reason
  );
end;
$$;

create or replace function public.admin_list_account_locks()
returns table (user_id uuid, locked_until timestamptz, lock_reason text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return query select w.user_id, w.locked_until, w.lock_reason from public.wallets w;
end;
$$;

create or replace function public.admin_list_audit_logs(p_limit integer default 100)
returns table (
  id uuid,
  admin_user_id uuid,
  admin_username text,
  target_user_id uuid,
  target_username text,
  action text,
  old_value jsonb,
  new_value jsonb,
  reason text,
  metadata jsonb,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return query
  select l.id, l.admin_user_id, a.username, l.target_user_id,
    t.username, l.action, l.old_value, l.new_value, l.reason,
    l.metadata, l.created_at
  from public.admin_audit_logs l
  join public.profiles a on a.id = l.admin_user_id
  left join public.profiles t on t.id = l.target_user_id
  order by l.created_at desc, l.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
end;
$$;

create or replace function public.admin_apply_wallet_status_v2(
  p_admin_user_id uuid,
  p_target_user_id uuid,
  p_status text,
  p_reason text,
  p_locked_until timestamptz
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_role text;
  v_admin_wallet_status text;
  v_target_role text;
  v_is_primary_owner boolean := false;
  v_wallet public.wallets%rowtype;
  v_reason text := coalesce(nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''), 'Administrative Sicherheitsmassnahme');
begin
  if p_admin_user_id is null then raise exception 'admin_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_status not in ('active', 'locked') then raise exception 'invalid_wallet_status'; end if;
  if p_target_user_id = p_admin_user_id and p_status = 'locked' then raise exception 'cannot_lock_own_account'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;
  if p_status = 'locked' and p_locked_until is not null and p_locked_until <= clock_timestamp() then
    raise exception 'invalid_lock_duration';
  end if;

  select p.role, w.status into v_admin_role, v_admin_wallet_status
  from public.profiles p join public.wallets w on w.user_id = p.id
  where p.id = p_admin_user_id;
  if coalesce(v_admin_role, '') not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  if coalesce(v_admin_wallet_status, '') <> 'active' then raise exception 'account_locked'; end if;
  v_is_primary_owner := private.is_primary_owner(p_admin_user_id);
  if v_admin_role = 'super_admin' and not v_is_primary_owner then raise exception 'primary_owner_required'; end if;

  select p.role into v_target_role from public.profiles p where p.id = p_target_user_id;
  if v_target_role is null then raise exception 'user_not_found'; end if;
  if v_target_role = 'super_admin' and not v_is_primary_owner then raise exception 'cannot_modify_super_admin'; end if;
  if v_admin_role = 'admin' and v_target_role = 'admin' then raise exception 'cannot_modify_peer_admin'; end if;
  select w.* into v_wallet from public.wallets w where w.user_id = p_target_user_id for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;

  update public.wallets
  set status = p_status,
      locked_until = case when p_status = 'locked' then p_locked_until else null end,
      lock_reason = case when p_status = 'locked' then v_reason else null end,
      updated_at = now()
  where id = v_wallet.id;

  perform private.write_admin_audit(
    p_admin_user_id, p_target_user_id,
    case when p_status = 'locked' then 'ACCOUNT_LOCKED' else 'ACCOUNT_UNLOCKED' end,
    pg_catalog.jsonb_build_object('status', v_wallet.status, 'locked_until', v_wallet.locked_until),
    pg_catalog.jsonb_build_object('status', p_status, 'locked_until', p_locked_until),
    v_reason,
    pg_catalog.jsonb_build_object('auth_synced', true, 'primary_owner', v_is_primary_owner, 'timed', p_locked_until is not null)
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id, 'account_status',
    case when p_status = 'locked' then 'Konto gesperrt' else 'Konto freigeschaltet' end,
    case when p_status = 'locked'
      then 'Dein Konto wurde gesperrt' || case when p_locked_until is null then '.' else ' bis ' || pg_catalog.to_char(p_locked_until, 'DD.MM.YYYY HH24:MI') || '.' end
      else 'Dein Konto wurde wieder freigeschaltet.' end
  );
  return p_status;
end;
$$;

revoke all on function public.refresh_my_wallet_status() from public, anon, authenticated;
grant execute on function public.refresh_my_wallet_status() to authenticated;
revoke all on function public.admin_list_account_locks() from public, anon, authenticated;
grant execute on function public.admin_list_account_locks() to authenticated;
revoke all on function public.admin_list_audit_logs(integer) from public, anon, authenticated;
grant execute on function public.admin_list_audit_logs(integer) to authenticated;
revoke all on function public.admin_apply_wallet_status_v2(uuid, uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_apply_wallet_status_v2(uuid, uuid, text, text, timestamptz) to service_role;

notify pgrst, 'reload schema';
