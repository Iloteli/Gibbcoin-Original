-- GIBB Coin: neues Supabase einrichten – Teil 3 von 5
-- Im SQL Editor des NEUEN Projekts der Reihe nach ausführen (Teil 1, dann 2, …). Jeden Teil nur einmal.

-- ===================== 20260908063951_community_rewards_safety_upgrade.sql =====================
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


-- ===================== 20260908090000_harden_security_controls.sql =====================
-- Close legacy transfer paths and raise the security baseline for group invites,
-- account deletion, MFA and administrative PIN attempts.

-- The live database may already have removed this legacy RPC.
do $$ begin
  if to_regprocedure('public.transfer_gibb(uuid,bigint)') is not null then
    revoke all on function public.transfer_gibb(uuid, bigint) from public, anon, authenticated;
  end if;
end $$;
drop function if exists public.transfer_gibb(uuid, bigint);

alter table public.group_wallets
  drop constraint if exists group_wallets_join_code_check;

update public.group_wallets
set join_code = upper(encode(extensions.gen_random_bytes(16), 'hex'))
where join_code !~ '^[A-F0-9]{32}$';

alter table public.group_wallets
  add constraint group_wallets_join_code_check
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
begin
  p_name := pg_catalog.btrim(coalesce(p_name, ''));
  p_description := nullif(pg_catalog.btrim(coalesce(p_description, '')), '');
  if pg_catalog.char_length(p_name) not between 3 and 60 then raise exception 'invalid_group_name'; end if;
  if pg_catalog.char_length(coalesce(p_description, '')) > 160 then raise exception 'description_too_long'; end if;
  if (select pg_catalog.count(*) from public.group_wallets g where g.owner_user_id = v_user_id) >= 10 then
    raise exception 'group_limit_reached';
  end if;

  loop
    v_join_code := upper(encode(extensions.gen_random_bytes(16), 'hex'));
    exit when not exists (select 1 from public.group_wallets g where g.join_code = v_join_code);
  end loop;

  insert into public.group_wallets(name, description, owner_user_id, join_code)
  values (p_name, p_description, v_user_id, v_join_code)
  returning id into v_group_id;

  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'owner');

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
  v_code text := upper(pg_catalog.btrim(coalesce(p_join_code, '')));
begin
  if v_code !~ '^[A-F0-9]{32}$' then raise exception 'invalid_join_code'; end if;
  if (select pg_catalog.count(*) from public.group_wallet_members m where m.user_id = v_user_id) >= 30 then
    raise exception 'membership_limit_reached';
  end if;
  select g.id into v_group_id from public.group_wallets g where g.join_code = v_code;
  if v_group_id is null then raise exception 'group_not_found'; end if;
  insert into public.group_wallet_members(group_id, user_id, role)
  values (v_group_id, v_user_id, 'member')
  on conflict (group_id, user_id) do nothing;
  return v_group_id;
end;
$$;

create or replace function private.assert_mfa_if_enrolled(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'authentication_required';
  end if;
  select p.role into v_role from public.profiles p where p.id = p_user_id;
  if v_role in ('admin', 'super_admin')
     and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
end;
$$;

create or replace function private.check_admin_pin(p_admin_user_id uuid, p_pin text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pin private.admin_pins%rowtype;
  v_failed_attempts smallint;
begin
  select ap.* into v_pin from private.admin_pins ap
  where ap.admin_user_id = p_admin_user_id for update;
  if v_pin.admin_user_id is null then return 'not_set'; end if;
  if v_pin.locked_until is not null and v_pin.locked_until > now() then return 'locked'; end if;

  if coalesce(p_pin, '') ~ '^[0-9]{4}$'
     and extensions.crypt(coalesce(p_pin, ''), v_pin.pin_hash) = v_pin.pin_hash then
    update private.admin_pins set failed_attempts = 0, locked_until = null, updated_at = now()
    where admin_user_id = p_admin_user_id;
    return 'ok';
  end if;

  v_failed_attempts := least(v_pin.failed_attempts + 1, 5);
  update private.admin_pins
  set failed_attempts = v_failed_attempts,
      locked_until = case when v_failed_attempts >= 5 then now() + interval '1 hour' else null end,
      updated_at = now()
  where admin_user_id = p_admin_user_id;
  return case when v_failed_attempts >= 5 then 'locked' else 'invalid' end;
end;
$$;

create or replace function private.anonymize_deleted_group_entries()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.group_wallet_entries
  set actor_label = case when actor_user_id = old.id then 'Gelöschtes Konto' else actor_label end,
      recipient_label = case when recipient_user_id = old.id then 'Gelöschtes Konto' else recipient_label end
  where actor_user_id = old.id or recipient_user_id = old.id;
  return old;
end;
$$;

revoke all on function private.anonymize_deleted_group_entries() from public, anon, authenticated;
drop trigger if exists before_auth_user_delete_anonymize_group_entries on auth.users;
create trigger before_auth_user_delete_anonymize_group_entries
before delete on auth.users
for each row execute procedure private.anonymize_deleted_group_entries();


-- ===================== 20260909081539_admin_global_game_limits_and_public_profiles.sql =====================
-- Global, server-enforced game limits managed by Admins and Owners.
create table if not exists private.global_game_limits (
  singleton boolean primary key default true check (singleton),
  max_wager bigint check (max_wager is null or max_wager between 1 and 1000000000000),
  daily_loss_limit bigint check (daily_loss_limit is null or daily_loss_limit between 1 and 1000000000000),
  cooldown_seconds integer not null default 0 check (cooldown_seconds between 0 and 3600),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into private.global_game_limits (singleton)
values (true)
on conflict (singleton) do nothing;

alter table private.global_game_limits enable row level security;
alter table private.global_game_limits force row level security;
revoke all on table private.global_game_limits from public, anon, authenticated;

create or replace function public.get_global_game_limits()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_admin();
  v_limits private.global_game_limits%rowtype;
begin
  select g.* into v_limits
  from private.global_game_limits g
  where g.singleton;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'max_wager', v_limits.max_wager,
    'daily_loss_limit', v_limits.daily_loss_limit,
    'cooldown_seconds', coalesce(v_limits.cooldown_seconds, 0),
    'updated_at', v_limits.updated_at
  );
end;
$$;

create or replace function public.admin_set_global_game_limits(
  p_max_wager bigint,
  p_daily_loss_limit bigint,
  p_cooldown_seconds integer,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := private.require_admin();
  v_pin_status text;
  v_old private.global_game_limits%rowtype;
begin
  if p_max_wager is not null and p_max_wager not between 1 and 1000000000000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_global_max_wager');
  end if;
  if p_daily_loss_limit is not null and p_daily_loss_limit not between 1 and 1000000000000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_global_daily_loss_limit');
  end if;
  if coalesce(p_cooldown_seconds, 0) not between 0 and 3600 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_global_cooldown');
  end if;

  v_pin_status := private.check_admin_pin(v_actor, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select g.* into v_old
  from private.global_game_limits g
  where g.singleton
  for update;

  update private.global_game_limits
  set max_wager = p_max_wager,
      daily_loss_limit = p_daily_loss_limit,
      cooldown_seconds = coalesce(p_cooldown_seconds, 0),
      updated_by = v_actor,
      updated_at = pg_catalog.clock_timestamp()
  where singleton;

  if v_old.max_wager is distinct from p_max_wager
     or v_old.daily_loss_limit is distinct from p_daily_loss_limit
     or v_old.cooldown_seconds is distinct from coalesce(p_cooldown_seconds, 0) then
    perform private.write_admin_audit(
      v_actor,
      null,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', 'global_limits',
        'max_wager', v_old.max_wager,
        'daily_loss_limit', v_old.daily_loss_limit,
        'cooldown_seconds', v_old.cooldown_seconds
      ),
      pg_catalog.jsonb_build_object(
        'game_key', 'global_limits',
        'max_wager', p_max_wager,
        'daily_loss_limit', p_daily_loss_limit,
        'cooldown_seconds', coalesce(p_cooldown_seconds, 0)
      ),
      'Globale Spielgrenzen geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'max_wager', p_max_wager,
    'daily_loss_limit', p_daily_loss_limit,
    'cooldown_seconds', coalesce(p_cooldown_seconds, 0)
  );
end;
$$;

create or replace function private.prepare_fair_game_round()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_safety public.player_safety_settings%rowtype;
  v_global private.global_game_limits%rowtype;
  v_daily_loss bigint := 0;
  v_loss_increment bigint := greatest(new.wager - new.payout, 0);
  v_effective_cooldown integer := 0;
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

  insert into public.player_safety_settings (user_id)
  values (new.user_id)
  on conflict (user_id) do nothing;

  select s.* into v_safety
  from public.player_safety_settings s
  where s.user_id = new.user_id
  for update;

  select g.* into v_global
  from private.global_game_limits g
  where g.singleton;

  if v_safety.break_until is not null and v_safety.break_until > pg_catalog.clock_timestamp() then
    raise exception 'player_break_active';
  end if;
  if v_global.max_wager is not null and new.wager > v_global.max_wager then
    raise exception 'global_wager_limit';
  end if;
  if v_safety.max_wager is not null and new.wager > v_safety.max_wager then
    raise exception 'player_wager_limit';
  end if;

  v_effective_cooldown := greatest(
    coalesce(v_global.cooldown_seconds, 0),
    coalesce(v_safety.cooldown_seconds, 0)
  );
  if v_effective_cooldown > 0
     and v_safety.last_round_at is not null
     and v_safety.last_round_at + pg_catalog.make_interval(secs => v_effective_cooldown) > pg_catalog.clock_timestamp()
  then
    raise exception 'global_or_player_cooldown';
  end if;

  if v_global.daily_loss_limit is not null or v_safety.daily_loss_limit is not null then
    select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint into v_daily_loss
    from public.game_rounds r
    where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;
  end if;
  if v_global.daily_loss_limit is not null
     and v_daily_loss + v_loss_increment > v_global.daily_loss_limit then
    raise exception 'global_daily_loss_limit';
  end if;
  if v_safety.daily_loss_limit is not null
     and v_daily_loss + v_loss_increment > v_safety.daily_loss_limit then
    raise exception 'player_daily_loss_limit';
  end if;

  update public.player_safety_settings
  set last_round_at = pg_catalog.clock_timestamp(), updated_at = pg_catalog.clock_timestamp()
  where user_id = new.user_id;

  new.fairness_nonce := coalesce(new.fairness_nonce, extensions.gen_random_uuid());
  v_payload := pg_catalog.concat_ws('|',
    new.id::text, new.user_id::text, new.game_key, coalesce(new.choice, ''),
    new.wager::text, new.payout::text, new.result::text, new.fairness_nonce::text
  );
  new.fairness_hash := pg_catalog.encode(extensions.digest(v_payload, 'sha256'), 'hex');
  return new;
end;
$$;

create or replace function private.enforce_session_safety()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_safety public.player_safety_settings%rowtype;
  v_global private.global_game_limits%rowtype;
  v_daily_loss bigint := 0;
  v_effective_cooldown integer := 0;
begin
  insert into public.player_safety_settings (user_id)
  values (new.user_id)
  on conflict (user_id) do nothing;

  select s.* into v_safety
  from public.player_safety_settings s
  where s.user_id = new.user_id
  for update;

  select g.* into v_global
  from private.global_game_limits g
  where g.singleton;

  if v_safety.break_until is not null and v_safety.break_until > pg_catalog.clock_timestamp() then
    raise exception 'player_break_active';
  end if;
  if v_global.max_wager is not null and new.wager > v_global.max_wager then
    raise exception 'global_wager_limit';
  end if;
  if v_safety.max_wager is not null and new.wager > v_safety.max_wager then
    raise exception 'player_wager_limit';
  end if;

  v_effective_cooldown := greatest(
    coalesce(v_global.cooldown_seconds, 0),
    coalesce(v_safety.cooldown_seconds, 0)
  );
  if v_effective_cooldown > 0
     and v_safety.last_round_at is not null
     and v_safety.last_round_at + pg_catalog.make_interval(secs => v_effective_cooldown) > pg_catalog.clock_timestamp()
  then
    raise exception 'global_or_player_cooldown';
  end if;

  if v_global.daily_loss_limit is not null or v_safety.daily_loss_limit is not null then
    select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint into v_daily_loss
    from public.game_rounds r
    where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;
  end if;
  if v_global.daily_loss_limit is not null
     and v_daily_loss + new.wager > v_global.daily_loss_limit then
    raise exception 'global_daily_loss_limit';
  end if;
  if v_safety.daily_loss_limit is not null
     and v_daily_loss + new.wager > v_safety.daily_loss_limit then
    raise exception 'player_daily_loss_limit';
  end if;

  update public.player_safety_settings
  set last_round_at = pg_catalog.clock_timestamp(), updated_at = pg_catalog.clock_timestamp()
  where user_id = new.user_id;
  return new;
end;
$$;

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
  v_global private.global_game_limits%rowtype;
  v_daily_loss bigint := 0;
begin
  select s.* into v_settings
  from public.player_safety_settings s
  where s.user_id = v_user_id;

  select g.* into v_global
  from private.global_game_limits g
  where g.singleton;

  select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint into v_daily_loss
  from public.game_rounds r
  where r.user_id = v_user_id and r.created_at >= current_date::timestamptz;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'max_wager', v_settings.max_wager,
    'daily_loss_limit', v_settings.daily_loss_limit,
    'cooldown_seconds', coalesce(v_settings.cooldown_seconds, 0),
    'global_max_wager', v_global.max_wager,
    'global_daily_loss_limit', v_global.daily_loss_limit,
    'global_cooldown_seconds', coalesce(v_global.cooldown_seconds, 0),
    'effective_max_wager', case
      when v_settings.max_wager is null and v_global.max_wager is null then null
      else least(coalesce(v_settings.max_wager, 1000000000000), coalesce(v_global.max_wager, 1000000000000))
    end,
    'effective_daily_loss_limit', case
      when v_settings.daily_loss_limit is null and v_global.daily_loss_limit is null then null
      else least(coalesce(v_settings.daily_loss_limit, 1000000000000), coalesce(v_global.daily_loss_limit, 1000000000000))
    end,
    'effective_cooldown_seconds', greatest(
      coalesce(v_settings.cooldown_seconds, 0),
      coalesce(v_global.cooldown_seconds, 0)
    ),
    'daily_loss', v_daily_loss,
    'loss_today', v_daily_loss,
    'break_until', v_settings.break_until,
    'last_round_at', v_settings.last_round_at
  );
end;
$$;

-- Authenticated users may inspect a deliberately small, public profile card.
-- Email addresses, authentication metadata, PINs and other private fields are
-- intentionally never part of this result.
create or replace function public.get_public_user_profile(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_viewer uuid := private.require_active_user();
  v_profile public.profiles%rowtype;
  v_balance bigint := 0;
  v_dino_best integer := 0;
begin
  if p_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_user');
  end if;

  select p.* into v_profile
  from public.profiles p
  where p.id = p_user_id;

  if v_profile.id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'profile_not_found');
  end if;

  select coalesce(w.balance, 0) into v_balance
  from public.wallets w
  where w.user_id = p_user_id;

  select coalesce(max(d.score), 0)::integer into v_dino_best
  from public.dino_run_sessions d
  where d.user_id = p_user_id and d.status = 'finished';

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'user_id', v_profile.id,
    'username', coalesce(nullif(v_profile.username, ''), 'gibb-user'),
    'display_name', v_profile.display_name,
    'bio', v_profile.bio,
    'profile_color', v_profile.profile_color,
    'avatar_url', v_profile.avatar_url,
    'equipped_title', v_profile.equipped_title,
    'role', v_profile.role,
    'joined_at', v_profile.created_at,
    'balance', v_balance,
    'dino_best_score', v_dino_best,
    'is_me', v_profile.id = v_viewer
  );
end;
$$;

revoke all on function public.get_global_game_limits() from public, anon, authenticated;
grant execute on function public.get_global_game_limits() to authenticated;
revoke all on function public.admin_set_global_game_limits(bigint, bigint, integer, text) from public, anon, authenticated;
grant execute on function public.admin_set_global_game_limits(bigint, bigint, integer, text) to authenticated;
revoke all on function private.prepare_fair_game_round() from public, anon, authenticated;
revoke all on function private.enforce_session_safety() from public, anon, authenticated;
revoke all on function public.get_my_player_safety() from public, anon, authenticated;
grant execute on function public.get_my_player_safety() to authenticated;
revoke all on function public.get_public_user_profile(uuid) from public, anon, authenticated;
grant execute on function public.get_public_user_profile(uuid) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20260909120000_add_home_wallet_stats_reset.sql =====================
-- Jeder Benutzer darf die Plus/Minus-Statistik auf der Home-Ansicht selbst
-- zurücksetzen. Der Reset merkt sich nur einen Zeitpunkt: Guthaben,
-- Transaktionsverlauf und Hash-Kette bleiben unverändert.
create table if not exists private.wallet_stats_resets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reset_at timestamptz not null,
  updated_at timestamptz not null default now()
);

