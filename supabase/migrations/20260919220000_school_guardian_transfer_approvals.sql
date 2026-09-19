-- School operations: guardian approval for student transfers at/above a
-- configurable threshold. Pending approvals never reserve or mutate balances.

create table if not exists public.school_transfer_settings (
  school_key text primary key check (char_length(school_key) between 1 and 80),
  approval_threshold bigint not null default 1000
    check (approval_threshold between 1 and 100000),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.school_transfer_settings (school_key, approval_threshold)
values ('default', 1000)
on conflict (school_key) do nothing;

create table if not exists public.guardian_invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  student_user_id uuid not null references auth.users(id) on delete cascade,
  guardian_email text not null check (char_length(guardian_email) between 3 and 320),
  token_hash text not null unique,
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists guardian_invitations_student_idx
  on public.guardian_invitations(student_user_id, created_at desc);

create table if not exists public.guardian_relationships (
  id uuid primary key default extensions.gen_random_uuid(),
  student_user_id uuid not null references auth.users(id) on delete cascade,
  guardian_user_id uuid not null references auth.users(id) on delete cascade,
  invitation_id uuid references public.guardian_invitations(id) on delete set null,
  status text not null default 'active' check (status in ('active', 'revoked')),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(student_user_id, guardian_user_id),
  check (student_user_id <> guardian_user_id)
);

create index if not exists guardian_relationships_guardian_idx
  on public.guardian_relationships(guardian_user_id, status);
create index if not exists guardian_relationships_student_idx
  on public.guardian_relationships(student_user_id, status);

create table if not exists public.transfer_approvals (
  id uuid primary key default extensions.gen_random_uuid(),
  student_user_id uuid not null references auth.users(id) on delete restrict,
  receiver_user_id uuid not null references auth.users(id) on delete restrict,
  amount bigint not null check (amount > 0),
  note text check (note is null or char_length(note) <= 160),
  threshold bigint not null check (threshold between 1 and 100000),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'declined', 'cancelled')),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  check (student_user_id <> receiver_user_id)
);

create index if not exists transfer_approvals_student_idx
  on public.transfer_approvals(student_user_id, created_at desc);
create index if not exists transfer_approvals_receiver_idx
  on public.transfer_approvals(receiver_user_id, created_at desc);

create table if not exists public.transfer_approval_audit (
  id uuid primary key default extensions.gen_random_uuid(),
  approval_id uuid not null references public.transfer_approvals(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('created', 'approved', 'declined', 'cancelled')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.school_transfer_settings enable row level security;
alter table public.guardian_invitations enable row level security;
alter table public.guardian_relationships enable row level security;
alter table public.transfer_approvals enable row level security;
alter table public.transfer_approval_audit enable row level security;
alter table public.school_transfer_settings force row level security;
alter table public.guardian_invitations force row level security;
alter table public.guardian_relationships force row level security;
alter table public.transfer_approvals force row level security;
alter table public.transfer_approval_audit force row level security;

revoke all on public.school_transfer_settings, public.guardian_invitations,
  public.guardian_relationships, public.transfer_approvals,
  public.transfer_approval_audit from public, anon, authenticated;
grant select on public.guardian_relationships, public.transfer_approvals to authenticated;

create policy guardian_relationships_participant on public.guardian_relationships
  for select to authenticated
  using ((select auth.uid()) in (student_user_id, guardian_user_id));
create policy transfer_approvals_participant on public.transfer_approvals
  for select to authenticated
  using (
    (select auth.uid()) = student_user_id
    or exists (
      select 1 from public.guardian_relationships r
      where r.student_user_id = transfer_approvals.student_user_id
        and r.guardian_user_id = (select auth.uid())
        and r.status = 'active'
    )
  );
create policy transfer_approval_audit_participant on public.transfer_approval_audit
  for select to authenticated
  using (
    exists (
      select 1 from public.transfer_approvals a
      where a.id = transfer_approval_audit.approval_id
        and (
          a.student_user_id = (select auth.uid())
          or exists (
            select 1 from public.guardian_relationships r
            where r.student_user_id = a.student_user_id
              and r.guardian_user_id = (select auth.uid())
              and r.status = 'active'
          )
        )
    )
  );

create or replace function private.school_transfer_threshold(p_school_key text default 'default')
returns bigint language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select approval_threshold from public.school_transfer_settings
     where school_key = coalesce(nullif(trim(p_school_key), ''), 'default')),
    1000
  );
