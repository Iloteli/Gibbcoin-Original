-- Gewinnchancen der Sofort-Spiele einstellbar (Chain-Seite, Recht "Spiele verwalten").
-- Faktor pro Spiel: 100 % = faire Grundchance, 50 % = halb so oft gewinnen, 150 % = 1,5-mal so oft.
-- Gilt für alle gleich (nicht pro Person) und wird den Spielern in den Regeln angezeigt.
create table if not exists private.game_odds (
  game_key text primary key check (game_key in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko')),
  factor numeric(5, 2) not null default 1 check (factor >= 0 and factor <= 3),
  updated_at timestamptz not null default now()
);
alter table private.game_odds enable row level security;

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
  v_factor numeric;
  v_natural numeric;
  v_lose numeric;
  v_target numeric;
  v_roll numeric;
  v_swap integer;
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

  -- Gewinnchance anpassen (Faktor pro Spiel, 100 % = faire Grundchance).
  -- Das Ergebnis wird danach so umgestellt, dass es zur Auszahlung passt.
  select o.factor into v_factor from private.game_odds o where o.game_key = p_game_key;
  v_factor := coalesce(v_factor, 1);
  if v_factor <> 1 then
    v_natural := case p_game_key
      when 'coin_flip' then 0.5
      when 'dice_duel' then 15.0 / 36
      when 'high_card' then 6.0 / 13
      when 'plinko' then 2.0 / 9
      else case when p_choice in ('rot', 'schwarz') then 18.0 / 37 else 1.0 / 37 end
    end;
    v_lose := case p_game_key
      when 'coin_flip' then 0.5
      when 'dice_duel' then 15.0 / 36
      when 'high_card' then 6.0 / 13
      when 'plinko' then 5.0 / 9
      else case when p_choice in ('rot', 'schwarz') then 19.0 / 37 else 36.0 / 37 end
    end;
    v_target := least(v_natural * v_factor, 0.95);
    v_roll := private.game_random(1000000)::numeric / 1000000;
    if v_payout > p_wager and v_target < v_natural and v_roll < 1 - v_target / v_natural then
      -- Gewinn wird zu Verlust
      if p_game_key = 'coin_flip' then
        v_result_text := case p_choice when 'kopf' then 'zahl' else 'kopf' end;
        v_result := pg_catalog.jsonb_build_object('side', v_result_text);
      elsif p_game_key in ('dice_duel', 'high_card') then
        v_swap := v_user_roll; v_user_roll := v_house_roll; v_house_roll := v_swap;
        v_result_text := v_user_roll || ' zu ' || v_house_roll;
        v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
      elsif p_game_key = 'plinko' then
        v_plinko_slot := 2 + private.game_random(5);
        v_plinko_multiplier := 0;
        v_result_text := 'Fach ' || (v_plinko_slot + 1) || ' · 0x';
        v_result := pg_catalog.jsonb_build_object('slot', v_plinko_slot, 'multiplier', 0, 'status', 'lost');
      else
        loop
          v_number := private.game_random(37);
          v_color := case when v_number = 0 then 'grün'
            when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot' else 'schwarz' end;
          exit when p_choice <> v_number::text and p_choice <> v_color;
        end loop;
        v_result_text := v_number || ' · ' || v_color;
        v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
      end if;
      v_payout := 0;
    elsif v_payout = 0 and v_target > v_natural and v_roll < (v_target - v_natural) / v_lose then
      -- Verlust wird zu Gewinn
      if p_game_key = 'coin_flip' then
        v_result_text := p_choice;
        v_result := pg_catalog.jsonb_build_object('side', v_result_text);
        v_payout := p_wager * 2;
      elsif p_game_key in ('dice_duel', 'high_card') then
        v_swap := v_user_roll; v_user_roll := v_house_roll; v_house_roll := v_swap;
        v_result_text := v_user_roll || ' zu ' || v_house_roll;
        v_result := pg_catalog.jsonb_build_object('player', v_user_roll, 'house', v_house_roll);
        v_payout := p_wager * 2;
      elsif p_game_key = 'plinko' then
        v_plinko_slot := case private.game_random(2) when 0 then 0 else 8 end;
        v_plinko_multiplier := 3;
        v_payout := p_wager * 3;
        v_result_text := 'Fach ' || (v_plinko_slot + 1) || ' · 3x';
        v_result := pg_catalog.jsonb_build_object('slot', v_plinko_slot, 'multiplier', 3, 'status', 'won');
      else
        if p_choice in ('rot', 'schwarz') then
          loop
            v_number := 1 + private.game_random(36);
            v_color := case when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot' else 'schwarz' end;
            exit when v_color = p_choice;
          end loop;
          v_payout := p_wager * 2;
        else
          v_number := p_choice::integer;
          v_color := case when v_number = 0 then 'grün'
            when v_number = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'rot' else 'schwarz' end;
          v_payout := p_wager * 36;
        end if;
        v_result_text := v_number || ' · ' || v_color;
        v_result := pg_catalog.jsonb_build_object('number', v_number, 'color', v_color);
      end if;
    end if;
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

revoke all on function public.play_instant_game(text, text, bigint) from public, anon;
grant execute on function public.play_instant_game(text, text, bigint) to authenticated;

-- Für die Spiele-Seite: aktuelle Faktoren (alle Spieler sehen sie in den Regeln)
create or replace function public.get_game_odds()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_object_agg(o.game_key, o.factor), '{}'::jsonb) from private.game_odds o;
$$;
revoke all on function public.get_game_odds() from public, anon;
grant execute on function public.get_game_odds() to authenticated;

create or replace function public.node_get_game_odds(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'odds', public.get_game_odds());
end;
$$;
revoke all on function public.node_get_game_odds(text) from public;
grant execute on function public.node_get_game_odds(text) to anon, authenticated, service_role;

create or replace function public.node_set_game_odds(p_key text, p_odds jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_game text;
  v_factor numeric;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_odds is null or pg_catalog.jsonb_typeof(p_odds) <> 'object' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  for v_game, v_factor in select k, (v #>> '{}')::numeric from pg_catalog.jsonb_each(p_odds) as e(k, v) loop
    if v_game not in ('roulette', 'coin_flip', 'dice_duel', 'high_card', 'plinko') or v_factor is null or v_factor < 0 or v_factor > 3 then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_odds');
    end if;
    insert into private.game_odds (game_key, factor) values (v_game, pg_catalog.round(v_factor, 2))
    on conflict (game_key) do update set factor = excluded.factor, updated_at = pg_catalog.now();
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'odds', public.get_game_odds());
end;
$$;
revoke all on function public.node_set_game_odds(text, jsonb) from public;
grant execute on function public.node_set_game_odds(text, jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