revoke all on table private.wallet_stats_resets
from public, anon, authenticated;

create or replace function public.my_wallet_stats_reset()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_since timestamptz;
begin
  select r.reset_at into v_since
  from private.wallet_stats_resets r
  where r.user_id = v_user_id;

  return pg_catalog.jsonb_build_object('ok', true, 'since', v_since);
end;
$$;

create or replace function public.reset_my_wallet_stats()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_reset_at timestamptz := pg_catalog.clock_timestamp();
begin
  insert into private.wallet_stats_resets (user_id, reset_at, updated_at)
  values (v_user_id, v_reset_at, v_reset_at)
  on conflict (user_id) do update
  set reset_at = excluded.reset_at,
      updated_at = excluded.updated_at;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'since', v_reset_at,
    'ledger_preserved', true,
    'balances_preserved', true
  );
end;
$$;

revoke all on function public.my_wallet_stats_reset()
from public, anon, authenticated;
grant execute on function public.my_wallet_stats_reset()
to authenticated;
revoke all on function public.reset_my_wallet_stats()
from public, anon, authenticated;
grant execute on function public.reset_my_wallet_stats()
to authenticated;


-- ===================== 20260909140000_allow_username_change.sql =====================
-- Jeder Benutzer darf seinen Benutzernamen selbst ändern. Es gelten dieselben
-- Regeln wie bei der Registrierung: Kleinbuchstaben, Ziffern, Punkt, Bindestrich
-- und Unterstrich, 3 bis 24 Zeichen, Beginn alphanumerisch. Die Eindeutigkeit
-- wird case-insensitiv geprüft und zusätzlich vom Unique-Index erzwungen.
-- Rollen, Guthaben und Transaktionen bleiben unberührt.
create or replace function public.set_my_username(p_username text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
  v_current text;
begin
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_username');
  end if;

  select p.username into v_current
  from public.profiles p
  where p.id = v_user_id;

  if v_current = v_username then
    return pg_catalog.jsonb_build_object('ok', true, 'username', v_username, 'changed', false);
  end if;

  if exists (
    select 1
    from public.profiles p
    where pg_catalog.lower(p.username) = v_username
      and p.id <> v_user_id
  ) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;

  update public.profiles
  set username = v_username,
      updated_at = now()
  where id = v_user_id;

  return pg_catalog.jsonb_build_object('ok', true, 'username', v_username, 'changed', true);
exception
  when unique_violation then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
end;
$$;

revoke all on function public.set_my_username(text)
from public, anon, authenticated;
grant execute on function public.set_my_username(text)
to authenticated;


-- ===================== 20260909160000_protect_named_accounts.sql =====================
-- Einzelne Konten können dauerhaft vor Bannen und Löschen geschützt werden.
-- Der Schutz hängt an der unveränderlichen User-ID, nicht am Benutzernamen:
-- Benutzernamen sind selbst änderbar und wären damit fälschbar.
--
-- Durchgesetzt wird der Schutz auf Datenbankebene, nicht in der Edge Function.
-- Damit greift er für jeden Weg: admin_apply_wallet_status, dessen v2-Variante,
-- direkte service_role-Updates und jede künftige Funktion.
create table if not exists private.protected_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null default 'Dauerhaft geschütztes Konto',
  added_at timestamptz not null default now()
);

revoke all on table private.protected_accounts
from public, anon, authenticated;

create or replace function private.is_protected_account(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.protected_accounts a
    where a.user_id = p_user_id
  );
$$;

revoke all on function private.is_protected_account(uuid)
from public, anon, authenticated;

-- Sperren verhindern: greift auf der Tabelle selbst, egal wer schreibt.
-- Entsperren bleibt jederzeit erlaubt.
create or replace function private.protect_account_from_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'locked'
     and old.status is distinct from 'locked'
     and private.is_protected_account(new.user_id)
  then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;
  return new;
end;
$$;

revoke all on function private.protect_account_from_ban()
from public, anon, authenticated;

drop trigger if exists protect_account_from_ban on public.wallets;
create trigger protect_account_from_ban
before update on public.wallets
for each row
execute function private.protect_account_from_ban();

-- Löschen verhindern: derselbe Trigger, der schon Owner-Konten schützt.
-- Die bestehenden Regeln bleiben unverändert, der Schutz kommt davor.
create or replace function private.protect_owner_auth_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target_role text;
  v_actor_user_id uuid;
  v_actor_role text;
  v_actor_status text;
  v_actor_is_primary_owner boolean := false;
begin
  if private.is_protected_account(old.id) then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;

  select p.role into v_target_role
  from public.profiles p
  where p.id = old.id;

  select a.actor_user_id, p.role, w.status
  into v_actor_user_id, v_actor_role, v_actor_status
  from private.account_deletion_authorizations a
  join public.profiles p on p.id = a.actor_user_id
  join public.wallets w on w.user_id = a.actor_user_id
  where a.target_user_id = old.id
    and a.expires_at >= now()
    and a.consumed_at is null;

  v_actor_is_primary_owner := private.is_primary_owner(v_actor_user_id);

  if v_actor_user_id is null
     or v_actor_user_id = old.id
     or coalesce(v_actor_role, '') not in ('admin', 'super_admin')
     or coalesce(v_actor_status, '') <> 'active'
     or (v_actor_role = 'super_admin' and not v_actor_is_primary_owner) then
    raise exception using errcode = '42501', message = 'account_deletion_not_authorized';
  end if;

  if v_target_role = 'super_admin' and not v_actor_is_primary_owner then
    raise exception using errcode = '42501', message = 'owner_account_is_protected';
  end if;

  if v_target_role = 'admin' and v_actor_role <> 'super_admin' then
    raise exception using errcode = '42501', message = 'admin_account_is_protected';
  end if;

  update private.account_deletion_authorizations
  set consumed_at = now()
  where target_user_id = old.id;

  return old;
end;
$$;

revoke all on function private.protect_owner_auth_deletion()
from public, anon, authenticated;

