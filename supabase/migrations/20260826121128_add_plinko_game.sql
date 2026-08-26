-- Add Plinko as a server-authoritative wallet game and extend the existing
-- visual-only Admin/Owner game controls. The visual mode never changes wallet
-- balances, ledger entries, statistics or game history.

alter table public.game_settings
  drop constraint if exists game_settings_game_key_check;
alter table public.game_settings
  add constraint game_settings_game_key_check check (game_key in (
    'game_center', 'roulette', 'coin_flip', 'blackjack',
    'dice_duel', 'high_card', 'poker', 'plinko', 'dino_run'
  ));

alter table public.game_rounds
  drop constraint if exists game_rounds_game_key_check;
alter table public.game_rounds
  add constraint game_rounds_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko', 'dino_run'
  ));

alter table private.game_prank_settings
  drop constraint if exists game_prank_settings_game_key_check;
alter table private.game_prank_settings
  add constraint game_prank_settings_game_key_check check (game_key in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko'
  ));

insert into public.game_settings (game_key, label, enabled, sort_order)
values ('plinko', 'Plinko', true, 70)
on conflict (game_key) do update
set label = excluded.label,
    sort_order = excluded.sort_order;

update public.game_settings
set sort_order = 80
where game_key = 'dino_run' and sort_order <= 70;

insert into private.game_prank_settings (game_key, enabled, win_chance)
values ('plinko', false, 50)
on conflict (game_key) do nothing;

create or replace function public.get_game_extras_admin_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_games jsonb;
  v_dino jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'game_key', s.game_key,
    'label', case s.game_key
      when 'roulette' then 'Roulette'
      when 'coin_flip' then 'Münzwurf'
      when 'blackjack' then 'Blackjack'
      when 'dice_duel' then 'Würfelduell'
      when 'high_card' then 'High Card'
      when 'poker' then '5-Karten-Poker'
      when 'plinko' then 'Plinko'
    end,
    'enabled', s.enabled,
    'win_chance', s.win_chance,
    'scope', case when s.target_user_id is null then 'all' else 'user' end,
    'target_username', p.username,
    'target_display_name', p.display_name
  ) order by case s.game_key
    when 'roulette' then 1 when 'coin_flip' then 2 when 'blackjack' then 3
    when 'dice_duel' then 4 when 'high_card' then 5 when 'poker' then 6
    when 'plinko' then 7
  end), '[]'::jsonb)
  into v_games
  from private.game_prank_settings s
  left join public.profiles p on p.id = s.target_user_id;

  select pg_catalog.jsonb_build_object(
    'speed_level', d.speed_level,
    'difficulty_level', d.difficulty_level
  ) into v_dino
  from private.dino_game_settings d
  where d.singleton;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'games', v_games,
    'dino', v_dino
  );
end;
$$;

create or replace function public.admin_set_game_visual_prank(
  p_game_key text,
  p_enabled boolean,
  p_win_chance integer,
  p_scope text,
  p_target_username text,
  p_pin text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_pin_status text;
  v_target_user_id uuid;
  v_old private.game_prank_settings%rowtype;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);

  if p_game_key is null or p_game_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko'
  ) or p_enabled is null or p_win_chance is null
    or p_win_chance < 0 or p_win_chance > 100
    or p_scope is null or p_scope not in ('all', 'user') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting');
  end if;

  if p_scope = 'user' then
    if pg_catalog.btrim(coalesce(p_target_username, '')) = '' then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_username_required');
    end if;
    select p.id into v_target_user_id
    from public.profiles p
    where pg_catalog.lower(p.username) = pg_catalog.lower(pg_catalog.btrim(p_target_username))
    limit 1;
    if v_target_user_id is null then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'target_user_not_found');
    end if;
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select s.* into v_old
  from private.game_prank_settings s
  where s.game_key = p_game_key
  for update;

  update private.game_prank_settings
  set enabled = p_enabled,
      win_chance = p_win_chance::smallint,
      target_user_id = case when p_scope = 'user' then v_target_user_id else null end,
      updated_by = v_admin_user_id,
      updated_at = pg_catalog.clock_timestamp()
  where game_key = p_game_key;

  if v_old.enabled is distinct from p_enabled
     or v_old.win_chance is distinct from p_win_chance::smallint
     or v_old.target_user_id is distinct from v_target_user_id then
    perform private.write_admin_audit(
      v_admin_user_id,
      case when p_scope = 'user' then v_target_user_id else null end,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', p_game_key || '_visual',
        'enabled', v_old.enabled,
        'win_chance', v_old.win_chance,
        'target_user_id', v_old.target_user_id
      ),
      pg_catalog.jsonb_build_object(
        'game_key', p_game_key || '_visual',
        'enabled', p_enabled,
        'win_chance', p_win_chance,
        'scope', p_scope,
        'target_user_id', v_target_user_id
      ),
      'Rein visuellen Spielmodus geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

