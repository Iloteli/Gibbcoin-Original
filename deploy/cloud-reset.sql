-- GIBB Coin: alles zurücksetzen. Behalten werden nur die Konten von
-- Ilja, Robyn, gianleomala, lpi164520 und xexobo9705. Alle anderen Konten werden gelöscht.
-- Zurückgesetzt werden: Blockchain, alle Transaktionen, Guthaben (10 GIBB Startguthaben),
-- Credits, Markt und Kurs, Spiele, Ranglisten, Diagramme, Belohnungen, Mitteilungen und Besucherstatistik.
-- Einstellungen, Aufgaben und Saisons bleiben erhalten.
--
-- Die ganze Datei in den Supabase SQL Editor einfügen und auf "Run" klicken (nichts markieren).
-- Alles läuft als EIN Block: Werden nicht genau 5 Konten gefunden oder tritt ein Fehler auf,
-- wird nichts geändert.

do $reset$
declare
  v_keep uuid[];
  v_ilja uuid;
  t text;
  k record;
  v_hashes text[];
  v_first bigint;
  v_last bigint;
  v_count integer;
  v_merkle text;
  v_timestamp bigint := floor(extract(epoch from now()))::bigint;
  v_zero text := repeat('0', 64);
begin
  select array_agg(u.id) into v_keep
  from auth.users u left join public.profiles p on p.id = u.id
  where lower(u.email) = 'ilja.podorieszach@icloud.com'
     or u.id = 'd465d88f-0acb-4bff-ad55-945761acaeea'
     or lower(coalesce(p.username, '')) in ('gianleomala', 'lpi164520', 'xexobo9705')
     or lower(coalesce(p.display_name, '')) in ('gianleomala', 'lpi164520', 'xexobo9705')
     or lower(split_part(u.email, '@', 1)) in ('gianleomala', 'lpi164520', 'xexobo9705');
  if coalesce(array_length(v_keep, 1), 0) <> 5 then
    raise exception 'Abbruch: % statt 5 Konten gefunden – nichts wurde geändert.', coalesce(array_length(v_keep, 1), 0);
  end if;
  select id into v_ilja from auth.users where lower(email) = 'ilja.podorieszach@icloud.com';

  -- 1) Verlauf, Ranglisten und Diagramme leeren (ohne Schutz-Trigger des Ledgers)
  perform set_config('session_replication_role', 'replica', true);
  foreach t in array array[
    'public.blocks', 'public.transactions', 'public.market_events', 'public.coin_purchases',
    'public.transfer_approval_audit', 'public.transfer_approvals', 'public.payment_requests',
    'public.game_rounds', 'public.blackjack_sessions', 'public.poker_sessions', 'public.dino_run_sessions',
    'public.game_leaderboard', 'public.daily_rewards', 'public.daily_task_claims', 'public.user_challenges',
    'public.season_rewards', 'public.purchases', 'public.notifications', 'public.site_visits',
    'public.group_wallet_entries', 'public.group_wallet_members', 'public.group_wallets', 'public.contacts',
    'public.abuse_reports', 'public.support_cases', 'public.session_diagnostics',
    'private.game_loss_reservations', 'private.wallet_stats_resets', 'private.admin_coin_stats_resets'
  ] loop
    if to_regclass(t) is not null then
      execute 'delete from ' || t;
    end if;
  end loop;
  update public.wallets set balance = 10, credits = 0, updated_at = now();
  update private.market_settings set price = 1, updated_at = now();
  perform set_config('session_replication_role', 'origin', true);

  -- 2) Ilja entbannen und als Owner sicherstellen (er gibt die Löschungen frei)
  update auth.users set banned_until = null where id = v_ilja;
  update public.wallets set status = 'active' where user_id = v_ilja;
  update public.profiles set role = 'super_admin' where id = v_ilja;

  -- 3) Alle anderen Konten löschen (Profile, Wallets usw. werden mitgelöscht)
  delete from private.account_deletion_authorizations;
  insert into private.account_deletion_authorizations (target_user_id, actor_user_id, actor_role, target_role, expires_at)
  select u.id, v_ilja, 'super_admin', coalesce(p.role, 'user'), now() + interval '10 minutes'
  from auth.users u left join public.profiles p on p.id = u.id
  where u.id <> all (v_keep);
  delete from auth.users where id <> all (v_keep);
  delete from private.account_deletion_authorizations;

  -- 4) Neue Kette: Startguthaben als Transaktionen, dann Genesis-Block
  for k in select w.user_id from public.wallets w order by w.created_at loop
    perform private.append_transaction(null, k.user_id, 10, 'INITIAL_BALANCE', 'Startguthaben (Neustart)');
  end loop;
  select coalesce(array_agg(x.hash order by x.chain_index), '{}'::text[]), min(x.chain_index), max(x.chain_index), count(*)
  into v_hashes, v_first, v_last, v_count
  from public.transactions x where x.block_height is null;
  v_merkle := private.merkle_root(v_hashes);
  insert into public.blocks (
    height, previous_hash, merkle_root, first_chain_index, last_chain_index, tx_count,
    mined_at, difficulty_bits, nonce, hash, miner_user_id, miner_label, reward
  ) values (
    0, v_zero, v_merkle, v_first, v_last, coalesce(v_count, 0),
    to_timestamp(v_timestamp), 0, 0, private.block_hash(0, v_zero, v_merkle, v_timestamp, 0, null, 0), null, 'Genesis', 0
  );
  update public.transactions set block_height = 0 where block_height is null;
end
$reset$;

-- Kontrolle: 5 Konten mit je 10 GIBB
select u.email, p.username, p.role, w.balance, w.credits
from auth.users u left join public.profiles p on p.id = u.id left join public.wallets w on w.user_id = u.id;