-- Die Schutzliste ist bewusst leer. Ein Konto wird geschützt, indem seine
-- User-ID hier eingetragen wird, zum Beispiel:
--   insert into private.protected_accounts (user_id, reason)
--   values ('00000000-0000-0000-0000-000000000000'::uuid, 'Ilja')
--   on conflict (user_id) do nothing;

notify pgrst, 'reload schema';


-- ===================== 20260909180000_make_admin_mfa_optional.sql =====================
-- Zwei-Faktor-Bestätigung ist nicht mehr zwingend. Bisher scheiterte jede
-- geschützte Adminaktion mit 'mfa_required', sobald ein Konto einen bestätigten
-- Faktor hatte und die Sitzung nur 'aal1' war. Wer sein Authenticator-Gerät
-- verlor, kam damit an keine Adminfunktion mehr heran.
--
-- Die Prüfung bleibt vollständig erhalten, ist aber jetzt über eine Einstellung
-- schaltbar und standardmässig aus. Einschalten mit:
--   update private.security_settings set enabled = true, updated_at = now()
--   where key = 'require_admin_mfa';
create table if not exists private.security_settings (
  key text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

revoke all on table private.security_settings
from public, anon, authenticated;

insert into private.security_settings (key, enabled)
values ('require_admin_mfa', false)
on conflict (key) do nothing;

create or replace function private.assert_mfa_if_enrolled(p_user_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Die Identitätsprüfung bleibt in jedem Fall bestehen.
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'authentication_required';
  end if;

  if not coalesce(
    (select s.enabled from private.security_settings s where s.key = 'require_admin_mfa'),
    false
  ) then
    return;
  end if;

  if exists (
    select 1
    from auth.mfa_factors f
    where f.user_id = p_user_id
      and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
end;
$$;

revoke all on function private.assert_mfa_if_enrolled(uuid)
from public, anon, authenticated;

notify pgrst, 'reload schema';


-- ===================== 20260912160000_add_admin_operations_registry.sql =====================
-- Central, private registry for the admin capabilities that are not account,
-- wallet, game-limit, report or audit-log controls.  The registry deliberately
-- stores configuration/status only; integrations must be wired separately.
create table if not exists private.admin_operations (
  operation_key text primary key check (operation_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  label text not null,
  description text not null,
  category text not null check (category in ('system','communication','data','moderation','economy','games')),
  status text not null default 'unavailable' check (status in ('enabled','disabled','configured','unavailable')),
  configuration jsonb not null default '{}'::jsonb check (jsonb_typeof(configuration) = 'object'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table private.admin_operations enable row level security;
alter table private.admin_operations force row level security;
revoke all on table private.admin_operations from public, anon, authenticated;

alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;
alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED',
      'STATS_RESET', 'ADMIN_OPERATION_CHANGED'
    )
  );

insert into private.admin_operations (operation_key, label, description, category)
values
 ('maintenance_mode','Wartungsmodus','Zugriff für Benutzer zeitweise pausieren.','system'),
 ('registration_policy','Registrierung','Neue Registrierungen und Einladungen steuern.','system'),
 ('login_policy','Anmelderichtlinie','Anmeldeversuche und Sitzungsdauer konfigurieren.','system'),
 ('password_policy','Passwortregeln','Mindestanforderungen für Passwörter dokumentieren.','system'),
 ('session_revocation','Sitzungen','Sitzungen eines Kontos serverseitig widerrufen.','system'),
 ('feature_flags','Funktionsschalter','Nicht-kritische Funktionen kontrolliert aktivieren.','system'),
 ('announcement_banner','Hinweisbanner','Einen globalen, zeitlich begrenzten Hinweis anzeigen.','communication'),
 ('email_delivery','E-Mail-Versand','E-Mail-Anbieter und Versandstatus verwalten.','communication'),
 ('push_delivery','Push-Versand','Push-Anbieter und Versandstatus verwalten.','communication'),
 ('notification_templates','Benachrichtigungsvorlagen','Vorlagen für Systemmeldungen verwalten.','communication'),
 ('backup_status','Backups','Status des externen Backup-Dienstes dokumentieren.','data'),
 ('restore_status','Wiederherstellung','Wiederherstellung nur als geprüften externen Vorgang markieren.','data'),
 ('data_export','Datenexport','Exportanfragen sicher erfassen und nachverfolgen.','data'),
 ('retention_policy','Aufbewahrung','Aufbewahrungsfristen und Löschläufe konfigurieren.','data'),
 ('privacy_requests','Datenschutzanfragen','Auskunfts- und Löschanfragen nachverfolgen.','data'),
 ('health_checks','Systemstatus','Abhängigkeiten und Erreichbarkeit prüfen.','system'),
 ('scheduled_jobs','Geplante Aufgaben','Geplante Wartungsaufgaben überwachen.','system'),
 ('api_integrations','API-Integrationen','Externe Integrationen mit Status und Endpunkt verwalten.','system'),
 ('webhook_delivery','Webhooks','Webhook-Zustellung und Wiederholungen überwachen.','system'),
 ('domain_allowlist','Domain-Freigaben','Erlaubte E-Mail-Domains konfigurieren.','system'),
 ('moderation_queue','Moderationswarteschlange','Gemeldete Inhalte zur Prüfung priorisieren.','moderation'),
 ('report_workflow','Meldungsworkflow','Zuständigkeiten und Fristen für Meldungen konfigurieren.','moderation'),
 ('user_impersonation','Supportzugriff','Supportzugriff nur als nicht aktivierte Konfiguration dokumentieren.','moderation'),
 ('economy_limits','Ökonomiegrenzen','Zusätzliche globale Wirtschaftsgrenzen konfigurieren.','economy'),
 ('refund_workflow','Erstattungen','Erstattungsanfragen kontrolliert erfassen.','economy'),
 ('purchase_reconciliation','Zahlungsabgleich','Zahlungsabgleich als externen Status überwachen.','economy'),
 ('leaderboard_moderation','Ranglistenmoderation','Auffällige Ranglisten-Einträge markieren.','games'),
 ('game_catalog','Spielekatalog','Spiele sichtbar oder vorübergehend deaktiviert konfigurieren.','games'),
 ('game_maintenance','Spielwartung','Spielwartungsfenster und Hinweise verwalten.','games'),
 ('fairness_monitoring','Fairness-Prüfung','Prüfstatus der serverseitigen Spielintegrität dokumentieren.','games')
on conflict (operation_key) do update set
 label = excluded.label, description = excluded.description, category = excluded.category;

create or replace function public.admin_list_operations()
returns table (
 operation_key text, label text, description text, category text,
 status text, configuration jsonb, updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.require_admin();
  return query
    select o.operation_key, o.label, o.description, o.category,
           o.status, o.configuration, o.updated_at
    from private.admin_operations o
    order by o.category, o.label;
end;
$$;

create or replace function public.admin_update_operation(
  p_operation_key text,
  p_status text,
  p_configuration jsonb default '{}'::jsonb,
  p_pin text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_actor uuid := private.require_admin();
  v_pin_status text;
  v_operation private.admin_operations%rowtype;
begin
  if p_operation_key is null or p_status not in ('enabled','disabled','configured','unavailable')
     or p_configuration is null or pg_catalog.jsonb_typeof(p_configuration) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_operation');
  end if;
  if pg_catalog.char_length(p_operation_key) > 64 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_operation');
  end if;
  v_pin_status := private.check_admin_pin(v_actor, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;
  select * into v_operation from private.admin_operations
    where operation_key = p_operation_key for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'operation_not_found');
  end if;
  update private.admin_operations
    set status = p_status, configuration = p_configuration,
        updated_by = v_actor, updated_at = pg_catalog.clock_timestamp()
    where operation_key = p_operation_key;
  if v_operation.status is distinct from p_status
     or v_operation.configuration is distinct from p_configuration then
    perform private.write_admin_audit(
      v_actor, null, 'ADMIN_OPERATION_CHANGED',
      pg_catalog.jsonb_build_object('operation_key', p_operation_key,
        'status', v_operation.status, 'configuration', v_operation.configuration),
      pg_catalog.jsonb_build_object('operation_key', p_operation_key,
        'status', p_status, 'configuration', p_configuration),
      'Admin-Operation geändert'
    );
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'operation_key', p_operation_key,
    'status', p_status, 'configuration', p_configuration);
end;
$$;

revoke all on function public.admin_list_operations() from public, anon;
grant execute on function public.admin_list_operations() to authenticated;
revoke all on function public.admin_update_operation(text, text, jsonb, text) from public, anon;
grant execute on function public.admin_update_operation(text, text, jsonb, text) to authenticated;


-- ===================== 20260912163000_add_admin_control_center.sql =====================
-- First-party administration controls.  External delivery (mail, push,
-- backups and impersonation) remains deliberately outside this migration.
create table if not exists private.admin_control_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb check (jsonb_typeof(value) = 'object'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table private.admin_control_settings enable row level security;
alter table private.admin_control_settings force row level security;
revoke all on table private.admin_control_settings from public, anon, authenticated;
insert into private.admin_control_settings(key, value) values
 ('maintenance', '{"enabled":false,"message":"Kurze Wartung – bitte versuche es später erneut.","until":null}'::jsonb),
 ('announcement', '{"enabled":false,"title":"","message":"","until":null}'::jsonb),
 ('health', '{"last_check_at":null,"status":"unknown"}'::jsonb)
on conflict (key) do nothing;

create table if not exists private.admin_user_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  daily_transfer_limit bigint check (daily_transfer_limit is null or daily_transfer_limit between 1 and 1000000000),
  daily_game_limit bigint check (daily_game_limit is null or daily_game_limit between 1 and 1000000000),
  max_transfer bigint check (max_transfer is null or max_transfer between 1 and 1000000000),
  updated_by uuid references auth.users(id) on delete set null, updated_at timestamptz not null default now()
);
create table if not exists private.admin_group_limits (
  group_id uuid primary key references public.group_wallets(id) on delete cascade,
  daily_limit bigint check (daily_limit is null or daily_limit between 1 and 1000000000),
  max_entry bigint check (max_entry is null or max_entry between 1 and 1000000000),
  updated_by uuid references auth.users(id) on delete set null, updated_at timestamptz not null default now()
);
alter table private.admin_user_limits enable row level security;
alter table private.admin_user_limits force row level security;
alter table private.admin_group_limits enable row level security;
alter table private.admin_group_limits force row level security;
revoke all on table private.admin_user_limits, private.admin_group_limits from public, anon, authenticated;

create table if not exists public.admin_classes (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  school_year text not null default '' check (char_length(school_year) <= 30),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.admin_class_members (
  class_id uuid references public.admin_classes(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  primary key (class_id, user_id)
);
alter table public.admin_classes enable row level security;
alter table public.admin_classes force row level security;
alter table public.admin_class_members enable row level security;
alter table public.admin_class_members force row level security;
revoke all on table public.admin_classes, public.admin_class_members from public, anon, authenticated;
grant select on public.admin_classes, public.admin_class_members to authenticated;
create policy admin_classes_read on public.admin_classes for select to authenticated using (active);
create policy admin_class_members_read on public.admin_class_members for select to authenticated using ((select auth.uid()) = user_id);

create table if not exists public.support_cases (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  subject text not null check (char_length(subject) between 3 and 120),
  body text not null check (char_length(body) between 3 and 5000),
  status text not null default 'open' check (status in ('open','in_progress','waiting','closed')),
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  assigned_to uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.support_cases enable row level security;
alter table public.support_cases force row level security;
revoke all on table public.support_cases from public, anon, authenticated;
grant select, insert on public.support_cases to authenticated;
create policy support_cases_own on public.support_cases for select to authenticated using ((select auth.uid()) = requester_id);
create policy support_cases_create on public.support_cases for insert to authenticated with check ((select auth.uid()) = requester_id);

create table if not exists public.admin_export_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'requested' check (status in ('requested','processing','ready','expired','rejected')),
  format text not null default 'json' check (format in ('json','csv')),
  created_at timestamptz not null default now(), completed_at timestamptz
);
create table if not exists public.privacy_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  request_type text not null check (request_type in ('access','deletion','correction')),
  status text not null default 'open' check (status in ('open','in_progress','completed','rejected')),
  note text check (note is null or char_length(note) <= 1000),
  created_at timestamptz not null default now(), resolved_at timestamptz
);
alter table public.admin_export_requests enable row level security;
alter table public.admin_export_requests force row level security;
alter table public.privacy_requests enable row level security;
alter table public.privacy_requests force row level security;
revoke all on table public.admin_export_requests, public.privacy_requests from public, anon, authenticated;
grant select, insert on public.admin_export_requests, public.privacy_requests to authenticated;
create policy export_own on public.admin_export_requests for select to authenticated using ((select auth.uid()) = requester_id);
create policy export_create on public.admin_export_requests for insert to authenticated with check ((select auth.uid()) = requester_id);
create policy privacy_own on public.privacy_requests for select to authenticated using ((select auth.uid()) = requester_id);
create policy privacy_create on public.privacy_requests for insert to authenticated with check ((select auth.uid()) = requester_id);

create or replace function public.get_public_admin_notice()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ declare m jsonb; a jsonb; begin
  select value into m from private.admin_control_settings where key = 'maintenance';
  select value into a from private.admin_control_settings where key = 'announcement';
  return jsonb_build_object('maintenance', m, 'announcement', a);
end $$;

create or replace function public.admin_list_control_center()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ declare r jsonb; begin
  perform private.require_admin();
  select jsonb_build_object(
    'settings', coalesce((select jsonb_object_agg(key,value) from private.admin_control_settings),'{}'::jsonb),
    'classes', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc) from public.admin_classes c),'[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.support_cases t),'[]'::jsonb),
    'exports', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.admin_export_requests e),'[]'::jsonb),
    'privacy', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.privacy_requests p),'[]'::jsonb),
    'shop', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.marketplace_items i),'[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.task_key) from public.daily_tasks t),'[]'::jsonb),
    'seasons', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at desc) from public.seasons s),'[]'::jsonb)
  ) into r;
  return r;
