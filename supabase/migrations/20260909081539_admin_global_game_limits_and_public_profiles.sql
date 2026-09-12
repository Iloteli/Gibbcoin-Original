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