$$;
revoke all on function private.school_transfer_threshold(text) from public, anon, authenticated;

create or replace function public.get_transfer_approval_context()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_threshold bigint := private.school_transfer_threshold();
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  return jsonb_build_object(
    'threshold', v_threshold,
    'guardians', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.guardian_user_id, 'name', p.display_name)
                       order by p.display_name)
      from public.guardian_relationships r
      join public.profiles p on p.id = r.guardian_user_id
      where r.student_user_id = v_user and r.status = 'active'
    ), '[]'::jsonb),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.student_user_id, 'name', p.display_name)
                       order by p.display_name)
      from public.guardian_relationships r
      join public.profiles p on p.id = r.student_user_id
      where r.guardian_user_id = v_user and r.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.create_guardian_invitation(p_guardian_email text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_student uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_guardian_email, '')));
  v_token text := encode(extensions.gen_random_bytes(24), 'hex');
  v_invitation public.guardian_invitations%rowtype;
begin
  if v_student is null then raise exception 'authentication_required'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_guardian_email');
  end if;
  insert into public.guardian_invitations(student_user_id, guardian_email, token_hash)
    values (v_student, v_email, encode(extensions.digest(v_token, 'sha256'), 'hex'))
    returning * into v_invitation;
  return jsonb_build_object('ok', true, 'invitation_id', v_invitation.id,
    'token', v_token, 'expires_at', v_invitation.expires_at);
end;
$$;

create or replace function public.accept_guardian_invitation(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_guardian uuid := auth.uid();
  v_invitation public.guardian_invitations%rowtype;
  v_email text;
begin
  if v_guardian is null then raise exception 'authentication_required'; end if;
  select lower(email) into v_email from public.profiles where id = v_guardian;
  select * into v_invitation from public.guardian_invitations
  where token_hash = encode(extensions.digest(trim(coalesce(p_token, '')), 'sha256'), 'hex')
    and lower(guardian_email) = v_email
    and accepted_at is null and revoked_at is null and expires_at > now()
  for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'invalid_or_expired_invitation'); end if;
  insert into public.guardian_relationships(student_user_id, guardian_user_id, invitation_id)
    values (v_invitation.student_user_id, v_guardian, v_invitation.id)
    on conflict (student_user_id, guardian_user_id) do update
      set status = 'active', revoked_at = null, invitation_id = excluded.invitation_id;
  update public.guardian_invitations set accepted_at = clock_timestamp() where id = v_invitation.id;
  return jsonb_build_object('ok', true, 'student_user_id', v_invitation.student_user_id);
end;
$$;