end $$;

create or replace function public.admin_update_catalog(
  p_kind text, p_id text, p_values jsonb, p_pin text
) returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; begin
  if p_kind not in ('shop','task','season') or jsonb_typeof(p_values) <> 'object' then
    return jsonb_build_object('ok',false,'error','invalid_catalog');
  end if;
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  if p_kind = 'shop' then
    update public.marketplace_items set
      name = coalesce(nullif(left(p_values->>'name',60),''),name),
      description = coalesce(nullif(left(p_values->>'description',180),''),description),
      price = case when (p_values->>'price') ~ '^[0-9]+$' then greatest((p_values->>'price')::bigint,1) else price end,
      active = coalesce((p_values->>'active')::boolean,active), updated_at=clock_timestamp()
    where id=p_id::uuid;
  elsif p_kind = 'task' then
    update public.daily_tasks set
      name = coalesce(nullif(left(p_values->>'name',80),''),name),
      description = coalesce(nullif(left(p_values->>'description',180),''),description),
      reward = case when (p_values->>'reward') ~ '^[0-9]+$' then greatest((p_values->>'reward')::bigint,1) else reward end,
      target_count = case when (p_values->>'target_count') ~ '^[0-9]+$' then greatest((p_values->>'target_count')::integer,1) else target_count end,
      active = coalesce((p_values->>'active')::boolean,active)
    where task_key=p_id;
  else
    update public.seasons set
      name = coalesce(nullif(left(p_values->>'name',60),''),name),
      reward_first = case when (p_values->>'reward_first') ~ '^[0-9]+$' then greatest((p_values->>'reward_first')::bigint,0) else reward_first end,
      reward_second = case when (p_values->>'reward_second') ~ '^[0-9]+$' then greatest((p_values->>'reward_second')::bigint,0) else reward_second end,
      reward_third = case when (p_values->>'reward_third') ~ '^[0-9]+$' then greatest((p_values->>'reward_third')::bigint,0) else reward_third end
    where id=p_id::uuid;
  end if;
  return jsonb_build_object('ok',true);
exception when invalid_text_representation then
  return jsonb_build_object('ok',false,'error','invalid_catalog_id');
end $$;

create or replace function public.admin_update_control(
  p_key text, p_value jsonb, p_pin text
) returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); pin_status text; begin
  if p_key not in ('maintenance','announcement','health') or jsonb_typeof(p_value) <> 'object' then
    return jsonb_build_object('ok',false,'error','invalid_control');
  end if;
  pin_status := private.check_admin_pin(actor,p_pin);
  if pin_status <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||pin_status); end if;
  insert into private.admin_control_settings(key,value,updated_by,updated_at)
    values(p_key,p_value,actor,clock_timestamp())
    on conflict(key) do update set value=excluded.value,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  return jsonb_build_object('ok',true,'key',p_key,'value',p_value);
end $$;

create or replace function public.admin_run_health_check(p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; result jsonb; begin
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  result := jsonb_build_object(
    'database', jsonb_build_object('status','ok','checked_at',clock_timestamp()),
    'wallets', jsonb_build_object('status',case when exists(select 1 from public.wallets) then 'ok' else 'warning' end),
    'transactions', jsonb_build_object('status',case when exists(select 1 from public.transactions) then 'ok' else 'warning' end),
    'catalog', jsonb_build_object('status',case when exists(select 1 from public.marketplace_items where active) then 'ok' else 'warning' end)
  );
  update private.admin_control_settings set value=jsonb_build_object('last_check_at',clock_timestamp(),'status','ok','checks',result),updated_by=actor,updated_at=clock_timestamp() where key='health';
  return jsonb_build_object('ok',true,'checks',result);
end $$;

create or replace function public.admin_create_class(p_name text,p_school_year text,p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; c public.admin_classes%rowtype; begin
  if char_length(trim(coalesce(p_name,''))) not between 2 and 80 then return jsonb_build_object('ok',false,'error','invalid_class'); end if;
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  insert into public.admin_classes(name,school_year,created_by) values(trim(p_name),coalesce(trim(p_school_year),''),actor) returning * into c;
  return jsonb_build_object('ok',true,'class',to_jsonb(c));
end $$;

create or replace function public.admin_update_case(p_case_id uuid,p_status text,p_priority text,p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare actor uuid := private.require_admin(); s text; begin
  if p_status not in ('open','in_progress','waiting','closed') or p_priority not in ('low','normal','high','urgent') then return jsonb_build_object('ok',false,'error','invalid_case'); end if;
  s := private.check_admin_pin(actor,p_pin); if s <> 'ok' then return jsonb_build_object('ok',false,'error','admin_pin_'||s); end if;
  update public.support_cases set status=p_status,priority=p_priority,assigned_to=actor,updated_at=clock_timestamp() where id=p_case_id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.request_data_export(p_format text default 'json')
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare u uuid := private.require_active_user(); r public.admin_export_requests%rowtype; begin
  if p_format not in ('json','csv') then raise exception 'invalid_export_format'; end if;
  insert into public.admin_export_requests(requester_id,format) values(u,p_format) returning * into r;
  return jsonb_build_object('ok',true,'request',to_jsonb(r));
end $$;
create or replace function public.create_privacy_request(p_type text,p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$ declare u uuid := private.require_active_user(); r public.privacy_requests%rowtype; begin
  if p_type not in ('access','deletion','correction') then raise exception 'invalid_privacy_request'; end if;
  insert into public.privacy_requests(requester_id,request_type,note) values(u,p_type,left(p_note,1000)) returning * into r;
  return jsonb_build_object('ok',true,'request',to_jsonb(r));
end $$;

revoke all on function public.get_public_admin_notice() from public, anon; grant execute on function public.get_public_admin_notice() to authenticated;
revoke all on function public.admin_list_control_center() from public, anon; grant execute on function public.admin_list_control_center() to authenticated;
revoke all on function public.admin_update_catalog(text,text,jsonb,text) from public, anon; grant execute on function public.admin_update_catalog(text,text,jsonb,text) to authenticated;
revoke all on function public.admin_update_control(text,jsonb,text) from public, anon; grant execute on function public.admin_update_control(text,jsonb,text) to authenticated;
revoke all on function public.admin_run_health_check(text) from public, anon; grant execute on function public.admin_run_health_check(text) to authenticated;
revoke all on function public.admin_create_class(text,text,text) from public, anon; grant execute on function public.admin_create_class(text,text,text) to authenticated;
revoke all on function public.admin_update_case(uuid,text,text,text) from public, anon; grant execute on function public.admin_update_case(uuid,text,text,text) to authenticated;
revoke all on function public.request_data_export(text) from public, anon; grant execute on function public.request_data_export(text) to authenticated;
revoke all on function public.create_privacy_request(text,text) from public, anon; grant execute on function public.create_privacy_request(text,text) to authenticated;


-- ===================== 20260915090000_add_gibb_blockchain.sql =====================
-- GIBB Blockchain: Blöcke über der bestehenden Transaktions-Hash-Kette.
--
-- Jeder Block versiegelt eine Menge unbestätigter Transaktionen (Merkle-Root),
-- verweist auf den Hash des Vorgängerblocks und trägt einen Proof-of-Work
-- (SHA-256, führende Nullbits). Blöcke werden von Schülern im Browser gefunden
-- (CPU-Mining); der Server prüft Header, Merkle-Root und Schwierigkeit und
-- schreibt die Belohnung serverautoritativ über private.append_transaction.
--
-- Die bestehende lineare Hash-Kette der Transaktionen bleibt unverändert.

-- ---------------------------------------------------------------------------
-- Ledger: neuer Transaktionstyp und Blockzuordnung
-- ---------------------------------------------------------------------------
-- Kompatibilität: In der Supabase-Cloud wurde die Ledger-Tabelle ohne chain_index angelegt
-- (Reihenfolge der Hash-Kette dort: created_at, id). Die Blöcke brauchen eine laufende Nummer.
-- Fehlt die Spalte, wird sie angelegt und in Ketten-Reihenfolge aufgefüllt; neue Buchungen
-- bekommen die nächste Nummer automatisch. Bei frischen Datenbanken existiert sie bereits.
do $compat$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'transactions' and column_name = 'chain_index'
  ) then
    alter table public.transactions add column chain_index bigint;
    with ordered as (
      select t.id, pg_catalog.row_number() over (order by t.created_at, t.id) as rn
      from public.transactions t
    )
    update public.transactions t set chain_index = ordered.rn from ordered where ordered.id = t.id;
    create sequence if not exists public.transactions_chain_index_seq owned by public.transactions.chain_index;
    perform pg_catalog.setval('public.transactions_chain_index_seq',
      coalesce((select max(chain_index) from public.transactions), 0) + 1, false);
    alter table public.transactions
      alter column chain_index set default pg_catalog.nextval('public.transactions_chain_index_seq'::regclass),
      alter column chain_index set not null;
    create unique index if not exists transactions_chain_index_key on public.transactions(chain_index);
  end if;
end;
$compat$;

alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions
  add constraint transactions_type_check check (
    type in (
      'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
      'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN',
      'COIN_PURCHASE', 'GAME_ENTRY', 'GAME_REWARD', 'MINING_REWARD'
    )
  );

alter table public.transactions add column if not exists block_height bigint;
create index if not exists transactions_block_height_idx on public.transactions(block_height);
create index if not exists transactions_pending_block_idx on public.transactions(chain_index) where block_height is null;

alter table public.admin_audit_logs drop constraint if exists admin_audit_logs_action_check;
alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT', 'ADMIN_BURN', 'BALANCE_SET', 'ROLE_CHANGED',
      'WALLET_LOCKED', 'WALLET_UNLOCKED', 'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED', 'ACCOUNT_DELETED', 'PASSWORD_RESET_SENT',
      'ADMIN_PIN_SET', 'ADMIN_PIN_CHANGED', 'GAME_SETTING_CHANGED',
      'STATS_RESET', 'ADMIN_OPERATION_CHANGED', 'BLOCKCHAIN_SETTING_CHANGED'
    )
  );

-- ---------------------------------------------------------------------------
-- Blöcke
-- ---------------------------------------------------------------------------
create table if not exists public.blocks (
  height bigint primary key check (height >= 0),
  previous_hash text not null check (previous_hash ~ '^[0-9a-f]{64}$'),
  merkle_root text not null check (merkle_root ~ '^[0-9a-f]{64}$'),
  first_chain_index bigint,
  last_chain_index bigint,
  tx_count integer not null check (tx_count >= 0),
  mined_at timestamptz not null,
  difficulty_bits integer not null check (difficulty_bits between 0 and 64),
  nonce bigint not null check (nonce >= 0),
  hash text not null unique check (hash ~ '^[0-9a-f]{64}$'),
  miner_user_id uuid references private.ledger_identities(id) on delete restrict,
  miner_label text not null default 'Genesis' check (char_length(miner_label) between 1 and 100),
  reward bigint not null default 0 check (reward >= 0),
  reward_transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint blocks_chain_range check (
    (tx_count = 0 and first_chain_index is null and last_chain_index is null)
    or (tx_count > 0 and first_chain_index is not null and last_chain_index >= first_chain_index)
  )
);

create index if not exists blocks_miner_idx on public.blocks(miner_user_id, mined_at desc);

alter table public.blocks enable row level security;
alter table public.blocks force row level security;
revoke all on table public.blocks from public, anon, authenticated;
grant select on table public.blocks to authenticated;

drop policy if exists "read blocks" on public.blocks;
create policy "read blocks" on public.blocks for select to authenticated using (true);

-- Blockchain-Einstellungen (Admin) liegen in der bestehenden Kontrolltabelle.
insert into private.admin_control_settings (key, value) values
  ('blockchain', pg_catalog.jsonb_build_object(
    'enabled', true,
    'reward', 2,
    'target_seconds', 120,
    'min_bits', 16,
    'max_bits', 36,
    'cooldown_seconds', 90,
    'max_tx_per_block', 500
  ))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Reine Hilfsfunktionen (identisch im Browser nachgerechnet, siehe app/lib/blockchain-core.js)
-- ---------------------------------------------------------------------------
create or replace function private.blockchain_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'enabled', coalesce((s.value ->> 'enabled')::boolean, true),
    'reward', greatest(0, least(1000, coalesce((s.value ->> 'reward')::bigint, 2))),
    'target_seconds', greatest(10, least(86400, coalesce((s.value ->> 'target_seconds')::integer, 120))),
    'min_bits', greatest(8, least(48, coalesce((s.value ->> 'min_bits')::integer, 16))),
    'max_bits', greatest(8, least(48, coalesce((s.value ->> 'max_bits')::integer, 36))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((s.value ->> 'cooldown_seconds')::integer, 90))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((s.value ->> 'max_tx_per_block')::integer, 500)))
  )
  from (select coalesce((select value from private.admin_control_settings where key = 'blockchain'), '{}'::jsonb) as value) s;
