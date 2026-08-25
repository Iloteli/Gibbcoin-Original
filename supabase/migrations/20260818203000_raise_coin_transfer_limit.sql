-- Raise the per-transfer ceiling while retaining all server-side balance,
-- account-status, note-length and recipient checks.

create or replace function public.transfer_coins(
  p_receiver_user_id uuid,
  p_amount bigint,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sender_id uuid := auth.uid();
  v_sender public.wallets%rowtype;
  v_receiver public.wallets%rowtype;
  v_transaction_id uuid;
  v_sender_name text;
  v_receiver_name text;
begin
  if v_sender_id is null then raise exception 'authentication_required'; end if;
  if p_receiver_user_id is null then raise exception 'recipient_required'; end if;
  if p_receiver_user_id = v_sender_id then raise exception 'self_transfer_not_allowed'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if pg_catalog.char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;

  perform w.id
  from public.wallets w
  where w.user_id = any(array[v_sender_id, p_receiver_user_id])
  order by w.id
  for update;

  select w.* into v_sender from public.wallets w where w.user_id = v_sender_id;
  select w.* into v_receiver from public.wallets w where w.user_id = p_receiver_user_id;

  if v_sender.id is null or v_receiver.id is null then raise exception 'wallet_not_found'; end if;
  if v_sender.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_receiver.status <> 'active' then raise exception 'recipient_wallet_locked'; end if;
  if v_sender.balance < p_amount then raise exception 'insufficient_balance'; end if;

  update public.wallets set balance = balance - p_amount where id = v_sender.id;
  update public.wallets set balance = balance + p_amount where id = v_receiver.id;
  v_transaction_id := private.append_transaction(
    v_sender_id,
    p_receiver_user_id,
    p_amount,
    'TRANSFER',
    p_note
  );

  select display_name into v_sender_name from public.profiles where id = v_sender_id;
  select display_name into v_receiver_name from public.profiles where id = p_receiver_user_id;

  insert into public.notifications (user_id, kind, title, message) values
    (
      p_receiver_user_id,
      'transfer_received',
      'GIBB erhalten',
      v_sender_name || ' hat dir ' || p_amount || ' GIBB gesendet.'
    ),
    (
      v_sender_id,
      'transfer_sent',
      'Zahlung erfolgreich',
      p_amount || ' GIBB wurden an ' || v_receiver_name || ' gesendet.'
    );

  return v_transaction_id;
end;
$$;

revoke all on function public.transfer_coins(uuid, bigint, text)
from public, anon, authenticated;
grant execute on function public.transfer_coins(uuid, bigint, text)
to authenticated;
