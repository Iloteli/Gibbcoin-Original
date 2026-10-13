-- GIBB Coin: alles zurücksetzen. Behalten werden nur die Konten von
-- Ilja, Robyn, gianleomala und lpi164520. Alle anderen Konten werden gelöscht.
-- Zurückgesetzt werden: Blockchain, alle Transaktionen, Guthaben (10 GIBB Startguthaben),
-- Credits, Markt und Kurs, Spiele, Ranglisten, Belohnungen, Mitteilungen und Besucherstatistik.
-- Einstellungen, Shop-Artikel, Aufgaben und Saisons bleiben erhalten.
--
-- SCHRITT 1 (nur anschauen): Diese Abfrage muss GENAU 4 Konten zeigen.
--
--   select u.id, u.email, p.username, p.display_name, p.role
--   from auth.users u left join public.profiles p on p.id = u.id
--   where lower(u.email) = 'ilja.podorieszach@icloud.com'
--      or u.id = 'd465d88f-0acb-4bff-ad55-945761acaeea'
--      or lower(coalesce(p.username, '')) in ('gianleomala', 'lpi164520')
--      or lower(coalesce(p.display_name, '')) in ('gianleomala', 'lpi164520')
--      or lower(split_part(u.email, '@', 1)) in ('gianleomala', 'lpi164520');
--
-- SCHRITT 2: Ab hier alles ausführen. Bricht ab, wenn nicht genau 4 Konten gefunden werden.

begin;

create temporary table reset_keep on commit drop as
select u.id from auth.users u left join public.profiles p on p.id = u.id
where lower(u.email) = 'ilja.podorieszach@icloud.com'
   or u.id = 'd465d88f-0acb-4bff-ad55-945761acaeea'
   or lower(coalesce(p.username, '')) in ('gianleomala', 'lpi164520')
   or lower(coalesce(p.display_name, '')) in ('gianleomala', 'lpi164520')
   or lower(split_part(u.email, '@', 1)) in ('gianleomala', 'lpi164520');

do $$
begin
  if (select count(*) from reset_keep) <> 4 then
    raise exception 'Abbruch: % statt 4 Konten gefunden – nichts wurde geändert.', (select count(*) from reset_keep);
  end if;
end $$;

-- 1) Verlauf und Statistiken leeren (ohne Schutz-Trigger, die Löschungen im Ledger verbieten)
set local session_replication_role = replica;
do $$
declare
  t text;
begin
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
end $$;

update public.wallets set balance = 10, credits = 0, updated_at = now();
update private.market_settings set price = 1, updated_at = now();
set local session_replication_role = origin;

-- 2) Ilja entbannen und als Owner sicherstellen (er gibt die Löschungen frei)
update auth.users set banned_until = null where lower(email) = 'ilja.podorieszach@icloud.com';
update public.wallets set status = 'active'
where user_id in (select id from auth.users where lower(email) = 'ilja.podorieszach@icloud.com');
update public.profiles set role = 'super_admin'
where id in (select id from auth.users where lower(email) = 'ilja.podorieszach@icloud.com');

-- 3) Alle anderen Konten löschen (Profile, Wallets usw. werden mitgelöscht)
delete from private.account_deletion_authorizations;
insert into private.account_deletion_authorizations (target_user_id, actor_user_id, actor_role, target_role, expires_at)
select u.id, (select id from auth.users where lower(email) = 'ilja.podorieszach@icloud.com'), 'super_admin',
       coalesce(p.role, 'user'), now() + interval '10 minutes'
from auth.users u left join public.profiles p on p.id = u.id
where u.id not in (select id from reset_keep);
delete from auth.users where id not in (select id from reset_keep);
delete from private.account_deletion_authorizations;
delete from private.ledger_identities where id not in (select id from reset_keep);

-- 4) Neue Kette: Startguthaben als Transaktionen, dann Genesis-Block
do $$
declare
  k record;
  v_hashes text[];
  v_first bigint;
  v_last bigint;
  v_count integer;
  v_merkle text;
  v_timestamp bigint := floor(extract(epoch from now()))::bigint;
  v_zero text := repeat('0', 64);
begin
  for k in select w.user_id from public.wallets w order by w.created_at loop
    perform private.append_transaction(null, k.user_id, 10, 'INITIAL_BALANCE', 'Startguthaben (Neustart)');
  end loop;
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
end $$;

commit;

-- Kontrolle: 4 Konten mit je 10 GIBB, Kette gültig
select u.email, p.username, p.role, w.balance, w.credits
from auth.users u left join public.profiles p on p.id = u.id left join public.wallets w on w.user_id = u.id;
