-- GIBB Coin: Datenbank prüfen (Supabase SQL Editor)
-- 1. Unten bei KONTO den Benutzernamen eines TEST-Kontos eintragen (z. B. das Konto, das sich nicht löschen lässt).
-- 2. Alles einfügen und auf "Run" klicken.
-- Es wird NICHTS dauerhaft geändert: Löschen und Bannen werden nur ausprobiert und sofort rückgängig gemacht.

create or replace function pg_temp.gibb_pruefen(p_username text)
returns table(pruefung text, ergebnis text)
language plpgsql
as $$
declare
  v_user uuid;
  v_owner uuid;
  v_missing text;
  v_result jsonb;
begin
  -- Fehlende Funktionen (Hauptseite und Chain-Seite)
  select string_agg(n, ', ' order by n) into v_missing
  from unnest(array[
    'accept_guardian_invitation',
    'blackjack_action',
    'cancel_bank_order',
    'cancel_my_payout',
    'create_bank_order',
    'create_group_wallet',
    'create_guardian_invitation',
    'create_payment_request',
    'create_privacy_request',
    'decide_transfer_approval',
    'delete_my_bank_order',
    'deposit_group_coins',
    'get_bank_details',
    'get_block_template',
    'get_block_transactions',
    'get_blockchain_overview',
    'get_challenge_progress',
    'get_community_leaderboard',
    'get_daily_tasks',
    'get_dino_leaderboard',
    'get_game_center_state',
    'get_game_leaderboard',
    'get_game_wager_limits',
    'get_market_state',
    'get_my_avatar_blocked',
    'get_my_player_safety',
    'get_my_visual_role',
    'get_payout_state',
    'get_public_admin_notice',
    'get_public_profile_extras',
    'get_public_user_profile',
    'get_recipient',
    'get_season_state',
    'get_site_features',
    'get_support_access',
    'get_transfer_approval_context',
    'join_group_wallet',
    'leave_group_wallet',
    'list_contacts',
    'list_group_history',
    'list_group_members',
    'list_my_abuse_reports',
    'list_my_group_wallets',
    'list_transfer_approvals',
    'market_quote',
    'my_session_revoked_at',
    'my_wallet_stats_reset',
    'node_adjust_balance',
    'node_allow_signup',
    'node_bulk_adjust',
    'node_credit_mining_reward',
    'node_decide_bank_order',
    'node_decide_payout',
    'node_delete_account',
    'node_delete_bank_orders',
    'node_delete_support_case',
    'node_existing_users',
    'node_get_announcement',
    'node_get_game_odds',
    'node_get_game_wager_limits',
    'node_get_profile',
    'node_list_bank_orders',
    'node_list_merchants',
    'node_list_payouts',
    'node_list_users',
    'node_list_verified_buyers',
    'node_logout_user',
    'node_mining_reward',
    'node_owner_call',
    'node_owner_login_email',
    'node_owner_stats',
    'node_password_reset',
    'node_push_settings',
    'node_set_account_status',
    'node_set_admin_features',
    'node_set_announcement',
    'node_set_avatar_blocked',
    'node_set_bank_address',
    'node_set_bank_settings',
    'node_set_buyer_verified',
    'node_set_footer',
    'node_set_game_odds',
    'node_set_game_wager_limits',
    'node_set_merchant',
    'node_set_owner_levels',
    'node_set_payment_methods',
    'node_set_payouts',
    'node_set_registration',
    'node_set_reserved_usernames',
    'node_set_site_design',
    'node_set_site_tabs',
    'node_update_profile',
    'payout_group_coins',
    'play_casino_game',
    'play_instant_game',
    'poker_draw',
    'record_site_visit',
    'refresh_my_wallet_status',
    'remove_contact',
    'rename_group_wallet',
    'request_data_export',
    'request_payout',
    'request_payout_gibb',
    'reset_my_wallet_stats',
    'respond_payment_request',
    'save_contact',
    'search_users',
    'set_contact_favorite',
    'set_group_member_role',
    'shop_cancel_invoice',
    'shop_create_invoice',
    'shop_invoice_info',
    'shop_invoice_status',
    'shop_list_sales',
    'shop_pay_invoice',
    'shop_status',
    'start_blackjack',
    'start_dino_run',
    'start_my_game_break',
    'start_poker',
    'submit_abuse_report',
    'submit_mined_block',
    'support_list_all',
    'support_update_case',
    'support_update_report',
    'sync_dino_run',
    'transfer_coins_with_guardian_approval',
    'update_my_player_safety',
    'update_my_profile_atomic',
    'verify_blockchain',
    'verify_hash_chain',
    'withdraw_group_coins'
  ]) as n
  where not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = n);
  pruefung := 'Funktionen der Hauptseite und Chain-Seite'; ergebnis := coalesce('FEHLT: ' || v_missing, 'ok – alle vorhanden'); return next;

  pruefung := 'Admin-Protokoll mit 7 Angaben (Fix Konto löschen/Bannen)';
  ergebnis := case when to_regprocedure('private.write_admin_audit(uuid,uuid,text,jsonb,jsonb,text,jsonb)') is not null then 'ok' else 'FEHLT – Fix (cloud-update-admin-audit.sql) noch nicht ausgeführt' end; return next;

  pruefung := 'Abmelden/Bannen mit eigener Dauer (Migration Okt. 2026)';
  ergebnis := case when to_regprocedure('public.node_logout_user(text,uuid)') is not null then 'ok' else 'FEHLT – cloud-update-ban-logout.sql ausführen' end; return next;

  pruefung := 'Schlüssel der Chain-Seite hinterlegt';
  begin
    ergebnis := case when exists (select 1 from private.node_settings_key k where k.singleton) then 'ok' else 'FEHLT – auf dem Server: sudo gibb-chain-key' end;
  exception when others then ergebnis := 'FEHLER: ' || sqlerrm; end;
  return next;

  begin v_owner := private.node_act_as_owner(); exception when others then v_owner := null; end;
  pruefung := 'Owner-Konto (Ilja) gefunden'; ergebnis := case when v_owner is null then 'FEHLT – Owner-Konto nicht gefunden' else 'ok' end; return next;

  select p.id into v_user from public.profiles p where lower(p.username) = lower(p_username);
  pruefung := 'Test-Konto ' || coalesce(p_username, '?'); ergebnis := case when v_user is null then 'nicht gefunden – Benutzernamen oben prüfen' else 'gefunden' end; return next;
  if v_user is null or v_owner is null then return; end if;

  -- Konto löschen ausprobieren (wie die Chain-Seite) und rückgängig machen
  pruefung := 'Konto löschen (Test, wird rückgängig gemacht)';
  begin
    -- Freigabe wie nach richtiger Admin-PIN (admin_authorize_account_deletion), nur für diesen Test
    insert into private.ledger_identities (id) values (v_user) on conflict (id) do nothing;
    insert into private.account_deletion_authorizations (target_user_id, actor_user_id, actor_role, target_role, expires_at, consumed_at, created_at)
    values (v_user, v_owner, (select role from public.profiles where id = v_owner), (select role from public.profiles where id = v_user), now() + interval '2 minutes', null, now())
    on conflict (target_user_id) do update set actor_user_id = excluded.actor_user_id, actor_role = excluded.actor_role,
      target_role = excluded.target_role, expires_at = excluded.expires_at, consumed_at = null, created_at = excluded.created_at;
    delete from auth.users where id = v_user;
    v_result := public.admin_finalize_account_deletion(v_owner, v_user);
    if coalesce((v_result ->> 'ok')::boolean, false) is not true then raise exception 'Abschluss: %', coalesce(v_result ->> 'error', v_result::text); end if;
    raise exception 'GIBB_TEST_OK';
  exception when others then
    ergebnis := case when sqlerrm = 'GIBB_TEST_OK' then 'ok' else 'FEHLER: ' || sqlerrm end;
  end;
  return next;

  -- Bannen ausprobieren und rückgängig machen
  pruefung := 'Bannen (Test, wird rückgängig gemacht)';
  begin
    update auth.users set banned_until = now() + interval '1 hour' where id = v_user;
    perform public.admin_apply_wallet_status_v2(v_owner, v_user, 'locked', 'Test', now() + interval '1 hour');
    raise exception 'GIBB_TEST_OK';
  exception when others then
    ergebnis := case when sqlerrm = 'GIBB_TEST_OK' then 'ok' else 'FEHLER: ' || sqlerrm end;
  end;
  return next;
end;
$$;

select * from pg_temp.gibb_pruefen('KONTO');