$$;
revoke all on function private.blockchain_settings() from public, anon, authenticated;

create or replace function private.merkle_root(p_hashes text[])
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_level text[] := p_hashes;
  v_next text[];
  v_count integer;
  v_i integer;
begin
  if v_level is null or coalesce(pg_catalog.array_length(v_level, 1), 0) = 0 then
    return pg_catalog.repeat('0', 64);
  end if;
  loop
    v_count := pg_catalog.array_length(v_level, 1);
    if v_count = 1 then return v_level[1]; end if;
    if v_count % 2 = 1 then
      v_level := v_level || v_level[v_count];
      v_count := v_count + 1;
    end if;
    v_next := '{}'::text[];
    v_i := 1;
    while v_i < v_count loop
      v_next := v_next || pg_catalog.encode(extensions.digest(v_level[v_i] || v_level[v_i + 1], 'sha256'), 'hex');
      v_i := v_i + 2;
    end loop;
    v_level := v_next;
  end loop;
end;
$$;
revoke all on function private.merkle_root(text[]) from public, anon, authenticated;

create or replace function private.block_header(
  p_height bigint, p_previous_hash text, p_merkle_root text, p_timestamp bigint,
  p_difficulty_bits integer, p_miner_user_id uuid, p_nonce bigint
)
returns text
language sql
immutable
set search_path = ''
as $$
  select p_height::text || '|' || p_previous_hash || '|' || p_merkle_root || '|' || p_timestamp::text || '|'
    || p_difficulty_bits::text || '|' || coalesce(p_miner_user_id::text, '') || '|' || p_nonce::text;
$$;
revoke all on function private.block_header(bigint, text, text, bigint, integer, uuid, bigint) from public, anon, authenticated;

create or replace function private.block_hash(
  p_height bigint, p_previous_hash text, p_merkle_root text, p_timestamp bigint,
  p_difficulty_bits integer, p_miner_user_id uuid, p_nonce bigint
)
returns text
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.encode(extensions.digest(
    private.block_header(p_height, p_previous_hash, p_merkle_root, p_timestamp, p_difficulty_bits, p_miner_user_id, p_nonce),
    'sha256'), 'hex');
$$;
revoke all on function private.block_hash(bigint, text, text, bigint, integer, uuid, bigint) from public, anon, authenticated;

-- Anzahl führender Nullbits eines Hex-Hashes (Proof-of-Work-Mass).
create or replace function private.leading_zero_bits(p_hex text)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_bits integer := 0;
  v_i integer := 1;
  v_nibble integer;
begin
  while v_i <= pg_catalog.length(p_hex) loop
    v_nibble := pg_catalog.strpos('0123456789abcdef', pg_catalog.substr(p_hex, v_i, 1)) - 1;
    if v_nibble < 0 then raise exception 'invalid_hex'; end if;
    if v_nibble = 0 then
      v_bits := v_bits + 4;
    else
      v_bits := v_bits + case when v_nibble < 2 then 3 when v_nibble < 4 then 2 when v_nibble < 8 then 1 else 0 end;
      return v_bits;
    end if;
    v_i := v_i + 1;
  end loop;
  return v_bits;
end;
$$;
revoke all on function private.leading_zero_bits(text) from public, anon, authenticated;

-- Unbestätigte Transaktionen bis zu einem Kettenindex, in Kettenreihenfolge.
create or replace function private.pending_transaction_hashes(p_last_chain_index bigint)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.array_agg(t.hash order by t.chain_index), '{}'::text[])
  from public.transactions t
  where t.block_height is null and t.chain_index <= p_last_chain_index;
$$;
revoke all on function private.pending_transaction_hashes(bigint) from public, anon, authenticated;

-- Schwierigkeit für den nächsten Block, abgeleitet aus der Blockzeit der letzten Blöcke.
create or replace function private.blockchain_difficulty()
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_settings jsonb := private.blockchain_settings();
  v_min integer := (v_settings ->> 'min_bits')::integer;
  v_max integer := (v_settings ->> 'max_bits')::integer;
  v_target integer := (v_settings ->> 'target_seconds')::integer;
  v_tip public.blocks%rowtype;
  v_window_start timestamptz;
  v_window_count integer;
  v_average double precision;
  v_bits integer;
  v_stalled_periods integer;
begin
  select * into v_tip from public.blocks order by height desc limit 1;
  if not found or v_tip.height = 0 then return v_min; end if;

  v_bits := v_tip.difficulty_bits;

  -- Durchschnittliche Blockzeit der letzten bis zu 10 Blöcke (ohne Genesis).
  select min(w.mined_at), count(*) into v_window_start, v_window_count
  from (select mined_at from public.blocks where height > 0 order by height desc limit 10) w;
  if v_window_count >= 2 then
    v_average := pg_catalog.date_part('epoch', (v_tip.mined_at - v_window_start)) / (v_window_count - 1);
    if v_average < v_target / 2.0 then v_bits := v_bits + 1;
    elsif v_average > v_target * 2.0 then v_bits := v_bits - 1;
    end if;
  end if;

  -- Notbremse: steht die Kette lange still, sinkt die Schwierigkeit schrittweise.
  v_stalled_periods := floor(pg_catalog.date_part('epoch', (pg_catalog.now() - v_tip.mined_at)) / (v_target * 4.0))::integer;
  if v_stalled_periods > 0 then v_bits := v_bits - v_stalled_periods; end if;

  return greatest(v_min, least(v_max, v_bits));
end;
$$;
revoke all on function private.blockchain_difficulty() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Öffentliche RPCs (nur angemeldete Benutzer)
-- ---------------------------------------------------------------------------
create or replace function public.get_blockchain_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_settings jsonb := private.blockchain_settings();
  v_tip public.blocks%rowtype;
  v_pending_count bigint;
  v_pending_first bigint;
  v_pending_last bigint;
  v_block_count bigint;
  v_minted bigint;
  v_average double precision;
  v_my_blocks bigint;
  v_my_last timestamptz;
  v_next_allowed timestamptz;
  v_top jsonb;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;

  select * into v_tip from public.blocks order by height desc limit 1;
  select count(*), min(chain_index), max(chain_index) into v_pending_count, v_pending_first, v_pending_last
  from public.transactions where block_height is null;
  select count(*), coalesce(sum(reward), 0) into v_block_count, v_minted from public.blocks;

  select case when count(*) >= 2 then pg_catalog.date_part('epoch', (max(mined_at) - min(mined_at))) / (count(*) - 1) end
  into v_average
  from (select mined_at from public.blocks where height > 0 order by height desc limit 10) w;

  select count(*), max(mined_at) into v_my_blocks, v_my_last from public.blocks where miner_user_id = v_user_id;
  v_next_allowed := case when v_my_last is null then null
    else v_my_last + make_interval(secs => (v_settings ->> 'cooldown_seconds')::integer) end;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'user_id', m.miner_user_id, 'label', m.miner_label, 'blocks', m.blocks, 'reward', m.reward
  ) order by m.blocks desc, m.reward desc), '[]'::jsonb)
  into v_top
  from (
    select miner_user_id, max(miner_label) as miner_label, count(*) as blocks, sum(reward) as reward
    from public.blocks where miner_user_id is not null
    group by miner_user_id order by count(*) desc, sum(reward) desc limit 5
  ) m;

  return pg_catalog.jsonb_build_object(
    'enabled', (v_settings ->> 'enabled')::boolean,
    'reward', (v_settings ->> 'reward')::bigint,
    'target_seconds', (v_settings ->> 'target_seconds')::integer,
    'cooldown_seconds', (v_settings ->> 'cooldown_seconds')::integer,
    'max_tx_per_block', (v_settings ->> 'max_tx_per_block')::integer,
    'min_bits', (v_settings ->> 'min_bits')::integer,
    'max_bits', (v_settings ->> 'max_bits')::integer,
    'height', v_tip.height,
    'tip_hash', v_tip.hash,
    'tip_mined_at', v_tip.mined_at,
    'difficulty_bits', private.blockchain_difficulty(),
    'block_count', v_block_count,
    'minted_reward', v_minted,
    'pending_count', v_pending_count,
    'pending_first_chain_index', v_pending_first,
    'pending_last_chain_index', v_pending_last,
    'average_block_seconds', v_average,
    'my_blocks', v_my_blocks,
    'my_next_mining_at', case when v_next_allowed > pg_catalog.now() then v_next_allowed end,
    'top_miners', v_top,
    'server_time', pg_catalog.now()
  );