-- Keep the established transfer_coins(uuid,bigint,text) returns uuid contract
-- intact for payment requests and other server-side callers.
create or replace function public.transfer_coins(
  p_receiver_user_id uuid, p_amount bigint, p_note text default null
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_sender uuid := auth.uid();
  v_sender_wallet public.wallets%rowtype;
  v_receiver_wallet public.wallets%rowtype;
  v_tx uuid;
  v_sender_name text;
  v_receiver_name text;
begin
  if v_sender is null then raise exception 'authentication_required'; end if;
  if p_receiver_user_id is null then raise exception 'recipient_required'; end if;
  if p_receiver_user_id = v_sender then raise exception 'self_transfer_not_allowed'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;

  perform w.id from public.wallets w
    where w.user_id = any(array[v_sender, p_receiver_user_id])
    order by w.id for update;
  select * into v_sender_wallet from public.wallets where user_id = v_sender;
  select * into v_receiver_wallet from public.wallets where user_id = p_receiver_user_id;
  if v_sender_wallet.id is null or v_receiver_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_sender_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_receiver_wallet.status <> 'active' then raise exception 'recipient_wallet_locked'; end if;
  if v_sender_wallet.balance < p_amount then raise exception 'insufficient_balance'; end if;

  update public.wallets set balance = balance - p_amount where id = v_sender_wallet.id;
  update public.wallets set balance = balance + p_amount where id = v_receiver_wallet.id;
  v_tx := private.append_transaction(v_sender, p_receiver_user_id, p_amount, 'TRANSFER', p_note);
  select display_name into v_sender_name from public.profiles where id = v_sender;
  select display_name into v_receiver_name from public.profiles where id = p_receiver_user_id;
  insert into public.notifications(user_id, kind, title, message) values
    (p_receiver_user_id, 'transfer_received', 'GIBB erhalten', v_sender_name || ' hat dir ' || p_amount || ' GIBB gesendet.'),
    (v_sender, 'transfer_sent', 'Zahlung erfolgreich', p_amount || ' GIBB wurden an ' || v_receiver_name || ' gesendet.');
  return v_tx;
end;
$$;

create or replace function public.transfer_coins_with_guardian_approval(
  p_receiver_user_id uuid, p_amount bigint, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_sender uuid := auth.uid();
  v_sender_wallet public.wallets%rowtype;
  v_receiver_wallet public.wallets%rowtype;
  v_threshold bigint := private.school_transfer_threshold();
  v_approval public.transfer_approvals%rowtype;
  v_tx uuid;
  v_sender_name text;
  v_receiver_name text;
begin
  if v_sender is null then raise exception 'authentication_required'; end if;
  if p_receiver_user_id is null then raise exception 'recipient_required'; end if;
  if p_receiver_user_id = v_sender then raise exception 'self_transfer_not_allowed'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_amount > 100000 then raise exception 'transaction_limit_exceeded'; end if;
  if char_length(coalesce(p_note, '')) > 160 then raise exception 'note_too_long'; end if;

  perform w.id from public.wallets w
    where w.user_id = any(array[v_sender, p_receiver_user_id])
    order by w.id for update;
  select * into v_sender_wallet from public.wallets where user_id = v_sender;
  select * into v_receiver_wallet from public.wallets where user_id = p_receiver_user_id;
  if v_sender_wallet.id is null or v_receiver_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_sender_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_receiver_wallet.status <> 'active' then raise exception 'recipient_wallet_locked'; end if;
  if v_sender_wallet.balance < p_amount then raise exception 'insufficient_balance'; end if;

  if p_amount >= v_threshold
     and exists (select 1 from public.profiles where id = v_sender and role = 'user') then
    if not exists (
      select 1 from public.guardian_relationships
      where student_user_id = v_sender and status = 'active'
    ) then
      raise exception 'guardian_required';
    end if;
    insert into public.transfer_approvals(student_user_id, receiver_user_id, amount, note, threshold)
      values (v_sender, p_receiver_user_id, p_amount, nullif(trim(p_note), ''), v_threshold)
      returning * into v_approval;
    insert into public.transfer_approval_audit(approval_id, actor_user_id, action, details)
      values (v_approval.id, v_sender, 'created', jsonb_build_object('threshold', v_threshold));
    select display_name into v_sender_name from public.profiles where id = v_sender;
    insert into public.notifications(user_id, kind, title, message)
      select guardian_user_id, 'transfer_approval_requested', 'Transfer wartet auf Freigabe',
        v_sender_name || ' möchte ' || p_amount || ' GIBB senden. Bitte prüfen und freigeben.'
      from public.guardian_relationships
      where student_user_id = v_sender and status = 'active';
    return jsonb_build_object('ok', true, 'status', 'pending', 'approval_id', v_approval.id,
      'threshold', v_threshold);
  end if;

  update public.wallets set balance = balance - p_amount where id = v_sender_wallet.id;
  update public.wallets set balance = balance + p_amount where id = v_receiver_wallet.id;
  v_tx := private.append_transaction(v_sender, p_receiver_user_id, p_amount, 'TRANSFER', p_note);
  select display_name into v_sender_name from public.profiles where id = v_sender;
  select display_name into v_receiver_name from public.profiles where id = p_receiver_user_id;
  insert into public.notifications(user_id, kind, title, message) values
    (p_receiver_user_id, 'transfer_received', 'GIBB erhalten', v_sender_name || ' hat dir ' || p_amount || ' GIBB gesendet.'),
    (v_sender, 'transfer_sent', 'Zahlung erfolgreich', p_amount || ' GIBB wurden an ' || v_receiver_name || ' gesendet.');
  return jsonb_build_object('ok', true, 'status', 'completed', 'transaction_id', v_tx, 'threshold', v_threshold);
end;
$$;

create or replace function public.decide_transfer_approval(p_approval_id uuid, p_decision text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_guardian uuid := auth.uid();
  v_approval public.transfer_approvals%rowtype;
  v_sender_wallet public.wallets%rowtype;
  v_receiver_wallet public.wallets%rowtype;
  v_tx uuid;
  v_guardian_name text;
  v_receiver_name text;
begin
  if v_guardian is null then raise exception 'authentication_required'; end if;
  if p_decision not in ('approve', 'decline') then raise exception 'invalid_approval_decision'; end if;
  select a.* into v_approval from public.transfer_approvals a
  where a.id = p_approval_id and a.status = 'pending'
    and exists (select 1 from public.guardian_relationships r
      where r.student_user_id = a.student_user_id and r.guardian_user_id = v_guardian and r.status = 'active')
  for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'approval_not_found_or_unauthorized'); end if;
  if p_decision = 'decline' then
    update public.transfer_approvals set status = 'declined', decided_by = v_guardian, decided_at = clock_timestamp()
      where id = v_approval.id;
    insert into public.transfer_approval_audit(approval_id, actor_user_id, action) values (v_approval.id, v_guardian, 'declined');
    insert into public.notifications(user_id, kind, title, message)
      values (v_approval.student_user_id, 'transfer_approval_declined', 'Transfer abgelehnt',
        'Dein Transfer über ' || v_approval.amount || ' GIBB wurde abgelehnt.');
    return jsonb_build_object('ok', true, 'status', 'declined');
  end if;

  perform w.id from public.wallets w
    where w.user_id = any(array[v_approval.student_user_id, v_approval.receiver_user_id])
    order by w.id for update;
  select * into v_sender_wallet from public.wallets where user_id = v_approval.student_user_id;
  select * into v_receiver_wallet from public.wallets where user_id = v_approval.receiver_user_id;
  if v_sender_wallet.id is null or v_receiver_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_sender_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;
  if v_receiver_wallet.status <> 'active' then raise exception 'recipient_wallet_locked'; end if;
  if v_sender_wallet.balance < v_approval.amount then
    update public.transfer_approvals set status = 'cancelled', decided_by = v_guardian, decided_at = clock_timestamp()
      where id = v_approval.id;
    insert into public.transfer_approval_audit(approval_id, actor_user_id, action, details)
      values (v_approval.id, v_guardian, 'cancelled', '{"reason":"insufficient_balance"}');
    return jsonb_build_object('ok', false, 'error', 'insufficient_balance', 'status', 'cancelled');
  end if;
  update public.wallets set balance = balance - v_approval.amount where id = v_sender_wallet.id;
  update public.wallets set balance = balance + v_approval.amount where id = v_receiver_wallet.id;
  v_tx := private.append_transaction(v_approval.student_user_id, v_approval.receiver_user_id,
    v_approval.amount, 'TRANSFER', v_approval.note);
  update public.transfer_approvals set status = 'approved', decided_by = v_guardian,
    decided_at = clock_timestamp(), transaction_id = v_tx where id = v_approval.id;
  insert into public.transfer_approval_audit(approval_id, actor_user_id, action, details)
    values (v_approval.id, v_guardian, 'approved', jsonb_build_object('transaction_id', v_tx));
  select display_name into v_guardian_name from public.profiles where id = v_guardian;
  select display_name into v_receiver_name from public.profiles where id = v_approval.receiver_user_id;
  insert into public.notifications(user_id, kind, title, message) values
    (v_approval.student_user_id, 'transfer_approval_approved', 'Transfer freigegeben',
      v_guardian_name || ' hat deinen Transfer über ' || v_approval.amount || ' GIBB freigegeben.'),
    (v_approval.receiver_user_id, 'transfer_received', 'GIBB erhalten',
      'Du hast ' || v_approval.amount || ' GIBB erhalten.');
  return jsonb_build_object('ok', true, 'status', 'approved', 'transaction_id', v_tx);
end;
$$;

create or replace function public.list_transfer_approvals()
returns setof public.transfer_approvals language sql stable security definer set search_path = ''
as $$
  select a from public.transfer_approvals a
  where a.student_user_id = auth.uid()
    or exists (select 1 from public.guardian_relationships r
      where r.student_user_id = a.student_user_id and r.guardian_user_id = auth.uid() and r.status = 'active')
  order by a.created_at desc limit 50;
$$;

create or replace function public.admin_set_transfer_threshold(p_school_key text, p_threshold bigint, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare v_admin uuid := private.require_admin(); v_pin text; v_key text := coalesce(nullif(trim(p_school_key), ''), 'default');
begin
  v_pin := private.check_admin_pin(v_admin, p_pin);
  if v_pin <> 'ok' then return jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin); end if;
  if p_threshold is null or p_threshold < 1 or p_threshold > 100000 then
    return jsonb_build_object('ok', false, 'error', 'invalid_threshold');
  end if;
  insert into public.school_transfer_settings(school_key, approval_threshold, updated_by, updated_at)
    values (v_key, p_threshold, v_admin, clock_timestamp())
    on conflict (school_key) do update set approval_threshold = excluded.approval_threshold,
      updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true, 'school_key', v_key, 'threshold', p_threshold);
end;
$$;

create or replace function public.admin_list_transfer_approvals(p_pin text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_admin uuid := private.require_admin(); v_pin text; v_result jsonb;
begin
  v_pin := private.check_admin_pin(v_admin, p_pin);
  if v_pin <> 'ok' then return jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin); end if;
  select jsonb_build_object(
    'threshold', private.school_transfer_threshold(),
    'pending', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc)
      from public.transfer_approvals a where a.status = 'pending'), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc)
      from public.transfer_approval_audit e), '[]'::jsonb)
  ) into v_result;
  return jsonb_build_object('ok', true, 'data', v_result);
end;
$$;

revoke all on function public.get_transfer_approval_context(), public.create_guardian_invitation(text),
  public.accept_guardian_invitation(text), public.transfer_coins(uuid,bigint,text),
  public.transfer_coins_with_guardian_approval(uuid,bigint,text),
  public.decide_transfer_approval(uuid,text), public.list_transfer_approvals(),
  public.admin_set_transfer_threshold(text,bigint,text), public.admin_list_transfer_approvals(text)
  from public, anon;
grant execute on function public.get_transfer_approval_context(), public.create_guardian_invitation(text),
  public.accept_guardian_invitation(text), public.transfer_coins(uuid,bigint,text),
  public.transfer_coins_with_guardian_approval(uuid,bigint,text),
  public.decide_transfer_approval(uuid,text), public.list_transfer_approvals(),
  public.admin_set_transfer_threshold(text,bigint,text), public.admin_list_transfer_approvals(text)
  to authenticated;
