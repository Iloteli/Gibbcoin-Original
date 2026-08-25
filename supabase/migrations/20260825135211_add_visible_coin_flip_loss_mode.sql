-- Harmless colleague prank: Admins and the Owner can adjust the visual coin-flip
-- odds. Prank rounds never change a wallet or create ledger transactions.
create table if not exists private.coin_flip_prank_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  win_chance smallint not null default 1 check (win_chance between 0 and 100),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into private.coin_flip_prank_settings (singleton, enabled, win_chance)
values (true, false, 1)
on conflict (singleton) do nothing;

revoke all on table private.coin_flip_prank_settings
from public, anon, authenticated;

do $migration$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.play_instant_game(text,text,bigint)'::pg_catalog.regprocedure
  ) into v_definition;

  if pg_catalog.strpos(v_definition, 'private.coin_flip_prank_settings') = 0 then
    v_old := $old$  v_label text;$old$;
    v_new := $new$  v_label text;
  v_prank_enabled boolean := false;
  v_prank_win_chance smallint := 1;$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game declarations changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    v_old := $old$  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;$old$;
    v_new := $new$  if exists (
    select 1 from public.game_rounds r
    where r.user_id = v_user_id and r.created_at > pg_catalog.clock_timestamp() - interval '700 milliseconds'
  ) then raise exception 'game_too_fast'; end if;

  if p_game_key = 'coin_flip' then
    select s.enabled, s.win_chance
    into v_prank_enabled, v_prank_win_chance
    from private.coin_flip_prank_settings s
    where s.singleton;
  end if;$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game throttle block changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    v_old := $old$    v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);$old$;
    v_new := $new$    if v_prank_enabled then
      if private.game_random(100) < v_prank_win_chance then
        v_result_text := p_choice;
      else
        v_result_text := case p_choice when 'kopf' then 'zahl' else 'kopf' end;
      end if;
    else
      v_result_text := case private.game_random(2) when 0 then 'kopf' else 'zahl' end;
    end if;
    if p_choice = v_result_text then v_payout := p_wager * 2; end if;
    v_result := pg_catalog.jsonb_build_object('side', v_result_text);$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game coin-flip block changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    v_old := $old$  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;$old$;
    v_new := $new$  if v_prank_enabled and p_game_key = 'coin_flip' then
    insert into public.game_rounds (user_id, game_key, choice, wager, payout, result)
    values (v_user_id, p_game_key, p_choice, p_wager, v_payout, v_result)
    returning id into v_round_id;

    return pg_catalog.jsonb_build_object(
      'ok', true, 'round_id', v_round_id, 'game_key', p_game_key,
      'choice', p_choice, 'wager', p_wager, 'payout', v_payout,
      'net', v_payout - p_wager, 'result', v_result,
      'balance', v_wallet.balance,
      'entry_transaction_id', null, 'reward_transaction_id', null
    );
  end if;

  update public.wallets set balance = balance - p_wager, updated_at = now() where id = v_wallet.id;$new$;
    if pg_catalog.strpos(v_definition, v_old) = 0 then
      raise exception 'play_instant_game wallet block changed unexpectedly';
    end if;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);

    execute v_definition;
  end if;
end;
$migration$;

create or replace function public.get_coin_flip_prank_admin_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid := private.require_admin();
  v_enabled boolean;
  v_win_chance smallint;
begin
  select s.enabled, s.win_chance
  into v_enabled, v_win_chance
  from private.coin_flip_prank_settings s
  where s.singleton;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'enabled', v_enabled,
    'win_chance', v_win_chance,
    'loss_chance', 100 - v_win_chance
  );
end;
$$;

create or replace function public.admin_set_coin_flip_prank(
  p_enabled boolean,
  p_win_chance integer,
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
  v_old_enabled boolean;
  v_old_win_chance smallint;
begin
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  if p_enabled is null or p_win_chance is null or p_win_chance < 0 or p_win_chance > 100 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_game_setting');
  end if;

  v_pin_status := private.check_admin_pin(v_admin_user_id, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select s.enabled, s.win_chance
  into v_old_enabled, v_old_win_chance
  from private.coin_flip_prank_settings s
  where s.singleton
  for update;

  update private.coin_flip_prank_settings
  set enabled = p_enabled,
      win_chance = p_win_chance::smallint,
      updated_by = v_admin_user_id,
      updated_at = now()
  where singleton;

  if v_old_enabled is distinct from p_enabled
     or v_old_win_chance is distinct from p_win_chance::smallint then
    perform private.write_admin_audit(
      v_admin_user_id,
      null,
      'GAME_SETTING_CHANGED',
      pg_catalog.jsonb_build_object(
        'game_key', 'coin_flip_prank',
        'enabled', v_old_enabled,
        'win_chance', v_old_win_chance
      ),
      pg_catalog.jsonb_build_object(
        'game_key', 'coin_flip_prank',
        'enabled', p_enabled,
        'win_chance', p_win_chance
      ),
      'Münzwurf-Spaßmodus geändert'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'enabled', p_enabled,
    'win_chance', p_win_chance,
    'loss_chance', 100 - p_win_chance
  );
end;
$$;

revoke all on function public.play_instant_game(text, text, bigint)
from public, anon, authenticated;
revoke all on function public.get_coin_flip_prank_admin_state()
from public, anon, authenticated;
revoke all on function public.admin_set_coin_flip_prank(boolean, integer, text)
from public, anon, authenticated;

grant execute on function public.play_instant_game(text, text, bigint)
to authenticated;
grant execute on function public.get_coin_flip_prank_admin_state()
to authenticated;
grant execute on function public.admin_set_coin_flip_prank(boolean, integer, text)
to authenticated;