end;
$$;

-- Liefert alles, was ein Miner für die Nonce-Suche braucht. Der Header wird im
-- Browser exakt so zusammengesetzt wie in private.block_header.
create or replace function public.get_block_template()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_settings jsonb := private.blockchain_settings();
  v_tip public.blocks%rowtype;
  v_hashes text[];
  v_first bigint;
  v_last bigint;
  v_count integer;
  v_height bigint;
  v_previous text;
  v_bits integer;
  v_timestamp bigint := floor(pg_catalog.date_part('epoch', pg_catalog.now()))::bigint;
  v_my_last timestamptz;
begin
  if not (v_settings ->> 'enabled')::boolean then raise exception 'mining_disabled'; end if;

  select max(mined_at) into v_my_last from public.blocks where miner_user_id = v_user_id;
  if v_my_last is not null and v_my_last + make_interval(secs => (v_settings ->> 'cooldown_seconds')::integer) > pg_catalog.now() then
    raise exception 'mining_cooldown';
  end if;

  select * into v_tip from public.blocks order by height desc limit 1;
  v_height := coalesce(v_tip.height + 1, 0);
  v_previous := coalesce(v_tip.hash, pg_catalog.repeat('0', 64));

  select min(p.chain_index), max(p.chain_index), count(*) into v_first, v_last, v_count
  from (
    select chain_index from public.transactions where block_height is null
    order by chain_index limit (v_settings ->> 'max_tx_per_block')::integer
  ) p;
  if coalesce(v_count, 0) = 0 then raise exception 'no_pending_transactions'; end if;

  v_hashes := private.pending_transaction_hashes(v_last);
  v_bits := private.blockchain_difficulty();

  return pg_catalog.jsonb_build_object(
    'height', v_height,
    'previous_hash', v_previous,
    'merkle_root', private.merkle_root(v_hashes),
    'first_chain_index', v_first,
    'last_chain_index', v_last,
    'tx_count', v_count,
    'tx_hashes', pg_catalog.to_jsonb(v_hashes),
    'timestamp', v_timestamp,
    'difficulty_bits', v_bits,
    'miner_user_id', v_user_id,
    'reward', (v_settings ->> 'reward')::bigint,
    'header_prefix', private.block_header(v_height, v_previous, private.merkle_root(v_hashes), v_timestamp, v_bits, v_user_id, 0)
  );
end;
$$;

create or replace function public.submit_mined_block(
  p_height bigint,
  p_previous_hash text,
  p_last_chain_index bigint,
  p_timestamp bigint,
  p_difficulty_bits integer,
  p_nonce bigint,
  p_hash text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_settings jsonb := private.blockchain_settings();
  v_tip public.blocks%rowtype;
  v_hashes text[];
  v_first bigint;
  v_count integer;
  v_merkle text;
  v_hash text;
  v_required_bits integer;
  v_reward bigint := (v_settings ->> 'reward')::bigint;
  v_label text;
  v_wallet_id uuid;
  v_reward_tx uuid;
  v_block public.blocks%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_my_last timestamptz;
begin
  if not (v_settings ->> 'enabled')::boolean then raise exception 'mining_disabled'; end if;
  if p_nonce is null or p_nonce < 0 then raise exception 'invalid_nonce'; end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid_hash'; end if;
  if p_difficulty_bits is null or p_difficulty_bits not between 0 and 64 then raise exception 'invalid_difficulty'; end if;

  -- Dieselbe Sperre wie der Ledger: Während der Versiegelung wird nichts angehängt.
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_blockchain'));

  select max(mined_at) into v_my_last from public.blocks where miner_user_id = v_user_id;
  if v_my_last is not null and v_my_last + make_interval(secs => (v_settings ->> 'cooldown_seconds')::integer) > v_now then
    raise exception 'mining_cooldown';
  end if;

  select * into v_tip from public.blocks order by height desc limit 1;
  if p_height <> coalesce(v_tip.height + 1, 0) or p_previous_hash <> coalesce(v_tip.hash, pg_catalog.repeat('0', 64)) then
    raise exception 'stale_block';
  end if;

  -- Zeitstempel: nicht vor dem Vorgänger, nicht älter als 10 Minuten, höchstens 2 Minuten in der Zukunft.
  if p_timestamp is null
     or (v_tip.mined_at is not null and p_timestamp < floor(pg_catalog.date_part('epoch', v_tip.mined_at))::bigint)
     or p_timestamp < floor(pg_catalog.date_part('epoch', v_now))::bigint - 600
     or p_timestamp > floor(pg_catalog.date_part('epoch', v_now))::bigint + 120 then
    raise exception 'invalid_timestamp';
  end if;

  -- Transaktionsmenge: alle unbestätigten bis zum gemeldeten Index (Obergrenze beachten).
  if p_last_chain_index is null or not exists (
    select 1 from public.transactions where block_height is null and chain_index = p_last_chain_index
  ) then
    raise exception 'invalid_transaction_range';
  end if;
  v_hashes := private.pending_transaction_hashes(p_last_chain_index);
  v_count := coalesce(pg_catalog.array_length(v_hashes, 1), 0);
  if v_count = 0 or v_count > (v_settings ->> 'max_tx_per_block')::integer then
    raise exception 'invalid_transaction_range';
  end if;
  select min(chain_index) into v_first from public.transactions where block_height is null and chain_index <= p_last_chain_index;
  v_merkle := private.merkle_root(v_hashes);

  -- Proof of Work: Der Client darf eine höhere, nie eine niedrigere Schwierigkeit verwenden.
  v_required_bits := private.blockchain_difficulty();
  if p_difficulty_bits < v_required_bits then raise exception 'difficulty_too_low'; end if;
  v_hash := private.block_hash(p_height, p_previous_hash, v_merkle, p_timestamp, p_difficulty_bits, v_user_id, p_nonce);
  if v_hash <> p_hash then raise exception 'hash_mismatch'; end if;
  if private.leading_zero_bits(v_hash) < p_difficulty_bits then raise exception 'insufficient_work'; end if;

  select coalesce(nullif(pg_catalog.btrim(p.username), ''), p.display_name, 'Miner') into v_label
  from public.profiles p where p.id = v_user_id;
  v_label := pg_catalog.left(coalesce(v_label, 'Miner'), 100);

  insert into public.blocks (
    height, previous_hash, merkle_root, first_chain_index, last_chain_index, tx_count,
    mined_at, difficulty_bits, nonce, hash, miner_user_id, miner_label, reward
  ) values (
    p_height, p_previous_hash, v_merkle, v_first, p_last_chain_index, v_count,
    pg_catalog.to_timestamp(p_timestamp), p_difficulty_bits, p_nonce, v_hash, v_user_id, v_label, v_reward
  ) returning * into v_block;

  update public.transactions set block_height = p_height
  where block_height is null and chain_index <= p_last_chain_index;

  -- Belohnung: serverautoritativ, als reguläre Ledger-Transaktion (landet im nächsten Block).
  if v_reward > 0 then
    select id into v_wallet_id from public.wallets where user_id = v_user_id for update;
    if v_wallet_id is null then raise exception 'wallet_not_found'; end if;
    update public.wallets set balance = balance + v_reward, updated_at = v_now where id = v_wallet_id;
    v_reward_tx := private.append_transaction(null, v_user_id, v_reward, 'MINING_REWARD',
      'Blockchain · Block #' || p_height || ' gefunden · ' || p_difficulty_bits || ' Bit');
    update public.blocks set reward_transaction_id = v_reward_tx where height = p_height;
    v_block.reward_transaction_id := v_reward_tx;
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'block', pg_catalog.to_jsonb(v_block));
end;
$$;