create or replace function public.play_instant_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_payout bigint := 0;
  v_result jsonb := '{}'::jsonb;
  v_result_text text;
  v_round_id uuid;
  v_entry_id uuid;
  v_reward_id uuid;
  v_number integer;
  v_user_roll integer;
  v_house_roll integer;
  v_color text;
  v_label text;
  v_plinko_slot integer;
  v_plinko_multiplier integer;
begin
  p_game_key := pg_catalog.lower(pg_catalog.btrim(coalesce(p_game_key, '')));
  p_choice := pg_catalog.lower(pg_catalog.btrim(coalesce(p_choice, '')));
  if p_game_key not in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko') then
    raise exception 'invalid_game';
  end if;
  if p_wager is null or p_wager < 1 then
    raise exception 'invalid_game_wager';
  end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  if p_game_key = 'roulette' and p_choice not in (
    'rot', 'schwarz', '0','1','2','3','4','5','6','7','8','9','10','11','12',
    '13','14','15','16','17','18','19','20','21','22','23','24','25','26',
    '27','28','29','30','31','32','33','34','35','36'
  ) then
    raise exception 'invalid_game_choice';
  elsif p_game_key = 'coin_flip' and p_choice not in ('kopf', 'zahl') then
    raise exception 'invalid_game_choice';
  elsif p_game_key in ('dice_duel', 'high_card', 'plinko') and p_choice <> 'spielen' then
    raise exception 'invalid_game_choice';
  end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id
  for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;
  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id
      and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  if p_game_key = 'roulette' then
    v_label := 'Roulette';
    v_number := private.game_random(37);
    v_color := case
      when v_number = 0 then 'grün'
      when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot'
      else 'schwarz'
    end;
    if p_choice = v_number::text then v_payout := p_wager * 36;
    elsif p_choice = v_color then v_payout := p_wager * 2;
    end if;
    v_result_text := v_number || ' · ' || v_color;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
  elsif p_game_key = 'coin_flip' then
    v_label := 'Münzwurf';
    v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);
  elsif p_game_key = 'dice_duel' then
    v_label := 'Würfelduell';
    v_user_roll := private.game_random(6) + 1;
    v_house_roll := private.game_random(6) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  elsif p_game_key = 'high_card' then
    v_label := 'High Card';
    v_user_roll := private.game_random(13) + 1;
    v_house_roll := private.game_random(13) + 1;
    if v_user_roll > v_house_roll then v_payout := p_wager * 2;
    elsif v_user_roll = v_house_roll then v_payout := p_wager;
    end if;
    v_result_text := v_user_roll || ' zu ' || v_house_roll;
    v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
  else
    v_label := 'Plinko';
    v_plinko_slot := private.game_random(9);
    v_plinko_multiplier := case v_plinko_slot
      when 0 then 3 when 1 then 1 when 7 then 1 when 8 then 3 else 0
    end;
    v_payout := p_wager * v_plinko_multiplier;
    v_result_text := 'Fach ' || (v_plinko_slot + 1) || ' · ' || v_plinko_multiplier || 'x';
    v_result := pg_catalog.jsonb_build_object(
      'slot', v_plinko_slot,
      'multiplier', v_plinko_multiplier,
      'status', case when v_payout > p_wager then 'won'
        when v_payout = p_wager then 'push' else 'lost' end
    );
  end if;

  update public.wallets
  set balance = balance - p_wager, updated_at = now()
  where id = v_wallet.id;
  v_entry_id := private.append_transaction(
    v_user_id, null, p_wager, 'GAME_ENTRY',
    'Game Center · ' || v_label || ' · Einsatz'
  );
  if v_payout > 0 then
    update public.wallets
    set balance = balance + v_payout, updated_at = now()
    where id = v_wallet.id;
    v_reward_id := private.append_transaction(
      null, v_user_id, v_payout, 'GAME_REWARD',
      'Game Center · ' || v_label || ' · Ergebnis ' || v_result_text
    );
  end if;

  insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
  values (v_user_id, p_game_key, p_choice, p_wager, v_payout, v_result)
  returning id into v_round_id;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'round_id', v_round_id, 'game_key', p_game_key,
    'choice', p_choice, 'wager', p_wager, 'payout', v_payout,
    'net', v_payout - p_wager, 'result', v_result,
    'balance', v_wallet.balance - p_wager + v_payout,
    'entry_transaction_id', v_entry_id, 'reward_transaction_id', v_reward_id
  );
end;
$$;

