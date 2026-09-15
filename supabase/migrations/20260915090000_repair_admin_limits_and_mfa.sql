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