-- Transaktionen eines Blocks: nur Hashes und Zeitpunkte, keine Beträge oder Beteiligten.
create or replace function public.get_block_transactions(p_height bigint)
returns table (chain_index bigint, hash text, previous_hash text, type text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select t.chain_index, t.hash, t.previous_hash, t.type, t.created_at
  from public.transactions t
  where auth.uid() is not null and t.block_height = p_height
  order by t.chain_index
  limit 2000;
$$;

-- Vollständige Prüfung: Vorgänger-Hashes, Merkle-Roots, Block-Hashes und Proof of Work.
create or replace function public.verify_blockchain()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_block record;
  v_expected_previous text := pg_catalog.repeat('0', 64);
  v_expected_height bigint := 0;
  v_hashes text[];
  v_checked integer := 0;
  v_reason text;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  for v_block in select * from public.blocks order by height loop
    v_reason := null;
    if v_block.height <> v_expected_height then v_reason := 'height_gap';
    elsif v_block.previous_hash <> v_expected_previous then v_reason := 'previous_hash_mismatch';
    else
      select coalesce(pg_catalog.array_agg(t.hash order by t.chain_index), '{}'::text[]) into v_hashes
      from public.transactions t where t.block_height = v_block.height;
      if coalesce(pg_catalog.array_length(v_hashes, 1), 0) <> v_block.tx_count then v_reason := 'transaction_count_mismatch';
      elsif private.merkle_root(v_hashes) <> v_block.merkle_root then v_reason := 'merkle_root_mismatch';
      elsif private.block_hash(v_block.height, v_block.previous_hash, v_block.merkle_root,
              floor(pg_catalog.date_part('epoch', v_block.mined_at))::bigint, v_block.difficulty_bits,
              v_block.miner_user_id, v_block.nonce) <> v_block.hash then v_reason := 'block_hash_mismatch';
      elsif private.leading_zero_bits(v_block.hash) < v_block.difficulty_bits then v_reason := 'insufficient_work';
      end if;
    end if;
    if v_reason is not null then
      return pg_catalog.jsonb_build_object('valid', false, 'blocks_checked', v_checked, 'invalid_height', v_block.height, 'reason', v_reason);
    end if;
    v_checked := v_checked + 1;
    v_expected_previous := v_block.hash;
    v_expected_height := v_block.height + 1;
  end loop;
  return pg_catalog.jsonb_build_object('valid', true, 'blocks_checked', v_checked, 'checked_at', pg_catalog.now());
end;
$$;

create or replace function public.admin_update_blockchain_settings(p_value jsonb, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb := private.blockchain_settings();
  v_after jsonb;
begin
  if p_value is null or pg_catalog.jsonb_typeof(p_value) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  v_pin_status := private.check_admin_pin(v_admin, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_after := pg_catalog.jsonb_build_object(
    'enabled', coalesce((p_value ->> 'enabled')::boolean, (v_before ->> 'enabled')::boolean),
    'reward', greatest(0, least(1000, coalesce((p_value ->> 'reward')::bigint, (v_before ->> 'reward')::bigint))),
    'target_seconds', greatest(10, least(86400, coalesce((p_value ->> 'target_seconds')::integer, (v_before ->> 'target_seconds')::integer))),
    'min_bits', greatest(8, least(48, coalesce((p_value ->> 'min_bits')::integer, (v_before ->> 'min_bits')::integer))),
    'max_bits', greatest(8, least(48, coalesce((p_value ->> 'max_bits')::integer, (v_before ->> 'max_bits')::integer))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((p_value ->> 'cooldown_seconds')::integer, (v_before ->> 'cooldown_seconds')::integer))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((p_value ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer)))
  );
  if (v_after ->> 'min_bits')::integer > (v_after ->> 'max_bits')::integer then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_difficulty_range');
  end if;

  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('blockchain', v_after, v_admin, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;

  perform private.write_admin_audit(v_admin, v_admin, 'BLOCKCHAIN_SETTING_CHANGED', v_before, v_after, 'Blockchain-Einstellungen geändert');

  return pg_catalog.jsonb_build_object('ok', true, 'settings', v_after);
end;
$$;

revoke all on function public.get_blockchain_overview() from public, anon;
revoke all on function public.get_block_template() from public, anon;
revoke all on function public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text) from public, anon;
revoke all on function public.get_block_transactions(bigint) from public, anon;
revoke all on function public.verify_blockchain() from public, anon;
revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.get_blockchain_overview() to authenticated;
grant execute on function public.get_block_template() to authenticated;
grant execute on function public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text) to authenticated;
grant execute on function public.get_block_transactions(bigint) to authenticated;
grant execute on function public.verify_blockchain() to authenticated;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Genesis-Block: versiegelt alle bereits vorhandenen Transaktionen ohne Proof of Work.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hashes text[];
  v_first bigint;
  v_last bigint;
  v_count integer;
  v_merkle text;
  v_timestamp bigint := floor(extract(epoch from now()))::bigint;
  v_zero text := repeat('0', 64);
begin
  if exists (select 1 from public.blocks) then return; end if;
  perform pg_advisory_xact_lock(hashtext('gibb_coin_transfer_chain'));
  select coalesce(array_agg(t.hash order by t.chain_index), '{}'::text[]), min(t.chain_index), max(t.chain_index), count(*)
  into v_hashes, v_first, v_last, v_count
  from public.transactions t where t.block_height is null;
  v_merkle := private.merkle_root(v_hashes);
  insert into public.blocks (
    height, previous_hash, merkle_root, first_chain_index, last_chain_index, tx_count,
    mined_at, difficulty_bits, nonce, hash, miner_user_id, miner_label, reward
  ) values (
    0, v_zero, v_merkle, v_first, v_last, coalesce(v_count, 0),
    to_timestamp(v_timestamp), 0, 0, private.block_hash(0, v_zero, v_merkle, v_timestamp, 0, null, 0), null, 'Genesis', 0
  );
  update public.transactions set block_height = 0 where block_height is null;
end;
$$;


-- ===================== 20260915090100_repair_admin_limits_and_mfa.sql =====================
-- Repair the prioritized admin and player-safety regressions without rewriting
-- previously applied migrations.

create or replace function private.assert_mfa_if_enrolled(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'authentication_required';
  end if;
  if exists (
    select 1 from auth.mfa_factors f
    where f.user_id = p_user_id and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
end;
$$;

revoke all on function private.assert_mfa_if_enrolled(uuid)
from public, anon, authenticated;

create table if not exists private.game_loss_reservations (
  session_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  wager bigint not null check (wager > 0),
  created_at timestamptz not null default clock_timestamp()
);

revoke all on table private.game_loss_reservations from public, anon, authenticated;
create index if not exists game_loss_reservations_user_idx
  on private.game_loss_reservations(user_id, created_at);

create or replace function private.enforce_session_safety()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_safety public.player_safety_settings%rowtype;
  v_global private.global_game_limits%rowtype;
  v_daily_loss bigint := 0;
  v_reserved_loss bigint := 0;
  v_effective_cooldown integer := 0;
begin
  insert into public.player_safety_settings (user_id)
  values (new.user_id)
  on conflict (user_id) do nothing;

  select s.* into v_safety
  from public.player_safety_settings s
  where s.user_id = new.user_id
  for update;

  select g.* into v_global
  from private.global_game_limits g
  where g.singleton;

  if v_safety.break_until is not null and v_safety.break_until > clock_timestamp() then
    raise exception 'player_break_active';
  end if;
  if v_global.max_wager is not null and new.wager > v_global.max_wager then
    raise exception 'global_wager_limit';
  end if;
  if v_safety.max_wager is not null and new.wager > v_safety.max_wager then
    raise exception 'player_wager_limit';
  end if;

  v_effective_cooldown := greatest(
    coalesce(v_global.cooldown_seconds, 0),
    coalesce(v_safety.cooldown_seconds, 0)
  );
  if v_effective_cooldown > 0
     and v_safety.last_round_at is not null
     and v_safety.last_round_at + pg_catalog.make_interval(secs => v_effective_cooldown) > clock_timestamp()
  then
    raise exception 'global_or_player_cooldown';
  end if;

  select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint
  into v_daily_loss
  from public.game_rounds r
  where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;

  select coalesce(sum(r.wager), 0)::bigint
  into v_reserved_loss
  from private.game_loss_reservations r
  where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;

  if v_global.daily_loss_limit is not null
     and v_daily_loss + v_reserved_loss + new.wager > v_global.daily_loss_limit then
    raise exception 'global_daily_loss_limit';
  end if;
  if v_safety.daily_loss_limit is not null
     and v_daily_loss + v_reserved_loss + new.wager > v_safety.daily_loss_limit then
    raise exception 'player_daily_loss_limit';
  end if;

  insert into private.game_loss_reservations(session_id, user_id, wager)
  values (new.id, new.user_id, new.wager)
  on conflict (session_id) do nothing;

  update public.player_safety_settings
  set last_round_at = clock_timestamp(), updated_at = clock_timestamp()
  where user_id = new.user_id;
  return new;
end;
$$;

revoke all on function private.enforce_session_safety() from public, anon, authenticated;

create or replace function private.prepare_fair_game_round()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_safety public.player_safety_settings%rowtype;
  v_global private.global_game_limits%rowtype;
  v_daily_loss bigint := 0;
  v_loss_increment bigint := greatest(new.wager, 0);
  v_effective_cooldown integer := 0;
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

  insert into public.player_safety_settings (user_id)
  values (new.user_id)
  on conflict (user_id) do nothing;

  select s.* into v_safety from public.player_safety_settings s
  where s.user_id = new.user_id for update;
  select g.* into v_global from private.global_game_limits g where g.singleton;

  if v_safety.break_until is not null and v_safety.break_until > clock_timestamp() then
    raise exception 'player_break_active';
  end if;
  if v_global.max_wager is not null and new.wager > v_global.max_wager then
    raise exception 'global_wager_limit';
  end if;
  if v_safety.max_wager is not null and new.wager > v_safety.max_wager then
    raise exception 'player_wager_limit';
  end if;

  v_effective_cooldown := greatest(coalesce(v_global.cooldown_seconds, 0), coalesce(v_safety.cooldown_seconds, 0));
  if v_effective_cooldown > 0
     and v_safety.last_round_at is not null
     and v_safety.last_round_at + pg_catalog.make_interval(secs => v_effective_cooldown) > clock_timestamp()
  then
    raise exception 'global_or_player_cooldown';
  end if;

  select coalesce(sum(greatest(r.wager - r.payout, 0)), 0)::bigint
  into v_daily_loss
  from public.game_rounds r
  where r.user_id = new.user_id and r.created_at >= current_date::timestamptz;

  if v_global.daily_loss_limit is not null and v_daily_loss + v_loss_increment > v_global.daily_loss_limit then
    raise exception 'global_daily_loss_limit';
  end if;
  if v_safety.daily_loss_limit is not null and v_daily_loss + v_loss_increment > v_safety.daily_loss_limit then
    raise exception 'player_daily_loss_limit';
  end if;

  update public.player_safety_settings
  set last_round_at = clock_timestamp(), updated_at = clock_timestamp()
  where user_id = new.user_id;

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

create or replace function private.release_game_loss_reservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from private.game_loss_reservations where session_id = old.id;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function private.release_game_loss_reservation() from public, anon, authenticated;

drop trigger if exists release_blackjack_loss_reservation on public.blackjack_sessions;
create trigger release_blackjack_loss_reservation
after update on public.blackjack_sessions
for each row when (new.status <> 'active')
execute function private.release_game_loss_reservation();
drop trigger if exists delete_blackjack_loss_reservation on public.blackjack_sessions;
create trigger delete_blackjack_loss_reservation
after delete on public.blackjack_sessions
for each row execute function private.release_game_loss_reservation();

drop trigger if exists release_poker_loss_reservation on public.poker_sessions;
create trigger release_poker_loss_reservation
after update on public.poker_sessions
for each row when (new.status <> 'active')
execute function private.release_game_loss_reservation();
drop trigger if exists delete_poker_loss_reservation on public.poker_sessions;
create trigger delete_poker_loss_reservation
after delete on public.poker_sessions
for each row execute function private.release_game_loss_reservation();

drop trigger if exists release_dino_loss_reservation on public.dino_run_sessions;
create trigger release_dino_loss_reservation
after update on public.dino_run_sessions
for each row when (new.status <> 'active')
execute function private.release_game_loss_reservation();
drop trigger if exists delete_dino_loss_reservation on public.dino_run_sessions;
create trigger delete_dino_loss_reservation
after delete on public.dino_run_sessions
for each row execute function private.release_game_loss_reservation();

notify pgrst, 'reload schema';

create or replace function public.get_public_admin_notice()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_maintenance jsonb;
  v_announcement jsonb;
begin
  select value into v_maintenance
  from private.admin_control_settings
  where key = 'maintenance'
    and coalesce((value ->> 'enabled')::boolean, false)
    and (
      nullif(value ->> 'until', '') is null
      or (value ->> 'until')::timestamptz > clock_timestamp()
    );

  select value into v_announcement
  from private.admin_control_settings
  where key = 'announcement'
    and coalesce((value ->> 'enabled')::boolean, false)
    and (
      nullif(value ->> 'until', '') is null
      or (value ->> 'until')::timestamptz > clock_timestamp()
    );

  return jsonb_build_object(
    'maintenance', coalesce(v_maintenance, jsonb_build_object('enabled', false)),
    'announcement', coalesce(v_announcement, jsonb_build_object('enabled', false))
  );
exception
  when invalid_text_representation then
    return jsonb_build_object(
      'maintenance', jsonb_build_object('enabled', false),
      'announcement', jsonb_build_object('enabled', false)
    );
end;
$$;

revoke all on function public.get_public_admin_notice() from public, anon;
grant execute on function public.get_public_admin_notice() to authenticated;


-- ===================== 20260915100000_backend_security_hardening.sql =====================
-- Backend hardening for admin mutations, seasons, and payment configuration.
-- All changes are additive and preserve existing rows.

create or replace function private.ensure_current_season()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz := pg_catalog.date_trunc('month', clock_timestamp());
  v_end timestamptz := v_start + interval '1 month';
  v_slug text := 'campus-' || pg_catalog.to_char(v_start, 'YYYY-MM');
  v_id uuid;
begin
  perform pg_catalog.pg_advisory_xact_lock(938242);
  insert into public.seasons (slug, name, starts_at, ends_at)
  values (
    v_slug,
    'Campus Saison ' || pg_catalog.to_char(v_start, 'MM/YYYY'),
    v_start,
    v_end
  )
  on conflict (slug) do nothing;

  select s.id into v_id
  from public.seasons s
  where s.slug = v_slug;
  if v_id is null then raise exception 'season_creation_failed'; end if;
  return v_id;
end;
$$;

revoke all on function private.ensure_current_season() from public, anon, authenticated;

-- Prevent stale or guessed identifiers from being reported as successful admin
-- changes. The existing validation and PIN checks remain unchanged.
create or replace function public.admin_update_catalog(
  p_kind text, p_id text, p_values jsonb, p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_admin();
  pin_status text;
  changed integer;
  target_id uuid;
begin
  if p_kind not in ('shop', 'task', 'season')
     or jsonb_typeof(p_values) <> 'object'
  then
    return jsonb_build_object('ok', false, 'error', 'invalid_catalog');
  end if;
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then
    return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status);
  end if;

  if p_kind = 'shop' then
    begin
      target_id := p_id::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok', false, 'error', 'invalid_catalog_id');
    end;
    update public.marketplace_items
    set name = coalesce(nullif(left(p_values->>'name', 60), ''), name),
        description = coalesce(nullif(left(p_values->>'description', 180), ''), description),
        price = case when (p_values->>'price') ~ '^[0-9]+$'
          then greatest((p_values->>'price')::bigint, 1) else price end,
        active = coalesce((p_values->>'active')::boolean, active),
        updated_at = clock_timestamp()
    where id = target_id;
  elsif p_kind = 'task' then
    update public.daily_tasks
    set name = coalesce(nullif(left(p_values->>'name', 80), ''), name),
        description = coalesce(nullif(left(p_values->>'description', 180), ''), description),
        reward = case when (p_values->>'reward') ~ '^[0-9]+$'
          then greatest((p_values->>'reward')::bigint, 1) else reward end,
        target_count = case when (p_values->>'target_count') ~ '^[0-9]+$'
          then greatest((p_values->>'target_count')::integer, 1) else target_count end,
        active = coalesce((p_values->>'active')::boolean, active)
    where task_key = p_id;
  else
    begin
      target_id := p_id::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok', false, 'error', 'invalid_catalog_id');
    end;
    update public.seasons
    set name = coalesce(nullif(left(p_values->>'name', 60), ''), name),
        reward_first = case when (p_values->>'reward_first') ~ '^[0-9]+$'
          then greatest((p_values->>'reward_first')::bigint, 0) else reward_first end,
        reward_second = case when (p_values->>'reward_second') ~ '^[0-9]+$'
          then greatest((p_values->>'reward_second')::bigint, 0) else reward_second end,
        reward_third = case when (p_values->>'reward_third') ~ '^[0-9]+$'
          then greatest((p_values->>'reward_third')::bigint, 0) else reward_third end
    where id = target_id;
  end if;

  get diagnostics changed = row_count;
  if changed <> 1 then
    return jsonb_build_object('ok', false, 'error', 'catalog_not_found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_update_case(
  p_case_id uuid, p_status text, p_priority text, p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_admin();
  pin_status text;
  changed integer;
begin
  if p_status not in ('open', 'in_progress', 'waiting', 'closed')
     or p_priority not in ('low', 'normal', 'high', 'urgent')
  then
    return jsonb_build_object('ok', false, 'error', 'invalid_case');
  end if;
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then
    return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status);
  end if;
  update public.support_cases
  set status = p_status, priority = p_priority,
      assigned_to = actor, updated_at = clock_timestamp()
  where id = p_case_id;
  get diagnostics changed = row_count;
  if changed <> 1 then
    return jsonb_build_object('ok', false, 'error', 'case_not_found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Keep every public admin RPC unavailable to browser roles unless an earlier
-- migration explicitly grants authenticated execution. Service-role-only
-- delegation functions remain service-role-only.
do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'admin\_%' escape '\'
  loop
    execute format('revoke all on function %s from public, anon', fn.oid::regprocedure);
  end loop;
end;
$$;

revoke all on function public.admin_update_catalog(text, text, jsonb, text) from public, anon;
grant execute on function public.admin_update_catalog(text, text, jsonb, text) to authenticated;
revoke all on function public.admin_update_case(uuid, text, text, text) from public, anon;
grant execute on function public.admin_update_case(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20260915100500_release_terminal_blackjack_reservation.sql =====================
-- Release reservations for blackjack hands that finish during the initial deal.
-- Those sessions never transition through an UPDATE, so the existing release
-- trigger cannot otherwise remove their temporary loss reservation.
drop trigger if exists release_terminal_blackjack_loss_reservation on public.blackjack_sessions;
create trigger release_terminal_blackjack_loss_reservation
after insert on public.blackjack_sessions
for each row when (new.status <> 'active')
execute function private.release_game_loss_reservation();


-- ===================== 20260915110000_complete_admin_privacy_flows.sql =====================
-- Complete the admin/privacy flows with bounded reads and transactional writes.

create or replace function public.update_my_profile_atomic(
  p_username text,
  p_display_name text,
  p_bio text,
  p_profile_color text,
  p_avatar_url text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
  v_name text := pg_catalog.btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(pg_catalog.btrim(coalesce(p_bio, '')), '');
  v_color text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_profile_color, '')));
  v_avatar text := nullif(pg_catalog.btrim(coalesce(p_avatar_url, '')), '');
  v_current_avatar text;
begin
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_username');
  end if;
  if char_length(v_name) not between 2 and 60 then
    return jsonb_build_object('ok', false, 'error', 'invalid_display_name');
  end if;
  if v_bio is not null and char_length(v_bio) > 180 then
    return jsonb_build_object('ok', false, 'error', 'invalid_bio');
  end if;
  if v_color !~ '^#[0-9a-f]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_profile_color');
  end if;
  if exists (select 1 from public.profiles where lower(username) = v_username and id <> v_user_id) then
    return jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;
  select avatar_url into v_current_avatar from public.profiles where id = v_user_id for update;
  if v_avatar is distinct from v_current_avatar and v_avatar is not null
     and v_avatar !~ ('^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/avatars/'
       || v_user_id::text || '/[A-Za-z0-9._-]+$') then
    return jsonb_build_object('ok', false, 'error', 'invalid_avatar_url');
  end if;
  update public.profiles
  set username = v_username, display_name = v_name, bio = v_bio,
      profile_color = v_color, avatar_url = v_avatar, updated_at = clock_timestamp()
  where id = v_user_id;
  return jsonb_build_object('ok', true, 'username', v_username,
    'display_name', v_name, 'bio', v_bio, 'profile_color', v_color, 'avatar_url', v_avatar);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'username_taken');
end;
$$;

revoke all on function public.update_my_profile_atomic(text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.update_my_profile_atomic(text,text,text,text,text) to authenticated;

create or replace function public.admin_add_class_member(p_class_id uuid, p_user_id uuid, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare actor uuid := private.require_admin(); pin_status text;
begin
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status); end if;
  if not exists (select 1 from public.admin_classes where id = p_class_id)
     or not exists (select 1 from auth.users where id = p_user_id) then
    return jsonb_build_object('ok', false, 'error', 'class_or_user_not_found');
  end if;
  insert into public.admin_class_members(class_id, user_id) values (p_class_id, p_user_id)
  on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_remove_class_member(p_class_id uuid, p_user_id uuid, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare actor uuid := private.require_admin(); pin_status text;
begin
  pin_status := private.check_admin_pin(actor, p_pin);
  if pin_status <> 'ok' then return jsonb_build_object('ok', false, 'error', 'admin_pin_' || pin_status); end if;
  delete from public.admin_class_members where class_id = p_class_id and user_id = p_user_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_list_control_center_page(p_page integer default 1, p_page_size integer default 12)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare actor uuid := private.require_admin(); v_page integer := greatest(coalesce(p_page, 1), 1);
v_size integer := least(greatest(coalesce(p_page_size, 12), 1), 50); r jsonb;
begin
  select jsonb_build_object(
    'classes', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('members', coalesce((select jsonb_agg(m.user_id) from public.admin_class_members m where m.class_id = c.id), '[]'::jsonb)) order by c.created_at desc) from public.admin_classes c
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.support_cases t
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'exports', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.admin_export_requests e
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'privacy', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.privacy_requests p
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'shop', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.marketplace_items i
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order, t.task_key) from public.daily_tasks t
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb),
    'seasons', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at desc) from public.seasons s
      offset (v_page - 1) * v_size limit v_size), '[]'::jsonb)
  ) into r;
  return r;