create or replace function public.play_visual_prank_game(
  p_game_key text,
  p_choice text,
  p_wager bigint
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_wallet public.wallets%rowtype;
  v_setting private.game_prank_settings%rowtype;
  v_win boolean;
  v_payout numeric := 0;
  v_result jsonb := '{}'::jsonb;
  v_number integer;
  v_color text;
  v_plinko_slot integer;
begin
  if p_game_key is null or p_game_key not in (
    'roulette', 'coin_flip', 'blackjack', 'dice_duel',
    'high_card', 'poker', 'plinko'
  ) then raise exception 'invalid_game'; end if;
  if p_wager is null or p_wager < 1 then raise exception 'invalid_game_wager'; end if;
  if not private.game_is_enabled(p_game_key) then raise exception 'game_disabled'; end if;

  select w.* into v_wallet
  from public.wallets w
  where w.user_id = v_user_id;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_wallet.balance < p_wager then raise exception 'insufficient_balance'; end if;

  select s.* into v_setting
  from private.game_prank_settings s
  where s.game_key = p_game_key
    and s.enabled
    and (s.target_user_id is null or s.target_user_id = v_user_id);
  if v_setting.game_key is null then raise exception 'visual_prank_inactive'; end if;

  v_win := private.game_random(100) < v_setting.win_chance;

  if p_game_key = 'roulette' then
    if coalesce(p_choice, '') ~ '^(0|[1-9]|[12][0-9]|3[0-6])$' then
      if v_win then v_number := p_choice::integer;
      else v_number := (p_choice::integer + 1 + private.game_random(36)) % 37; end if;
      v_payout := case when v_win then p_wager::numeric * 36 else 0 end;
    elsif p_choice in ('rot', 'schwarz') then
      if v_win then v_number := case p_choice when 'rot' then 1 else 2 end;
      else v_number := case p_choice when 'rot' then 2 else 1 end; end if;
      v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
    else raise exception 'invalid_roulette_choice'; end if;
    v_color := case when v_number = 0 then 'grün'
      when v_number in (1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36) then 'rot'
      else 'schwarz' end;
    v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
  elsif p_game_key = 'coin_flip' then
    if p_choice not in ('kopf', 'zahl') then raise exception 'invalid_coin_choice'; end if;
    v_result := pg_catalog.jsonb_build_object(
      'side', case when v_win then p_choice
        when p_choice = 'kopf' then 'zahl' else 'kopf' end
    );
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'dice_duel' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object('player', 6, 'house', 1)
      else pg_catalog.jsonb_build_object('player', 1, 'house', 6) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'high_card' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object('player', 13, 'house', 1)
      else pg_catalog.jsonb_build_object('player', 1, 'house', 13) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'blackjack' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object(
        'status', 'won', 'player_cards', pg_catalog.jsonb_build_array(10, 10),
        'dealer_cards', pg_catalog.jsonb_build_array(10, 8),
        'player_score', 20, 'dealer_score', 18
      )
      else pg_catalog.jsonb_build_object(
        'status', 'lost', 'player_cards', pg_catalog.jsonb_build_array(10, 7),
        'dealer_cards', pg_catalog.jsonb_build_array(10, 10),
        'player_score', 17, 'dealer_score', 20
      ) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  elsif p_game_key = 'poker' then
    v_result := case when v_win
      then pg_catalog.jsonb_build_object(
        'status', 'finished', 'cards', pg_catalog.jsonb_build_array(0, 13, 28, 42, 5),
        'hand', 'Ein Paar', 'multiplier', 2
      )
      else pg_catalog.jsonb_build_object(
        'status', 'finished', 'cards', pg_catalog.jsonb_build_array(0, 14, 28, 42, 5),
        'hand', 'Hohe Karte', 'multiplier', 0
      ) end;
    v_payout := case when v_win then p_wager::numeric * 2 else 0 end;
  else
    if p_choice <> 'spielen' then raise exception 'invalid_game_choice'; end if;
    v_plinko_slot := case when v_win
      then case private.game_random(2) when 0 then 0 else 8 end
      else 4
    end;
    v_payout := case when v_win then p_wager::numeric * 3 else 0 end;
    v_result := pg_catalog.jsonb_build_object(
      'slot', v_plinko_slot,
      'multiplier', case when v_win then 3 else 0 end,
      'status', case when v_win then 'won' else 'lost' end
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'game_key', p_game_key,
    'choice', p_choice,
    'wager', p_wager,
    'payout', v_payout,
    'net', v_payout - p_wager,
    'result', v_result,
    'balance', v_wallet.balance,
    'visual_only', true,
    'entry_transaction_id', null,
    'reward_transaction_id', null
  );
end;
$$;

revoke all on function public.get_game_extras_admin_state()
from public, anon, authenticated;
revoke all on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text)
from public, anon, authenticated;
revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.play_visual_prank_game(text, text, bigint)
from public, anon, authenticated;

grant execute on function public.get_game_extras_admin_state()
to authenticated;
grant execute on function public.admin_set_game_visual_prank(text, boolean, integer, text, text, text)
to authenticated;
grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.play_visual_prank_game(text, text, bigint)
to authenticated;