end $$;

revoke all on function public.admin_add_class_member(uuid,uuid,text), public.admin_remove_class_member(uuid,uuid,text), public.admin_list_control_center_page(integer,integer) from public, anon;
grant execute on function public.admin_add_class_member(uuid,uuid,text), public.admin_remove_class_member(uuid,uuid,text), public.admin_list_control_center_page(integer,integer) to authenticated;


-- ===================== 20260915120000_add_ilja_as_primary_owner.sql =====================
-- Ilja erhält dieselben Haupt-Owner-Rechte wie Robyn: Bannen, Entbannen und
-- dauerhaftes Löschen fremder Konten, auch anderer Owner-Konten.
--
-- Robyn bleibt über die unveränderliche User-ID hinterlegt. Ilja wird über die
-- Login-E-Mail in auth.users aufgelöst; diese kann nur mit Bestätigung geändert
-- werden und ist für den Browser weder les- noch schreibbar. Beide Konten müssen
-- zusätzlich die Rolle super_admin besitzen. Alle Ban- und Löschfunktionen
-- (admin_apply_wallet_status, dessen v2-Variante, admin_authorize_account_deletion,
-- admin_finalize_account_deletion und der auth.users-Trigger) verwenden
-- private.is_primary_owner und übernehmen die Änderung automatisch.

create or replace function private.is_primary_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
    and exists (
      select 1
      from public.profiles p
      where p.id = p_user_id
        and p.role = 'super_admin'
    )
    and (
      p_user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'::uuid
      or exists (
        select 1
        from auth.users u
        where u.id = p_user_id
          and pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
      )
    );
$$;

revoke all on function private.is_primary_owner(uuid)
from public, anon, authenticated;

create or replace function public.get_my_admin_account_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_is_primary_owner boolean := false;
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object(
      'is_primary_owner', false,
      'can_manage_standard_accounts', false,
      'can_manage_owner_accounts', false
    );
  end if;

  select p.role into v_role
  from public.profiles p
  where p.id = v_user_id;

  v_is_primary_owner := private.is_primary_owner(v_user_id);

  return pg_catalog.jsonb_build_object(
    'is_primary_owner', v_is_primary_owner,
    'can_manage_standard_accounts', v_role = 'admin' or v_is_primary_owner,
    'can_manage_owner_accounts', v_is_primary_owner
  );
end;
$$;

revoke all on function public.get_my_admin_account_capabilities()
from public, anon;
grant execute on function public.get_my_admin_account_capabilities()
to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20260915121000_promote_ilja_to_super_admin.sql =====================
-- Ilja wird zur höchsten Rolle befördert: super_admin (Owner)
-- Mit dieser Rolle kann Ilja:
-- - Konten bannen/entbannen
-- - Konten dauerhaft löschen
-- - Admin-Rechte vergeben/entfernen
-- - Coins aus der Admin-Reserve gutschreiben/enziehen

update public.profiles
set role = 'super_admin'
where id in (
  select u.id
  from auth.users u
  where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
);

notify pgrst, 'reload schema';


-- ===================== 20260915123000_make_all_marketplace_titles_equipable.sql =====================
-- All five current marketplace items are profile titles and can be equipped.
update public.marketplace_items
set
  kind = 'title',
  cosmetic_value = case name
    when 'Neon Mint' then 'Neon Mint'
    when 'Electric Blue' then 'Electric Blue'
    when 'Royal Gold' then 'Royal Gold'
    else cosmetic_value
  end,
  updated_at = now()
where name in ('Neon Mint', 'Electric Blue', 'Royal Gold')
  and active = true;

