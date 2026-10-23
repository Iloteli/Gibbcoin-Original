-- GIBB Coin: neues Supabase einrichten – Teil 4 von 5
-- Im SQL Editor des NEUEN Projekts der Reihe nach ausführen (Teil 1, dann 2, …). Jeden Teil nur einmal.

-- ===================== 20260915130000_promote_ilja_to_owner.sql =====================
-- Ilja wird Owner (super_admin) mit denselben Rechten wie Robyn. Die Rolle kann
-- über keine Browser-RPC gesetzt werden (admin_set_role erlaubt nur user/admin),
-- deshalb erfolgt die Beförderung serverseitig in dieser Migration.
--
-- Das Konto wird über die Login-E-Mail in auth.users aufgelöst. Existiert das
-- Konto noch nicht, macht die Migration nichts und kann später erneut
-- ausgeführt werden. Ist die Rolle bereits super_admin, bleibt alles unverändert.

do $$
declare
  v_user_id uuid;
  v_old_role text;
begin
  select u.id into v_user_id
  from auth.users u
  where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
  order by u.created_at
  limit 1;

  if v_user_id is null then
    raise notice 'Ilja-Konto noch nicht vorhanden – keine Rollenänderung.';
    return;
  end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = v_user_id
  for update;

  if v_old_role is null or v_old_role = 'super_admin' then
    return;
  end if;

  update public.profiles
  set role = 'super_admin'
  where id = v_user_id;

  perform private.write_admin_audit(
    v_user_id,
    v_user_id,
    'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role),
    pg_catalog.jsonb_build_object('role', 'super_admin'),
    'Owner-Rolle per Migration vergeben (gleiche Rechte wie Robyn)'
  );

  insert into public.notifications (user_id, kind, title, message)
  values (
    v_user_id,
    'role_changed',
    'Owner-Rechte erhalten',
    'Du bist jetzt Owner mit denselben Rechten wie Robyn.'
  );
end;
$$;


-- ===================== 20260919220000_school_guardian_transfer_approvals.sql =====================
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


-- ===================== 20260919233000_allow_group_name_changes.sql =====================
-- Allow group owners to rename their wallet without exposing direct table writes.

create or replace function public.rename_group_wallet(p_group_id uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_active_user();
  v_name text := pg_catalog.btrim(coalesce(p_name, ''));
begin
  if pg_catalog.char_length(v_name) not between 3 and 60 then
    raise exception 'invalid_group_name';
  end if;

  if not exists (
    select 1
    from public.group_wallet_members m
    where m.group_id = p_group_id
      and m.user_id = v_user_id
      and m.role = 'owner'
  ) then
    raise exception 'group_owner_required';
  end if;

  update public.group_wallets
  set name = v_name, updated_at = pg_catalog.now()
  where id = p_group_id;

  if not found then
    raise exception 'group_not_found';
  end if;
end;
$$;

revoke all on function public.rename_group_wallet(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_group_wallet(uuid, text) to authenticated;


-- ===================== 20260920180000_add_visitor_analytics.sql =====================
-- Besucherstatistik fuer das Adminpanel.
-- Zaehlt echte Seitenaufrufe und eindeutige Browser pro Webadresse.
-- Rohdaten sind nur ueber Security-Definer-Funktionen erreichbar.

create table if not exists public.site_visits (
  id uuid primary key default gen_random_uuid(),
  visitor_id text not null check (char_length(visitor_id) between 8 and 64),
  site text not null check (site in ('chatgpt-site', 'workers-dev', 'other')),
  path text not null default '/' check (char_length(path) between 1 and 200),
  visited_at timestamptz not null default now()
);

create index if not exists site_visits_visited_at_idx on public.site_visits (visited_at desc);
create index if not exists site_visits_site_idx on public.site_visits (site, visited_at desc);
create index if not exists site_visits_visitor_idx on public.site_visits (visitor_id, visited_at desc);

alter table public.site_visits enable row level security;
revoke all on public.site_visits from anon, authenticated;
grant all on public.site_visits to service_role;

-- Ein Besuch wird nur ueber diese Funktion geschrieben. Sie entfernt doppelte
-- Aufrufe derselben Seite innerhalb von 30 Sekunden und begrenzt Spam.
create or replace function public.record_site_visit(
  p_visitor_id text,
  p_site text,
  p_path text default '/'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_visitor text := nullif(trim(p_visitor_id), '');
  v_site text := lower(coalesce(nullif(trim(p_site), ''), 'other'));
  v_path text := left(coalesce(nullif(trim(p_path), ''), '/'), 200);
  v_recent_total integer;
begin
  if v_visitor is null or char_length(v_visitor) < 8 or char_length(v_visitor) > 64 then
    return;
  end if;
  if v_site not in ('chatgpt-site', 'workers-dev', 'other') then
    v_site := 'other';
  end if;

  -- Neuladen derselben Seite zaehlt nicht mehrfach.
  if exists (
    select 1 from public.site_visits
    where visitor_id = v_visitor
      and site = v_site
      and path = v_path
      and visited_at > now() - interval '30 seconds'
  ) then
    return;
  end if;

  -- Schutz gegen kuenstlich aufgeblasene Zahlen.
  select count(*) into v_recent_total
  from public.site_visits
  where visitor_id = v_visitor
    and visited_at > now() - interval '1 hour';
  if v_recent_total >= 240 then
    return;
  end if;

  insert into public.site_visits (visitor_id, site, path)
  values (v_visitor, v_site, v_path);
end;
$$;

revoke all on function public.record_site_visit(text, text, text) from public;
grant execute on function public.record_site_visit(text, text, text) to anon, authenticated;

-- Auswertung ausschliesslich fuer Admins und Owner.
create or replace function public.admin_visitor_stats(p_days integer default 30)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_from timestamptz;
  v_result json;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if coalesce(v_role, '') not in ('admin', 'super_admin') then
    raise exception 'admin_required';
  end if;

  v_from := date_trunc('day', now()) - make_interval(days => v_days - 1);

  select json_build_object(
    'range_days', v_days,
    'first_visit_at', (select min(visited_at) from public.site_visits),
    'range_unique_visitors', (
      select count(distinct visitor_id) from public.site_visits where visited_at >= v_from
    ),
    'range_page_views', (
      select count(*) from public.site_visits where visited_at >= v_from
    ),
    'total_unique_visitors', (select count(distinct visitor_id) from public.site_visits),
    'total_page_views', (select count(*) from public.site_visits),
    'daily', coalesce((
      select json_agg(row_to_json(day_rows) order by day_rows.day)
      from (
        select
          to_char(days.day, 'YYYY-MM-DD') as day,
          coalesce(count(distinct v.visitor_id), 0) as unique_visitors,
          coalesce(count(v.id), 0) as page_views
        from generate_series(v_from, date_trunc('day', now()), interval '1 day') as days(day)
        left join public.site_visits v
          on v.visited_at >= days.day and v.visited_at < days.day + interval '1 day'
        group by days.day
      ) as day_rows
    ), '[]'::json),
    'sites', coalesce((
      select json_agg(row_to_json(site_rows))
      from (
        select
          site,
          count(distinct visitor_id) as unique_visitors,
          count(*) as page_views
        from public.site_visits
        where visited_at >= v_from
        group by site
        order by count(*) desc
      ) as site_rows
    ), '[]'::json),
    'pages', coalesce((
      select json_agg(row_to_json(page_rows))
      from (
        select
          path,
          count(distinct visitor_id) as unique_visitors,
          count(*) as page_views
        from public.site_visits
        where visited_at >= v_from
        group by path
        order by count(*) desc
        limit 10
      ) as page_rows
    ), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_visitor_stats(integer) from public;
grant execute on function public.admin_visitor_stats(integer) to authenticated;


-- ===================== 20260921090000_restore_ilja_owner.sql =====================
-- Stellt Ilja als Owner wieder her – auch wenn das Profil verloren ging.
--
-- "Ilja ist kein Benutzer mehr": Falls sein Profil (public.profiles) fehlt oder
-- die Rolle zurückgesetzt wurde, richtet diese Migration es idempotent wieder
-- ein und setzt die Rolle auf super_admin. Das Konto wird über die Login-E-Mail
-- in auth.users aufgelöst. Existiert das Auth-Konto gar nicht mehr, kann eine
-- Migration es nicht neu anlegen – dann muss sich Ilja einmal neu registrieren
-- (danach greift diese Migration erneut).
--
-- Es wird niemand anderes zum Owner gemacht – nur Ilja.

do $$
declare
  v_user_id  uuid;
  v_email    text;
  v_username text;
  v_name     text;
  v_old_role text;
  v_had_row  boolean;
begin
  select u.id, pg_catalog.lower(u.email)
    into v_user_id, v_email
  from auth.users u
  where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
  order by u.created_at
  limit 1;

  if v_user_id is null then
    raise notice 'Ilja-Konto (auth.users) nicht vorhanden – bitte einmal registrieren, dann Migration erneut ausführen.';
    return;
  end if;

  select p.role into v_old_role
  from public.profiles p
  where p.id = v_user_id;
  v_had_row := found;

  -- Eindeutiger, formatgültiger Benutzername als Fallback (u + 23 Hexzeichen).
  v_username := 'u' || pg_catalog.left(pg_catalog.replace(v_user_id::text, '-', ''), 23);
  v_name := pg_catalog.btrim(coalesce(nullif(pg_catalog.split_part(coalesce(v_email, ''), '@', 1), ''), 'Ilja'));
  v_name := pg_catalog.left(v_name, 60);

  -- Profil wiederherstellen bzw. Rolle auf Owner setzen.
  insert into public.profiles (id, username, display_name, email, role)
  values (v_user_id, v_username, v_name, coalesce(v_email, ''), 'super_admin')
  on conflict (id) do update set role = 'super_admin';

  -- Wallet sicherstellen (nur anlegen, falls keines existiert).
  insert into public.wallets (user_id, balance)
  values (v_user_id, 200)
  on conflict (user_id) do nothing;

  -- Nur benachrichtigen/protokollieren, wenn sich wirklich etwas geändert hat.
  if (not v_had_row) or v_old_role is distinct from 'super_admin' then
    begin
      perform private.write_admin_audit(
        v_user_id,
        v_user_id,
        'ROLE_CHANGED',
        pg_catalog.jsonb_build_object('role', coalesce(v_old_role, '(kein Profil)')),
        pg_catalog.jsonb_build_object('role', 'super_admin'),
        'Owner-Rolle wiederhergestellt (Ilja)'
      );
    exception when others then
      raise notice 'Audit-Log übersprungen: %', SQLERRM;
    end;

    begin
      insert into public.notifications (user_id, kind, title, message)
      values (
        v_user_id,
        'role_changed',
        'Owner-Rechte wiederhergestellt',
        'Dein Konto ist wieder Owner (super_admin).'
      );
    exception when others then
      raise notice 'Benachrichtigung übersprungen: %', SQLERRM;
    end;
  end if;
end;
$$;

notify pgrst, 'reload schema';


-- ===================== 20260922090000_count_every_page_visit.sql =====================
-- Jede geoeffnete Seite wird als eigener Seitenaufruf gezaehlt.
-- Die bisherige 30-Sekunden-Deduplizierung und das Stundenlimit wurden entfernt,
-- damit der Counter bei jedem neuen Seitenaufruf erhoeht wird.

create or replace function public.record_site_visit(
  p_visitor_id text,
  p_site text,
  p_path text default '/'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_visitor text := nullif(trim(p_visitor_id), '');
  v_site text := lower(coalesce(nullif(trim(p_site), ''), 'other'));
  v_path text := left(coalesce(nullif(trim(p_path), ''), '/'), 200);
begin
  if v_visitor is null or char_length(v_visitor) < 8 or char_length(v_visitor) > 64 then
    return;
  end if;

  if v_site not in ('chatgpt-site', 'workers-dev', 'other') then
    v_site := 'other';
  end if;

  -- Absichtlich kein EXISTS-/Zeitfenster-Check: Jeder Seitenaufruf zaehlt.
  insert into public.site_visits (visitor_id, site, path)
  values (v_visitor, v_site, v_path);
end;
$$;

revoke all on function public.record_site_visit(text, text, text) from public;
grant execute on function public.record_site_visit(text, text, text) to anon, authenticated;


-- ===================== 20261010100000_admin_mfa_only_if_enrolled.sql =====================
-- Admin-Portal ohne Pflicht-2FA + Ilja als Owner.
--
-- 1) private.require_admin() verlangte seit 20260908063951 für JEDE Adminaktion
--    eine aal2-Sitzung, auch wenn das Konto gar keinen 2FA-Faktor hat. Jetzt gilt
--    dieselbe Regel wie in private.assert_mfa_if_enrolled: 2FA wird nur verlangt,
--    wenn das Konto einen bestätigten Faktor eingerichtet hat. Admin-PIN, Rolle
--    und Kontosperre werden weiterhin geprüft.
-- 2) Ilja (ilja.podorieszach@icloud.com) wird idempotent Owner (super_admin).
--    super_admin umfasst alle Adminrechte.

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if exists (
    select 1 from auth.mfa_factors f
    where f.user_id = v_user_id and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
  select p.role, w.status into v_role, v_wallet_status
  from public.profiles p join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;
  if v_role not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  if v_wallet_status <> 'active' then raise exception 'account_locked'; end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_admin() from public, anon, authenticated;

do $$
declare
  v_user_id uuid;
  v_old_role text;
begin
  select u.id into v_user_id
  from auth.users u
  where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
  order by u.created_at
  limit 1;

  if v_user_id is null then
    raise notice 'Ilja-Konto (auth.users) nicht vorhanden – bitte einmal registrieren, dann erneut ausführen.';
    return;
  end if;

  select p.role into v_old_role from public.profiles p where p.id = v_user_id;
  update public.profiles set role = 'super_admin' where id = v_user_id;
  if not found then
    raise notice 'Ilja hat noch kein Profil – Migration 20260921090000_restore_ilja_owner legt es an.';
  end if;
  update public.wallets set status = 'active' where user_id = v_user_id and status <> 'active';

  if v_old_role is distinct from 'super_admin' then
    begin
      perform private.write_admin_audit(
        v_user_id, v_user_id, 'ROLE_CHANGED',
        pg_catalog.jsonb_build_object('role', coalesce(v_old_role, '(kein Profil)')),
        pg_catalog.jsonb_build_object('role', 'super_admin'),
        'Owner- und Adminrechte für Ilja gesetzt'
      );
    exception when others then
      raise notice 'Audit-Log übersprungen: %', SQLERRM;
    end;
  end if;
end;
$$;

notify pgrst, 'reload schema';


-- ===================== 20261013090000_blockchain_settings_only_ilja.sql =====================
-- Blockchain-Einstellungen darf nur noch Ilja ändern (ilja.podorieszach@icloud.com).
-- Andere Admins und Owner bekommen 'owner_required'. Admin-PIN wird weiterhin geprüft.

create or replace function public.admin_update_blockchain_settings(p_value jsonb, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb := private.blockchain_settings();
  v_after jsonb;
begin
  if pg_catalog.lower(coalesce((select u.email from auth.users u where u.id = v_admin), '')) <> 'ilja.podorieszach@icloud.com' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if p_value is null or pg_catalog.jsonb_typeof(p_value) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  v_pin_status := private.check_admin_pin(v_admin, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_after := pg_catalog.jsonb_build_object(
    'enabled', coalesce((p_value ->> 'enabled')::boolean, (v_before ->> 'enabled')::boolean),
    'reward', greatest(0, least(1000, coalesce((p_value ->> 'reward')::bigint, (v_before ->> 'reward')::bigint))),
    'target_seconds', greatest(10, least(86400, coalesce((p_value ->> 'target_seconds')::integer, (v_before ->> 'target_seconds')::integer))),
    'min_bits', greatest(8, least(48, coalesce((p_value ->> 'min_bits')::integer, (v_before ->> 'min_bits')::integer))),
    'max_bits', greatest(8, least(48, coalesce((p_value ->> 'max_bits')::integer, (v_before ->> 'max_bits')::integer))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((p_value ->> 'cooldown_seconds')::integer, (v_before ->> 'cooldown_seconds')::integer))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((p_value ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer)))
  );
  if (v_after ->> 'min_bits')::integer > (v_after ->> 'max_bits')::integer then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_difficulty_range');
  end if;

  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('blockchain', v_after, v_admin, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;

  perform private.write_admin_audit(v_admin, v_admin, 'BLOCKCHAIN_SETTING_CHANGED', v_before, v_after, 'Blockchain-Einstellungen geändert');

  return pg_catalog.jsonb_build_object('ok', true, 'settings', v_after);
end;
$$;

revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013091000_mining_needs_real_transactions.sql =====================
-- Mining-Fehler beheben: Die Belohnung eines Blocks ist selbst eine unbestätigte Transaktion
-- (MINING_REWARD). Bisher reichte genau diese für den nächsten Block – Mining hielt sich so
-- endlos selbst am Laufen und erzeugte Coins ohne echte Coin-Bewegungen.
-- Neu: Ein Block braucht mindestens eine unbestätigte Transaktion, die KEINE Mining-Belohnung ist.
-- Belohnungen werden weiterhin mit in den nächsten echten Block aufgenommen.

do $migration$
declare
  v_def text;
  v_anchor text;
begin
  -- 1) Vorlage: ohne echte Transaktion keine Vorlage
  v_def := pg_catalog.pg_get_functiondef('public.get_block_template()'::pg_catalog.regprocedure);
  if pg_catalog.strpos(v_def, 'mining_needs_real_tx') = 0 then
    v_anchor := $a$if coalesce(v_count, 0) = 0 then raise exception 'no_pending_transactions'; end if;$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then
      raise exception 'get_block_template: Stelle für die Ergänzung nicht gefunden';
    end if;
    v_def := pg_catalog.replace(v_def, v_anchor, v_anchor || $b$
  -- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if not exists (
    select 1 from public.transactions t
    where t.block_height is null and t.chain_index <= v_last and t.type <> 'MINING_REWARD'
  ) then raise exception 'no_pending_transactions'; end if;$b$);
    execute v_def;
  end if;

  -- 2) Einreichen: dieselbe Regel serverseitig erzwingen
  v_def := pg_catalog.pg_get_functiondef('public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text)'::pg_catalog.regprocedure);
  if pg_catalog.strpos(v_def, 'mining_needs_real_tx') = 0 then
    v_anchor := '  v_merkle := private.merkle_root(v_hashes);';
    if pg_catalog.strpos(v_def, v_anchor) = 0 then
      raise exception 'submit_mined_block: Stelle für die Ergänzung nicht gefunden';
    end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $c$  -- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if not exists (
    select 1 from public.transactions t
    where t.block_height is null and t.chain_index <= p_last_chain_index and t.type <> 'MINING_REWARD'
  ) then raise exception 'no_pending_transactions'; end if;
$c$ || v_anchor);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';


-- ===================== 20261013100000_community_leaderboard.sql =====================
-- Community-Rangliste: Punkte aus Erfolgen, Tagesaufgaben, Check-ins und gefundenen Blöcken.
-- Bewusst OHNE Kontostände – niemand sieht, wie viele Coins andere haben.
-- Punkte: Erfolg 10 · Tagesaufgabe 3 · Block 2 · Check-in 1. Zeitraum: week | month | all.

create or replace function public.get_community_leaderboard(p_period text default 'week')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_period text := case when p_period in ('week', 'month', 'all') then p_period else 'week' end;
  v_since timestamptz;
  v_rows jsonb;
  v_mine jsonb;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  v_since := case v_period
    when 'week' then pg_catalog.date_trunc('week', pg_catalog.now())
    when 'month' then pg_catalog.date_trunc('month', pg_catalog.now())
    else '-infinity'::timestamptz end;

  with scores as (
    select p.id as user_id,
           coalesce(nullif(p.username, ''), p.display_name) as username,
           p.display_name,
           p.profile_color,
           p.equipped_title,
           (select count(*) from public.user_challenges c where c.user_id = p.id and c.claimed_at >= v_since) as achievements,
           (select count(*) from public.daily_task_claims d where d.user_id = p.id and d.created_at >= v_since) as tasks,
           (select count(*) from public.daily_rewards r where r.user_id = p.id and r.created_at >= v_since) as check_ins,
           (select count(*) from public.blocks b where b.miner_user_id = p.id and b.height > 0 and b.mined_at >= v_since) as blocks
    from public.profiles p
    join public.wallets w on w.user_id = p.id and w.status = 'active'
  ), ranked as (
    select s.*,
           s.achievements * 10 + s.tasks * 3 + s.blocks * 2 + s.check_ins as points,
           pg_catalog.rank() over (order by s.achievements * 10 + s.tasks * 3 + s.blocks * 2 + s.check_ins desc) as rank
    from scores s
  )
  select
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x) order by x.rank, x.username)
              from (select * from ranked where points > 0 order by rank, username limit 20) x), '[]'::jsonb),
    (select pg_catalog.to_jsonb(r) from ranked r where r.user_id = v_me)
  into v_rows, v_mine;

  return pg_catalog.jsonb_build_object('period', v_period, 'since', case when v_period = 'all' then null else v_since end, 'entries', v_rows, 'me', v_mine);
end;
$$;

revoke all on function public.get_community_leaderboard(text) from public, anon;
grant execute on function public.get_community_leaderboard(text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013110000_gibb_market.sql =====================
-- GIBB-Markt: Kurs in Rappen pro GIBB, der auf Käufe und Verkäufe reagiert.
--
-- * Kaufen (Stripe oder mit Credits) hebt den Kurs, Verkaufen an die Bank senkt ihn.
-- * Kurve: Jedes gehandelte GIBB verändert den Kurs um den Faktor (1 + k).
--   Kosten für n GIBB ab Kurs p:  p * ((1+k)^n - 1) / k  (aufgerundet auf ganze Rappen).
--   Ein Verkauf läuft dieselbe Kurve rückwärts – ein Kauf und sofortiger Verkauf
--   bringt also keinen Gewinn; zusätzlich gibt es eine Verkaufsgebühr.
-- * Verkaufen bringt KEIN echtes Geld, sondern Credits (Guthaben in Rappen), mit
--   denen man später wieder GIBB kaufen kann.
-- * Kursgrenzen schützen vor Ausreissern; Handel über eine Grenze hinaus wird abgelehnt.

-- Neue Transaktionstypen (Obermenge der bisherigen Liste)
alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions
  add constraint transactions_type_check check (
    type in (
      'TRANSFER', 'INITIAL_BALANCE', 'MARKETPLACE', 'CHALLENGE_REWARD',
      'DAILY_REWARD', 'REFUND', 'ADMIN_MINT', 'ADMIN_BURN',
      'COIN_PURCHASE', 'GAME_ENTRY', 'GAME_REWARD', 'MINING_REWARD',
      'MARKET_BUY', 'MARKET_SELL'
    )
  );

-- Credits (Rappen) pro Wallet
alter table public.wallets add column if not exists credits bigint not null default 0;
alter table public.wallets drop constraint if exists wallets_credits_check;
alter table public.wallets add constraint wallets_credits_check check (credits >= 0);

create table if not exists private.market_settings (
  singleton boolean primary key default true check (singleton),
  price numeric(20, 8) not null default 1,          -- Rappen pro GIBB
  step numeric(12, 8) not null default 0.0005,      -- Kursänderung pro GIBB (0.05 %)
  min_price numeric(20, 8) not null default 0.25,
  max_price numeric(20, 8) not null default 50,
  sell_fee numeric(6, 4) not null default 0.02,      -- 2 % Gebühr beim Verkauf
  max_trade bigint not null default 1000,           -- höchstens so viele GIBB pro Handel
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into private.market_settings (singleton) values (true) on conflict (singleton) do nothing;
revoke all on table private.market_settings from public, anon, authenticated;

create table if not exists public.market_events (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('buy_stripe', 'buy_credits', 'sell')),
  user_id uuid references auth.users(id) on delete set null,
  gibb bigint not null check (gibb > 0),
  rappen bigint not null check (rappen >= 0),
  price_before numeric(20, 8) not null,
  price_after numeric(20, 8) not null,
  reference text unique,                              -- z. B. Stripe-Event-ID (verhindert Doppelbuchung)
  created_at timestamptz not null default now()
);
create index if not exists market_events_created_idx on public.market_events (created_at desc);
alter table public.market_events enable row level security;
alter table public.market_events force row level security;
revoke all on table public.market_events from public, anon, authenticated;

-- Kosten für n GIBB ab Kurs p (Kauf): Summe p*(1+k)^i, i = 0..n-1
create or replace function private.market_curve_sum(p_price numeric, p_step numeric, p_n bigint)
returns numeric language sql immutable set search_path = '' as $$
  select case when p_step = 0 then p_price * p_n
              else p_price * (pg_catalog.power(1 + p_step, p_n) - 1) / p_step end;
$$;

-- Kurs nach einem Handel bewegen und protokollieren (intern, unter Sperre aufrufen)
create or replace function private.market_apply(p_kind text, p_user uuid, p_gibb bigint, p_rappen bigint, p_reference text)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_after numeric;
begin
  select * into v_s from private.market_settings where singleton for update;
  v_after := case when p_kind = 'sell'
    then v_s.price / pg_catalog.power(1 + v_s.step, p_gibb)
    else v_s.price * pg_catalog.power(1 + v_s.step, p_gibb) end;
  v_after := greatest(v_s.min_price, least(v_s.max_price, v_after));
  update private.market_settings set price = v_after, updated_at = pg_catalog.now() where singleton;
  insert into public.market_events (kind, user_id, gibb, rappen, price_before, price_after, reference)
  values (p_kind, p_user, p_gibb, p_rappen, v_s.price, v_after, p_reference);
  return v_after;
end;
$$;
revoke all on function private.market_apply(text, uuid, bigint, bigint, text) from public, anon, authenticated;

-- Angebot: Was kosten n GIBB gerade? Was bringt ein Verkauf von n GIBB?
create or replace function public.market_quote(p_gibb bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_buy numeric; v_sell numeric; v_after_buy numeric; v_after_sell numeric;
begin
  select * into v_s from private.market_settings where singleton;
  if p_gibb is null or p_gibb < 1 or p_gibb > v_s.max_trade then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount', 'max_trade', v_s.max_trade);
  end if;
  v_after_buy := v_s.price * pg_catalog.power(1 + v_s.step, p_gibb);
  v_after_sell := v_s.price / pg_catalog.power(1 + v_s.step, p_gibb);
  v_buy := pg_catalog.ceil(private.market_curve_sum(v_s.price, v_s.step, p_gibb));
  v_sell := pg_catalog.floor(private.market_curve_sum(v_after_sell, v_s.step, p_gibb) * (1 - v_s.sell_fee));
  return pg_catalog.jsonb_build_object(
    'ok', true, 'gibb', p_gibb, 'price', v_s.price,
    'buy_rappen', v_buy, 'buy_possible', v_after_buy <= v_s.max_price,
    'sell_rappen', v_sell, 'sell_possible', v_after_sell >= v_s.min_price,
    'price_after_buy', v_after_buy, 'price_after_sell', v_after_sell,
    'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade, 'enabled', v_s.enabled
  );
end;
$$;

-- Marktübersicht: Kurs, Verlauf, eigene Bestände
create or replace function public.get_market_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_s private.market_settings%rowtype;
  v_day_ago numeric;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  select * into v_s from private.market_settings where singleton;
  select e.price_after into v_day_ago from public.market_events e
  where e.created_at <= pg_catalog.now() - interval '24 hours' order by e.created_at desc limit 1;
  return pg_catalog.jsonb_build_object(
    'price', v_s.price, 'enabled', v_s.enabled, 'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade,
    'min_price', v_s.min_price, 'max_price', v_s.max_price,
    'price_24h_ago', coalesce(v_day_ago, (select e.price_before from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours' order by e.created_at limit 1), v_s.price),
    'volume_24h', coalesce((select sum(e.gibb) from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours'), 0),
    'history', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('t', x.created_at, 'p', x.price_after, 'k', x.kind, 'n', x.gibb) order by x.created_at)
                         from (select * from public.market_events order by created_at desc limit 120) x), '[]'::jsonb),
    'my_gibb', (select w.balance from public.wallets w where w.user_id = v_me),
    'my_credits', (select w.credits from public.wallets w where w.user_id = v_me)
  );
end;
$$;

-- GIBB an die Bank verkaufen -> Credits
create or replace function public.market_sell(p_gibb bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_quote jsonb;
  v_rappen bigint;
  v_wallet public.wallets%rowtype;
  v_after numeric;
begin
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'sell_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'sell_rappen')::bigint;
  if v_rappen < 1 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'amount_too_small'); end if;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.balance < p_gibb then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_funds'); end if;

  update public.wallets set balance = balance - p_gibb, credits = credits + v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(v_me, null, p_gibb, 'MARKET_SELL', 'GIBB-Markt · Verkauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('sell', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;

-- GIBB mit Credits kaufen
create or replace function public.market_buy_with_credits(p_gibb bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_quote jsonb;
  v_rappen bigint;
  v_wallet public.wallets%rowtype;
  v_after numeric;
begin
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'buy_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'buy_rappen')::bigint;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.credits < v_rappen then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_credits', 'needed', v_rappen); end if;

  update public.wallets set balance = balance + p_gibb, credits = credits - v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(null, v_me, p_gibb, 'MARKET_BUY', 'GIBB-Markt · Kauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('buy_credits', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;

-- Stripe-Kauf: Kurs bewegen (vom Webhook nach credit_gibb_purchase aufgerufen; idempotent pro Event)
create or replace function public.market_record_stripe_buy(p_event text, p_user uuid, p_gibb bigint, p_rappen bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_after numeric;
begin
  if exists (select 1 from public.market_events where reference = p_event) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_after := private.market_apply('buy_stripe', p_user, p_gibb, p_rappen, p_event);
  return pg_catalog.jsonb_build_object('ok', true, 'price', v_after);
end;
$$;

revoke all on function public.market_quote(bigint) from public, anon;
revoke all on function public.get_market_state() from public, anon;
revoke all on function public.market_sell(bigint) from public, anon;
revoke all on function public.market_buy_with_credits(bigint) from public, anon;
revoke all on function public.market_record_stripe_buy(text, uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.market_quote(bigint) to authenticated, service_role;
grant execute on function public.get_market_state() to authenticated;
grant execute on function public.market_sell(bigint) to authenticated;
grant execute on function public.market_buy_with_credits(bigint) to authenticated;
grant execute on function public.market_record_stripe_buy(text, uuid, bigint, bigint) to service_role;


-- Stripe-Kauf zum Marktkurs gutschreiben (nur service_role, idempotent pro Stripe-Event/Session).
-- Prüft, dass der bezahlte Betrag dem beim Checkout berechneten Angebot entspricht (min. 50 Rappen).
create or replace function public.credit_market_purchase(
  stripe_event text,
  checkout_session text,
  payment_intent text,
  purchased_user uuid,
  purchased_coins bigint,
  paid_amount bigint,
  paid_currency text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet public.wallets%rowtype;
  v_transaction_id uuid;
  v_existing uuid;
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> 'service_role' then
    raise exception 'service_role_required';
  end if;
  if purchased_user is null or stripe_event is null or checkout_session is null
     or purchased_coins is null or purchased_coins < 1 or purchased_coins > 1000
     or paid_amount is null or paid_amount < 50 or lower(coalesce(paid_currency, '')) <> 'chf' then
    raise exception 'invalid_purchase';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(938241);
  select p.transaction_id into v_existing from public.coin_purchases p
  where p.stripe_event_id = stripe_event or p.checkout_session_id = checkout_session limit 1;
  if found then return v_existing; end if;

  select w.* into v_wallet from public.wallets w where w.user_id = purchased_user for update;
  if v_wallet.id is null then raise exception 'wallet_not_found'; end if;
  if v_wallet.status <> 'active' then raise exception 'wallet_locked'; end if;

  update public.wallets set balance = balance + purchased_coins, updated_at = pg_catalog.now() where id = v_wallet.id;
  v_transaction_id := private.append_transaction(null, purchased_user, purchased_coins, 'COIN_PURCHASE',
    'GIBB-Markt · Stripe · ' || purchased_coins || ' GIBB für CHF ' || pg_catalog.to_char(paid_amount::numeric / 100, 'FM999999990.00'));
  insert into public.coin_purchases (user_id, stripe_event_id, checkout_session_id, payment_intent_id, coins, amount_paid, currency, transaction_id)
  values (purchased_user, stripe_event, checkout_session, payment_intent, purchased_coins, paid_amount, 'chf', v_transaction_id);
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  perform private.market_apply('buy_stripe', purchased_user, purchased_coins, paid_amount, stripe_event);
  insert into public.notifications (user_id, kind, title, message)
  values (purchased_user, 'coin_purchase', 'Coins gekauft', purchased_coins || ' GIBB wurden deinem Wallet gutgeschrieben.');
  return v_transaction_id;
end;
$$;
revoke all on function public.credit_market_purchase(text, text, text, uuid, bigint, bigint, text) from public, anon, authenticated;
grant execute on function public.credit_market_purchase(text, text, text, uuid, bigint, bigint, text) to service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013120000_ilja_protection_and_owner_roles.sql =====================
-- Ilja ist Haupt-Owner und geschützt; Owner-Rechte können vergeben und entzogen werden.
--
-- * Haupt-Owner ist nur noch Ilja (ilja.podorieszach@icloud.com). Nur er darf Owner-Rechte
--   vergeben/entziehen sowie andere Owner sperren oder löschen.
-- * Iljas Owner-Rolle kann NIE entzogen werden; Ilja kann weder gesperrt (Wallet oder Login)
--   noch gelöscht werden. Owner werden darf er jederzeit.
-- * Andere Owner sind nicht geschützt: Ilja kann sie herabstufen, sperren oder löschen.

create or replace function private.is_ilja(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null and exists (
    select 1 from auth.users u
    where u.id = p_user_id and pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
  );
$$;
revoke all on function private.is_ilja(uuid) from public, anon, authenticated;

create or replace function private.is_primary_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_ilja(p_user_id)
     and exists (select 1 from public.profiles p where p.id = p_user_id and p.role = 'super_admin');
$$;
revoke all on function private.is_primary_owner(uuid) from public, anon, authenticated;

-- Geschützt: Einträge der Schutzliste plus immer Ilja.
create table if not exists private.protected_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now()
);
create or replace function private.is_protected_account(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null and (
    exists (select 1 from private.protected_accounts a where a.user_id = p_user_id)
    or private.is_ilja(p_user_id)
  );
$$;
revoke all on function private.is_protected_account(uuid) from public, anon, authenticated;

-- Login-Sperre (auth.users.banned_until) für geschützte Konten verhindern.
create or replace function private.protect_account_from_auth_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.banned_until is not null
     and new.banned_until > pg_catalog.now()
     and new.banned_until is distinct from old.banned_until
     and private.is_protected_account(new.id) then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_account_from_auth_ban on auth.users;
create trigger protect_account_from_auth_ban before update of banned_until on auth.users
  for each row execute function private.protect_account_from_auth_ban();

-- Iljas Owner-Rolle und Profil schützen (gilt für alle Wege, auch direktes SQL).
create or replace function private.protect_ilja_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if private.is_ilja(old.id) then
      raise exception using errcode = '42501', message = 'account_is_protected';
    end if;
    return old;
  end if;
  if old.role = 'super_admin' and new.role is distinct from 'super_admin' and private.is_ilja(old.id) then
    raise exception using errcode = '42501', message = 'account_is_protected';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_ilja_profile on public.profiles;
create trigger protect_ilja_profile before update of role or delete on public.profiles
  for each row execute function private.protect_ilja_profile();

-- Rollenänderungen über die App nur über admin_set_role (setzt die Freigabe).
create or replace function private.prevent_api_profile_role_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_api_request boolean := nullif(pg_catalog.current_setting('request.jwt', true), '') is not null
    or nullif(pg_catalog.current_setting('request.jwt.claims', true), '') is not null;
  v_authorized boolean := coalesce(pg_catalog.current_setting('gibbcoin.owner_role_change', true), '') = 'authorized';
begin
  if new.role is distinct from old.role and v_api_request and not v_authorized then
    raise exception using errcode = '42501', message = 'owner_only_role_change';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_protect_role_from_api on public.profiles;
create trigger profiles_protect_role_from_api before update of role on public.profiles
  for each row execute function private.prevent_api_profile_role_changes();

-- Rollen setzen: Admins/Owner verwalten user/admin; nur Ilja vergibt und entzieht Owner.
create or replace function public.admin_set_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text default 'Administrative Rollenänderung'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_user_id uuid;
  v_admin_role text;
  v_old_role text;
  v_reason text := coalesce(nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''), 'Administrative Rollenänderung');
begin
  v_admin_user_id := private.require_admin();
  perform private.assert_mfa_if_enrolled(v_admin_user_id);
  select p.role into v_admin_role from public.profiles p where p.id = v_admin_user_id;
  if v_admin_role <> 'super_admin' then raise exception 'owner_required'; end if;
  if p_target_user_id is null then raise exception 'target_required'; end if;
  if p_target_user_id = v_admin_user_id then raise exception 'cannot_change_own_role'; end if;
  if p_role not in ('user', 'admin', 'super_admin') then raise exception 'invalid_role'; end if;
  if pg_catalog.char_length(v_reason) > 120 then raise exception 'invalid_admin_reason'; end if;

  select p.role into v_old_role from public.profiles p where p.id = p_target_user_id for update;
  if v_old_role is null then raise exception 'user_not_found'; end if;
  if v_old_role = p_role then return p_role; end if;
  -- Owner-Rechte vergeben oder entziehen: nur der Haupt-Owner (Ilja)
  if (v_old_role = 'super_admin' or p_role = 'super_admin') and not private.is_primary_owner(v_admin_user_id) then
    raise exception 'primary_owner_required';
  end if;
  if v_old_role = 'super_admin' and private.is_ilja(p_target_user_id) then
    raise exception 'account_is_protected';
  end if;

  perform pg_catalog.set_config('gibbcoin.owner_role_change', 'authorized', true);
  update public.profiles set role = p_role where id = p_target_user_id;
  perform pg_catalog.set_config('gibbcoin.owner_role_change', '', true);

  perform private.write_admin_audit(
    v_admin_user_id, p_target_user_id, 'ROLE_CHANGED',
    pg_catalog.jsonb_build_object('role', v_old_role), pg_catalog.jsonb_build_object('role', p_role), v_reason
  );
  insert into public.notifications (user_id, kind, title, message)
  values (
    p_target_user_id, 'role_changed',
    case p_role when 'super_admin' then 'Owner-Rechte erhalten' when 'admin' then 'Administratorrechte erhalten' else 'Rechte entfernt' end,
    case p_role when 'super_admin' then 'Du bist jetzt Owner.' when 'admin' then 'Du besitzt jetzt Administratorrechte.' else 'Deine Admin- bzw. Owner-Rechte wurden entfernt.' end
  );
  return p_role;
end;
$$;
revoke all on function public.admin_set_role(uuid, text, text) from public, anon;
grant execute on function public.admin_set_role(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013130000_more_coin_and_miner_settings.sql =====================
-- Mehr Einstellungen für den Coinwert (GIBB-Markt) und die Miner.
--
-- Markt (neu einstellbar): Kurs direkt setzen, Kursänderung pro GIBB, Kursgrenzen, Verkaufsgebühr,
--   max. Menge pro Handel, Markt an/aus, Kaufen an/aus, Verkaufen an/aus, Verkaufslimit pro Tag.
-- Miner (neu): Halbierung der Belohnung alle N Blöcke, max. Blöcke pro Miner und Tag,
--   "nur mit echten Transaktionen minen" an/aus.
-- Ändern dürfen beides Ilja und Robyn (jeweils als Owner).

create or replace function private.can_edit_economy_settings(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
    and exists (select 1 from public.profiles p where p.id = p_user_id and p.role = 'super_admin')
    and (private.is_ilja(p_user_id) or p_user_id = 'd465d88f-0acb-4bff-ad55-945761acaeea'::uuid);
$$;
revoke all on function private.can_edit_economy_settings(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Markt
-- ---------------------------------------------------------------------------
alter table private.market_settings add column if not exists buy_enabled boolean not null default true;
alter table private.market_settings add column if not exists sell_enabled boolean not null default true;
alter table private.market_settings add column if not exists daily_sell_limit bigint not null default 0; -- 0 = kein Limit

create or replace function private.market_settings_json()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'price', s.price, 'step', s.step, 'min_price', s.min_price, 'max_price', s.max_price,
    'sell_fee', s.sell_fee, 'max_trade', s.max_trade, 'enabled', s.enabled,
    'buy_enabled', s.buy_enabled, 'sell_enabled', s.sell_enabled, 'daily_sell_limit', s.daily_sell_limit
  ) from private.market_settings s where s.singleton;
$$;
revoke all on function private.market_settings_json() from public, anon, authenticated;

create or replace function public.market_quote(p_gibb bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_buy numeric; v_sell numeric; v_after_buy numeric; v_after_sell numeric;
begin
  select * into v_s from private.market_settings where singleton;
  if p_gibb is null or p_gibb < 1 or p_gibb > v_s.max_trade then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount', 'max_trade', v_s.max_trade);
  end if;
  v_after_buy := v_s.price * pg_catalog.power(1 + v_s.step, p_gibb);
  v_after_sell := v_s.price / pg_catalog.power(1 + v_s.step, p_gibb);
  v_buy := pg_catalog.ceil(private.market_curve_sum(v_s.price, v_s.step, p_gibb));
  v_sell := pg_catalog.floor(private.market_curve_sum(v_after_sell, v_s.step, p_gibb) * (1 - v_s.sell_fee));
  return pg_catalog.jsonb_build_object(
    'ok', true, 'gibb', p_gibb, 'price', v_s.price,
    'buy_rappen', v_buy, 'buy_possible', v_after_buy <= v_s.max_price,
    'sell_rappen', v_sell, 'sell_possible', v_after_sell >= v_s.min_price,
    'price_after_buy', v_after_buy, 'price_after_sell', v_after_sell,
    'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade,
    -- "enabled" prüft auch der Stripe-Checkout: dort zählt, ob Kaufen erlaubt ist.
    'enabled', v_s.enabled and v_s.buy_enabled,
    'market_enabled', v_s.enabled, 'buy_enabled', v_s.enabled and v_s.buy_enabled,
    'sell_enabled', v_s.enabled and v_s.sell_enabled
  );
end;
$$;

create or replace function public.get_market_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_s private.market_settings%rowtype;
  v_day_ago numeric;
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  select * into v_s from private.market_settings where singleton;
  select e.price_after into v_day_ago from public.market_events e
  where e.created_at <= pg_catalog.now() - interval '24 hours' order by e.created_at desc limit 1;
  return pg_catalog.jsonb_build_object(
    'price', v_s.price, 'enabled', v_s.enabled, 'sell_fee', v_s.sell_fee, 'max_trade', v_s.max_trade,
    'min_price', v_s.min_price, 'max_price', v_s.max_price,
    'buy_enabled', v_s.enabled and v_s.buy_enabled, 'sell_enabled', v_s.enabled and v_s.sell_enabled,
    'daily_sell_limit', v_s.daily_sell_limit,
    'my_sold_24h', coalesce((select sum(e.gibb) from public.market_events e
                             where e.user_id = v_me and e.kind = 'sell' and e.created_at > pg_catalog.now() - interval '24 hours'), 0),
    'price_24h_ago', coalesce(v_day_ago, (select e.price_before from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours' order by e.created_at limit 1), v_s.price),
    'volume_24h', coalesce((select sum(e.gibb) from public.market_events e where e.created_at > pg_catalog.now() - interval '24 hours'), 0),
    'history', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('t', x.created_at, 'p', x.price_after, 'k', x.kind, 'n', x.gibb) order by x.created_at)
                         from (select * from public.market_events order by created_at desc limit 120) x), '[]'::jsonb),
    'my_gibb', (select w.balance from public.wallets w where w.user_id = v_me),
    'my_credits', (select w.credits from public.wallets w where w.user_id = v_me),
    'settings', case when private.can_edit_economy_settings(v_me) then private.market_settings_json() end
  );
end;
$$;

create or replace function public.market_sell(p_gibb bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_quote jsonb;
  v_rappen bigint;
  v_wallet public.wallets%rowtype;
  v_after numeric;
  v_limit bigint;
  v_sold bigint;
begin
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'market_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'sell_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'sell_disabled'); end if;
  if not (v_quote ->> 'sell_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'sell_rappen')::bigint;
  if v_rappen < 1 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'amount_too_small'); end if;

  select s.daily_sell_limit into v_limit from private.market_settings s where s.singleton;
  if v_limit > 0 then
    select coalesce(sum(e.gibb), 0) into v_sold from public.market_events e
    where e.user_id = v_me and e.kind = 'sell' and e.created_at > pg_catalog.now() - interval '24 hours';
    if v_sold + p_gibb > v_limit then
      return pg_catalog.jsonb_build_object('ok', false, 'error', 'daily_sell_limit', 'remaining', greatest(0, v_limit - v_sold));
    end if;
  end if;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.balance < p_gibb then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_funds'); end if;

  update public.wallets set balance = balance - p_gibb, credits = credits + v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(v_me, null, p_gibb, 'MARKET_SELL', 'GIBB-Markt · Verkauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('sell', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;

create or replace function public.market_buy_with_credits(p_gibb bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_quote jsonb;
  v_rappen bigint;
  v_wallet public.wallets%rowtype;
  v_after numeric;
begin
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'market_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'buy_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'buy_disabled'); end if;
  if not (v_quote ->> 'buy_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'buy_rappen')::bigint;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.credits < v_rappen then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_credits', 'needed', v_rappen); end if;

  update public.wallets set balance = balance + p_gibb, credits = credits - v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(null, v_me, p_gibb, 'MARKET_BUY', 'GIBB-Markt · Kauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('buy_credits', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;

-- Markt-Einstellungen speichern (Ilja/Robyn, mit Admin-PIN)
create or replace function public.admin_update_market_settings(p_value jsonb, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb := private.market_settings_json();
  v_s private.market_settings%rowtype;
begin
  if not private.can_edit_economy_settings(v_admin) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if p_value is null or pg_catalog.jsonb_typeof(p_value) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  v_pin_status := private.check_admin_pin(v_admin, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  select * into v_s from private.market_settings where singleton for update;
  v_s.min_price := greatest(0.01, least(100000, coalesce((p_value ->> 'min_price')::numeric, v_s.min_price)));
  v_s.max_price := greatest(0.01, least(100000, coalesce((p_value ->> 'max_price')::numeric, v_s.max_price)));
  if v_s.min_price > v_s.max_price then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_price_range');
  end if;
  v_s.price := greatest(v_s.min_price, least(v_s.max_price, coalesce((p_value ->> 'price')::numeric, v_s.price)));
  v_s.step := greatest(0, least(0.05, coalesce((p_value ->> 'step')::numeric, v_s.step)));
  v_s.sell_fee := greatest(0, least(0.9, coalesce((p_value ->> 'sell_fee')::numeric, v_s.sell_fee)));
  v_s.max_trade := greatest(1, least(100000, coalesce((p_value ->> 'max_trade')::bigint, v_s.max_trade)));
  v_s.enabled := coalesce((p_value ->> 'enabled')::boolean, v_s.enabled);
  v_s.buy_enabled := coalesce((p_value ->> 'buy_enabled')::boolean, v_s.buy_enabled);
  v_s.sell_enabled := coalesce((p_value ->> 'sell_enabled')::boolean, v_s.sell_enabled);
  v_s.daily_sell_limit := greatest(0, least(10000000, coalesce((p_value ->> 'daily_sell_limit')::bigint, v_s.daily_sell_limit)));

  update private.market_settings set
    price = v_s.price, step = v_s.step, min_price = v_s.min_price, max_price = v_s.max_price,
    sell_fee = v_s.sell_fee, max_trade = v_s.max_trade, enabled = v_s.enabled,
    buy_enabled = v_s.buy_enabled, sell_enabled = v_s.sell_enabled, daily_sell_limit = v_s.daily_sell_limit,
    updated_at = pg_catalog.now()
  where singleton;

  perform private.write_admin_audit(v_admin, v_admin, 'MARKET_SETTING_CHANGED', v_before, private.market_settings_json(), 'Markt-Einstellungen geändert');
  return pg_catalog.jsonb_build_object('ok', true, 'settings', private.market_settings_json());
end;
$$;

revoke all on function public.market_quote(bigint) from public, anon;
revoke all on function public.get_market_state() from public, anon;
revoke all on function public.market_sell(bigint) from public, anon;
revoke all on function public.market_buy_with_credits(bigint) from public, anon;
revoke all on function public.admin_update_market_settings(jsonb, text) from public, anon;
grant execute on function public.market_quote(bigint) to authenticated, service_role;
grant execute on function public.get_market_state() to authenticated;
grant execute on function public.market_sell(bigint) to authenticated;
grant execute on function public.market_buy_with_credits(bigint) to authenticated;
grant execute on function public.admin_update_market_settings(jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Miner
-- ---------------------------------------------------------------------------
create or replace function private.blockchain_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'enabled', coalesce((s.value ->> 'enabled')::boolean, true),
    'reward', greatest(0, least(1000, coalesce((s.value ->> 'reward')::bigint, 2))),
    'target_seconds', greatest(10, least(86400, coalesce((s.value ->> 'target_seconds')::integer, 120))),
    'min_bits', greatest(8, least(48, coalesce((s.value ->> 'min_bits')::integer, 16))),
    'max_bits', greatest(8, least(48, coalesce((s.value ->> 'max_bits')::integer, 36))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((s.value ->> 'cooldown_seconds')::integer, 90))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((s.value ->> 'max_tx_per_block')::integer, 500))),
    'halving_blocks', greatest(0, least(1000000, coalesce((s.value ->> 'halving_blocks')::integer, 0))),
    'max_blocks_per_day', greatest(0, least(100000, coalesce((s.value ->> 'max_blocks_per_day')::integer, 0))),
    'require_real_tx', coalesce((s.value ->> 'require_real_tx')::boolean, true)
  )
  from (select coalesce((select value from private.admin_control_settings where key = 'blockchain'), '{}'::jsonb) as value) s;
$$;
revoke all on function private.blockchain_settings() from public, anon, authenticated;

-- Belohnung für einen Block: Grundbelohnung, halbiert alle "halving_blocks" Blöcke.
create or replace function private.block_reward(p_height bigint)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when (s ->> 'halving_blocks')::integer > 0
      then ((s ->> 'reward')::bigint >> least(62, (greatest(0, p_height) / (s ->> 'halving_blocks')::integer))::integer)
    else (s ->> 'reward')::bigint end
  from (select private.blockchain_settings() as s) x;
$$;
revoke all on function private.block_reward(bigint) from public, anon, authenticated;

create or replace function public.admin_update_blockchain_settings(p_value jsonb, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.require_admin();
  v_pin_status text;
  v_before jsonb := private.blockchain_settings();
  v_after jsonb;
begin
  if not private.can_edit_economy_settings(v_admin) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required');
  end if;
  if p_value is null or pg_catalog.jsonb_typeof(p_value) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_settings');
  end if;
  v_pin_status := private.check_admin_pin(v_admin, p_pin);
  if v_pin_status <> 'ok' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'admin_pin_' || v_pin_status);
  end if;

  v_after := pg_catalog.jsonb_build_object(
    'enabled', coalesce((p_value ->> 'enabled')::boolean, (v_before ->> 'enabled')::boolean),
    'reward', greatest(0, least(1000, coalesce((p_value ->> 'reward')::bigint, (v_before ->> 'reward')::bigint))),
    'target_seconds', greatest(10, least(86400, coalesce((p_value ->> 'target_seconds')::integer, (v_before ->> 'target_seconds')::integer))),
    'min_bits', greatest(8, least(48, coalesce((p_value ->> 'min_bits')::integer, (v_before ->> 'min_bits')::integer))),
    'max_bits', greatest(8, least(48, coalesce((p_value ->> 'max_bits')::integer, (v_before ->> 'max_bits')::integer))),
    'cooldown_seconds', greatest(0, least(86400, coalesce((p_value ->> 'cooldown_seconds')::integer, (v_before ->> 'cooldown_seconds')::integer))),
    'max_tx_per_block', greatest(1, least(2000, coalesce((p_value ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer))),
    'halving_blocks', greatest(0, least(1000000, coalesce((p_value ->> 'halving_blocks')::integer, (v_before ->> 'halving_blocks')::integer))),
    'max_blocks_per_day', greatest(0, least(100000, coalesce((p_value ->> 'max_blocks_per_day')::integer, (v_before ->> 'max_blocks_per_day')::integer))),
    'require_real_tx', coalesce((p_value ->> 'require_real_tx')::boolean, (v_before ->> 'require_real_tx')::boolean)
  );
  if (v_after ->> 'min_bits')::integer > (v_after ->> 'max_bits')::integer then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_difficulty_range');
  end if;

  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('blockchain', v_after, v_admin, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;

  perform private.write_admin_audit(v_admin, v_admin, 'BLOCKCHAIN_SETTING_CHANGED', v_before, v_after, 'Blockchain-Einstellungen geändert');

  return pg_catalog.jsonb_build_object('ok', true, 'settings', v_after);
end;
$$;
revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

-- Bestehende Mining-Funktionen gezielt ergänzen (Text-Patch, damit Cloud-Anpassungen erhalten bleiben).
do $migration$
declare
  v_def text;
  v_anchor text;
  v_real_old constant text := $r$-- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if not exists ($r$;
  v_real_new constant text := $r$-- mining_needs_real_tx: Mining-Belohnungen allein reichen nicht für einen neuen Block.
  if coalesce((private.blockchain_settings() ->> 'require_real_tx')::boolean, true) and not exists ($r$;
begin
  -- Vorlage
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_block_template()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'miner_settings_v2') = 0 then
    v_def := pg_catalog.replace(v_def, v_real_old, v_real_new);
    v_anchor := $a$'reward', (v_settings ->> 'reward')::bigint,$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'get_block_template: Belohnung nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $b$'reward', private.block_reward(v_height), -- miner_settings_v2$b$);
    execute v_def;
  end if;

  -- Einreichen
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.submit_mined_block(bigint, text, bigint, bigint, integer, bigint, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'miner_settings_v2') = 0 then
    v_def := pg_catalog.replace(v_def, v_real_old, v_real_new);
    v_anchor := $a$v_reward bigint := (v_settings ->> 'reward')::bigint;$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'submit_mined_block: Belohnung nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $b$v_reward bigint := private.block_reward(p_height); -- miner_settings_v2$b$);
    v_anchor := '  select * into v_tip from public.blocks order by height desc limit 1;';
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'submit_mined_block: Einfügestelle nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, $c$  -- Tageslimit pro Miner (0 = unbegrenzt)
  if (v_settings ->> 'max_blocks_per_day')::integer > 0 and (
    select count(*) from public.blocks b
    where b.miner_user_id = v_user_id and b.mined_at > v_now - interval '24 hours'
  ) >= (v_settings ->> 'max_blocks_per_day')::integer then
    raise exception 'mining_daily_limit';
  end if;

$c$ || v_anchor);
    execute v_def;
  end if;

  -- Übersicht: zusätzliche Einstellungen mitliefern
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_blockchain_overview()'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'miner_settings_v2') = 0 then
    v_anchor := $a$'max_bits', (v_settings ->> 'max_bits')::integer,$a$;
    if pg_catalog.strpos(v_def, v_anchor) = 0 then raise exception 'get_blockchain_overview: Einfügestelle nicht gefunden'; end if;
    v_def := pg_catalog.replace(v_def, v_anchor, v_anchor || $b$
    'halving_blocks', (v_settings ->> 'halving_blocks')::integer, -- miner_settings_v2
    'max_blocks_per_day', (v_settings ->> 'max_blocks_per_day')::integer,
    'require_real_tx', (v_settings ->> 'require_real_tx')::boolean,
    'next_reward', private.block_reward(coalesce(v_tip.height, -1) + 1),
    'can_edit_settings', private.can_edit_economy_settings(v_user_id),$b$);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';


-- ===================== 20261013140000_owner_coin_removal_and_shared_settings.sql =====================
-- 1) Owner dürfen anderen Ownern GIBB abziehen – nur Ilja ist davon ausgenommen.
--    Admins (ohne Owner-Rolle) dürfen weiterhin keinem Owner etwas abziehen.
-- 2) Die Chain-Seite (Node) liest die Einstellungen der Hauptseite über
--    public.get_shared_chain_settings() (nur Einstellungen, keine Kontodaten).

do $migration$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.admin_adjust_balance_secure(uuid, bigint, text, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'owner_coin_removal_v2') = 0 then
    v_new := pg_catalog.regexp_replace(
      v_def,
      $re$if\s+v_target_role\s*=\s*'super_admin'\s+and\s+p_target_user_id\s*<>\s*v_admin_user_id\s+then$re$,
      $rep$if v_target_role = 'super_admin' and p_target_user_id <> v_admin_user_id
       and (private.is_ilja(p_target_user_id) or v_admin_role is distinct from 'super_admin') then -- owner_coin_removal_v2$rep$
    );
    if v_new = v_def then
      raise exception 'admin_adjust_balance_secure: Owner-Prüfung nicht gefunden';
    end if;
    -- v_admin_role muss vor der Prüfung gesetzt sein
    if pg_catalog.strpos(v_new, 'into v_admin_role') = 0 then
      raise exception 'admin_adjust_balance_secure: v_admin_role wird nicht gesetzt';
    end if;
    execute v_new;
  end if;
end;
$migration$;

create or replace function public.get_shared_chain_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'blockchain', private.blockchain_settings(),
    'market', (select pg_catalog.jsonb_build_object(
      'price', s.price, 'sell_fee', s.sell_fee, 'enabled', s.enabled, 'max_trade', s.max_trade,
      'min_price', s.min_price, 'max_price', s.max_price
    ) from private.market_settings s where s.singleton)
  );
$$;
revoke all on function public.get_shared_chain_settings() from public;
grant execute on function public.get_shared_chain_settings() to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013150000_chain_page_settings_only.sql =====================
-- Einstellungen nur noch auf der Chain-Seite (Ilja).
-- * Auf der Hauptseite gibt es keine Blockchain-/Coinwert-Einstellungen mehr; die Admin-Funktionen
--   lehnen jede Änderung ab.
-- * Die Chain-Seite (Node) überträgt ihre Einstellungen mit einem geheimen Schlüssel über
--   public.node_push_settings(). Den Schlüssel erzeugt "sudo gibb-chain-key" auf dem Server; der
--   Befehl gibt die passende Zeile "select private.set_node_settings_key('…');" für den SQL Editor aus.

create table if not exists private.node_settings_key (
  singleton boolean primary key default true check (singleton),
  key_hash text not null,
  updated_at timestamptz not null default now()
);
revoke all on table private.node_settings_key from public, anon, authenticated;

create or replace function private.set_node_settings_key(p_key text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_key is null or pg_catalog.char_length(p_key) < 32 then raise exception 'key_too_short'; end if;
  insert into private.node_settings_key (singleton, key_hash, updated_at)
  values (true, pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex'), pg_catalog.now())
  on conflict (singleton) do update set key_hash = excluded.key_hash, updated_at = excluded.updated_at;
  return 'Schlüssel der Chain-Seite gespeichert';
end;
$$;
revoke all on function private.set_node_settings_key(text) from public, anon, authenticated;

-- Hauptseite: niemand darf dort mehr Einstellungen ändern oder sehen.
create or replace function private.can_edit_economy_settings(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select false; $$;
revoke all on function private.can_edit_economy_settings(uuid) from public, anon, authenticated;

create or replace function public.admin_update_blockchain_settings(p_value jsonb, p_pin text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required'); $$;
revoke all on function public.admin_update_blockchain_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_blockchain_settings(jsonb, text) to authenticated;

create or replace function public.admin_update_market_settings(p_value jsonb, p_pin text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('ok', false, 'error', 'owner_required'); $$;
revoke all on function public.admin_update_market_settings(jsonb, text) from public, anon;
grant execute on function public.admin_update_market_settings(jsonb, text) to authenticated;

-- Kaufen und Verkaufen vorerst ausgeschaltet (auf der Chain-Seite wieder einschaltbar).
update private.market_settings set buy_enabled = false, sell_enabled = false, updated_at = now() where singleton;

-- Alle Kurse zurücksetzen: 1 Rp pro GIBB, Kursverlauf leer.
update private.market_settings set price = 1, updated_at = now() where singleton;
delete from public.market_events;

-- Chain-Seite -> Hauptseite
create or replace function public.node_push_settings(p_key text, p_blockchain jsonb, p_market jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_before jsonb := private.blockchain_settings();
  v_after jsonb;
  v_s private.market_settings%rowtype;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;

  if p_blockchain is not null and pg_catalog.jsonb_typeof(p_blockchain) = 'object' then
    v_after := pg_catalog.jsonb_build_object(
      'enabled', coalesce((p_blockchain ->> 'enabled')::boolean, (v_before ->> 'enabled')::boolean),
      'reward', greatest(0, least(1000, coalesce((p_blockchain ->> 'reward')::bigint, (v_before ->> 'reward')::bigint))),
      'target_seconds', greatest(10, least(86400, coalesce((p_blockchain ->> 'target_seconds')::integer, (v_before ->> 'target_seconds')::integer))),
      'min_bits', greatest(8, least(48, coalesce((p_blockchain ->> 'min_bits')::integer, (v_before ->> 'min_bits')::integer))),
      'max_bits', greatest(8, least(48, coalesce((p_blockchain ->> 'max_bits')::integer, (v_before ->> 'max_bits')::integer))),
      'cooldown_seconds', greatest(0, least(86400, coalesce((p_blockchain ->> 'cooldown_seconds')::integer, (v_before ->> 'cooldown_seconds')::integer))),
      'max_tx_per_block', greatest(1, least(2000, coalesce((p_blockchain ->> 'max_tx_per_block')::integer, (v_before ->> 'max_tx_per_block')::integer))),
      'halving_blocks', greatest(0, least(1000000, coalesce((p_blockchain ->> 'halving_blocks')::integer, (v_before ->> 'halving_blocks')::integer))),
      'max_blocks_per_day', greatest(0, least(100000, coalesce((p_blockchain ->> 'max_blocks_per_day')::integer, (v_before ->> 'max_blocks_per_day')::integer))),
      'require_real_tx', coalesce((p_blockchain ->> 'require_real_tx')::boolean, (v_before ->> 'require_real_tx')::boolean)
    );
    if (v_after ->> 'min_bits')::integer > (v_after ->> 'max_bits')::integer then
      v_after := v_after || pg_catalog.jsonb_build_object('max_bits', (v_after ->> 'min_bits')::integer);
    end if;
    insert into private.admin_control_settings (key, value, updated_by, updated_at)
    values ('blockchain', v_after, null, pg_catalog.clock_timestamp())
    on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  end if;

  if p_market is not null and pg_catalog.jsonb_typeof(p_market) = 'object' then
    select * into v_s from private.market_settings where singleton for update;
    v_s.min_price := greatest(0.01, least(100000, coalesce((p_market ->> 'min_price')::numeric, v_s.min_price)));
    v_s.max_price := greatest(v_s.min_price, least(100000, coalesce((p_market ->> 'max_price')::numeric, v_s.max_price)));
    -- Kurs nur setzen, wenn ausdrücklich mitgeschickt (sonst bewegt ihn der Handel)
    v_s.price := greatest(v_s.min_price, least(v_s.max_price, coalesce((p_market ->> 'price')::numeric, v_s.price)));
    v_s.step := greatest(0, least(0.05, coalesce((p_market ->> 'step')::numeric, v_s.step)));
    v_s.sell_fee := greatest(0, least(0.9, coalesce((p_market ->> 'sell_fee')::numeric, v_s.sell_fee)));
    v_s.max_trade := greatest(1, least(100000, coalesce((p_market ->> 'max_trade')::bigint, v_s.max_trade)));
    v_s.enabled := coalesce((p_market ->> 'enabled')::boolean, v_s.enabled);
    v_s.buy_enabled := coalesce((p_market ->> 'buy_enabled')::boolean, v_s.buy_enabled);
    v_s.sell_enabled := coalesce((p_market ->> 'sell_enabled')::boolean, v_s.sell_enabled);
    v_s.daily_sell_limit := greatest(0, least(10000000, coalesce((p_market ->> 'daily_sell_limit')::bigint, v_s.daily_sell_limit)));
    update private.market_settings set
      price = v_s.price, step = v_s.step, min_price = v_s.min_price, max_price = v_s.max_price,
      sell_fee = v_s.sell_fee, max_trade = v_s.max_trade, enabled = v_s.enabled,
      buy_enabled = v_s.buy_enabled, sell_enabled = v_s.sell_enabled, daily_sell_limit = v_s.daily_sell_limit,
      updated_at = pg_catalog.now()
    where singleton;
  end if;

  return pg_catalog.jsonb_build_object('ok', true, 'blockchain', private.blockchain_settings(), 'market', private.market_settings_json());
end;
$$;
revoke all on function public.node_push_settings(text, jsonb, jsonb) from public;
grant execute on function public.node_push_settings(text, jsonb, jsonb) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013160000_admin_coin_grants_switch.sql =====================
-- "Admin Coins geben" abschaltbar – standardmässig AUS.
-- Eingeschaltet wird es nur auf der Chain-Seite (Ilja); die überträgt den Schalter mit dem
-- Schlüssel der Chain-Seite über public.node_set_admin_features(). Coins abziehen bleibt möglich.

create or replace function private.admin_coin_grants_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value ->> 'coin_grants')::boolean
                   from private.admin_control_settings s where s.key = 'admin_features'), false);
$$;
revoke all on function private.admin_coin_grants_enabled() from public, anon, authenticated;

-- Für das Admin-Panel: ist Gutschreiben gerade erlaubt?
create or replace function public.get_admin_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('coin_grants', private.admin_coin_grants_enabled()); $$;
revoke all on function public.get_admin_features() from public, anon;
grant execute on function public.get_admin_features() to authenticated;

-- Chain-Seite -> Hauptseite (mit dem Schlüssel aus "sudo gibb-chain-key")
create or replace function public.node_set_admin_features(p_key text, p_features jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('admin_features',
          pg_catalog.jsonb_build_object('coin_grants', coalesce((p_features ->> 'coin_grants')::boolean, false)),
          null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true, 'coin_grants', private.admin_coin_grants_enabled());
end;
$$;
revoke all on function public.node_set_admin_features(text, jsonb) from public;
grant execute on function public.node_set_admin_features(text, jsonb) to anon, authenticated, service_role;

-- Gutschriften im Admin-Panel sperren, solange der Schalter aus ist.
do $migration$
declare
  v_def text;
  v_pos integer;
begin
  v_def := pg_catalog.replace(pg_catalog.pg_get_functiondef('public.admin_adjust_balance_secure(uuid, bigint, text, text)'::pg_catalog.regprocedure), chr(13), '');
  if pg_catalog.strpos(v_def, 'coin_grants_switch') = 0 then
    v_pos := pg_catalog.strpos(v_def, E'\nbegin\n');
    -- Andere Schreibweise (z. B. in der Cloud): überspringen – 20261013180000 ersetzt die Funktion ohnehin.
    if v_pos = 0 then raise notice 'admin_adjust_balance_secure übersprungen'; return; end if;
    v_def := pg_catalog.left(v_def, v_pos + 6)
      || E'  -- coin_grants_switch: Gutschreiben nur, wenn auf der Chain-Seite eingeschaltet\n'
      || E'  if p_amount > 0 and not private.admin_coin_grants_enabled() then\n'
      || E'    return pg_catalog.jsonb_build_object(''ok'', false, ''error'', ''coin_grants_disabled'');\n'
      || E'  end if;\n'
      || pg_catalog.substr(v_def, v_pos + 7);
    execute v_def;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';


-- ===================== 20261013170000_node_account_cleanup.sql =====================
-- Chain-Seite räumt gelöschte Website-Konten auf: Sie fragt mit ihrem Schlüssel nach, welche
-- ihrer Website-Konten (sb_<uuid>) es noch gibt. Liefert nur IDs, die es noch gibt – keine Kontodaten.
create or replace function public.node_existing_users(p_key text, p_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  select k.key_hash into v_hash from private.node_settings_key k where k.singleton;
  if v_hash is null or p_key is null
     or pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex') <> v_hash then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_ids is null or pg_catalog.cardinality(p_ids) > 5000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_ids');
  end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'existing', coalesce((select pg_catalog.jsonb_agg(u.id) from auth.users u where u.id = any (p_ids)), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.node_existing_users(text, uuid[]) from public;
grant execute on function public.node_existing_users(text, uuid[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013180000_chain_page_coin_admin.sql =====================
-- Coins geben und abziehen nur noch auf der Chain-Seite (Ilja).
-- * Hauptseite: admin_adjust_balance_secure lehnt jede Änderung ab.
-- * Chain-Seite: node_list_users / node_adjust_balance mit dem Schlüssel aus "sudo gibb-chain-key".

create or replace function private.node_key_ok(p_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_key is not null and exists (
    select 1 from private.node_settings_key k
    where k.singleton and k.key_hash = pg_catalog.encode(extensions.digest(p_key, 'sha256'), 'hex')
  );
$$;
revoke all on function private.node_key_ok(text) from public, anon, authenticated;

-- Hauptseite: kein Coins geben/abziehen mehr
create or replace function public.admin_adjust_balance_secure(
  p_target_user_id uuid,
  p_amount bigint,
  p_reason text,
  p_pin text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select pg_catalog.jsonb_build_object('ok', false, 'error', 'coins_on_chain_page'); $$;
revoke all on function public.admin_adjust_balance_secure(uuid, bigint, text, text) from public, anon;
grant execute on function public.admin_adjust_balance_secure(uuid, bigint, text, text) to authenticated;

-- Chain-Seite: alle Website-Benutzer mit Guthaben
create or replace function public.node_list_users(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'users', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', p.id, 'username', p.username, 'display_name', p.display_name, 'role', p.role,
      'balance', coalesce(w.balance, 0), 'status', coalesce(w.status, 'active')
    ) order by pg_catalog.lower(coalesce(nullif(p.username, ''), p.display_name, '')))
    from public.profiles p left join public.wallets w on w.user_id = p.id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_users(text) from public;
grant execute on function public.node_list_users(text) to anon, authenticated, service_role;

-- Chain-Seite: Coins geben (positiv) oder abziehen (negativ)
create or replace function public.node_adjust_balance(p_key text, p_user uuid, p_amount bigint, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_wallet public.wallets%rowtype;
  v_reason text := pg_catalog.left(coalesce(nullif(pg_catalog.btrim(coalesce(p_reason, '')), ''), 'Chain-Seite'), 120);
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_user is null or p_amount is null or p_amount = 0 or pg_catalog.abs(p_amount) > 1000000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;

  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  select * into v_wallet from public.wallets where user_id = p_user for update;
  if v_wallet.id is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found'); end if;
  if p_amount < 0 and v_wallet.balance < -p_amount then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_balance', 'balance', v_wallet.balance);
  end if;

  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where id = v_wallet.id;
  if p_amount > 0 then
    v_tx := private.append_transaction(null, p_user, p_amount, 'ADMIN_MINT', 'Owner-Gutschrift · ' || v_reason);
  else
    v_tx := private.append_transaction(p_user, null, -p_amount, 'ADMIN_BURN', 'Owner-Abzug · ' || v_reason);
  end if;

  begin
    insert into public.notifications (user_id, kind, title, message)
    values (p_user, 'admin_adjustment',
            case when p_amount > 0 then 'Coins erhalten' else 'Coins abgezogen' end,
            case when p_amount > 0 then p_amount || ' GIBB wurden dir gutgeschrieben.' else (-p_amount) || ' GIBB wurden dir abgezogen.' end
              || ' Grund: ' || v_reason);
  exception when others then null; -- Mitteilung ist optional
  end;

  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx, 'balance', v_wallet.balance + p_amount);
end;
$$;
revoke all on function public.node_adjust_balance(text, uuid, bigint, text) from public;
grant execute on function public.node_adjust_balance(text, uuid, bigint, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013190000_node_mining_reward_key.sql =====================
-- Chain-Seite und Hauptseite synchron halten:
-- Findet ein Website-Konto (sb_<uuid>) auf der Chain-Seite einen Block, wird die Belohnung mit dem
-- Schlüssel der Chain-Seite auf das Website-Wallet gebucht (einmal pro Block-Hash).
-- Die Guthaben der Chain-Seite werden danach regelmässig von der Hauptseite übernommen.

create table if not exists private.node_mining_credits (
  block_hash text primary key,
  user_id uuid,
  amount bigint not null,
  height bigint,
  transaction_id uuid,
  created_at timestamptz not null default now()
);
revoke all on table private.node_mining_credits from public, anon, authenticated;

create or replace function public.node_mining_reward(p_key text, p_user uuid, p_amount bigint, p_block_hash text, p_height bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  if p_user is null or p_block_hash is null or pg_catalog.char_length(p_block_hash) < 16 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 10000 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount');
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  if exists (select 1 from private.node_mining_credits c where c.block_hash = p_block_hash) then
    return pg_catalog.jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where user_id = p_user;
  if not found then
    -- Konto gibt es nicht mehr: als erledigt merken, damit es nicht ewig erneut versucht wird
    insert into private.node_mining_credits (block_hash, user_id, amount, height) values (p_block_hash, null, p_amount, p_height);
    return pg_catalog.jsonb_build_object('ok', true, 'skipped', 'wallet_not_found');
  end if;
  v_tx := private.append_transaction(null, p_user, p_amount, 'MINING_REWARD',
    'Chain-Seite · Block #' || coalesce(p_height::text, '?') || ' gefunden');
  insert into private.node_mining_credits (block_hash, user_id, amount, height, transaction_id)
  values (p_block_hash, p_user, p_amount, p_height, v_tx);
  return pg_catalog.jsonb_build_object('ok', true, 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_mining_reward(text, uuid, bigint, text, bigint) from public;
grant execute on function public.node_mining_reward(text, uuid, bigint, text, bigint) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013200000_bank_transfer_purchases.sql =====================
-- GIBB per Banküberweisung kaufen.
-- * Hauptseite: Kundin/Kunde erstellt eine Bestellung, bekommt IBAN, Betrag und Verwendungszweck.
-- * Chain-Seite (Ilja): sieht offene Bestellungen und bestätigt den Zahlungseingang -> GIBB werden gutgeschrieben.
-- IBAN und Kontoinhaber trägt Ilja auf der Chain-Seite ein; sie werden mit dem Chain-Schlüssel übertragen.

alter table private.market_settings add column if not exists bank_enabled boolean not null default false;
alter table private.market_settings add column if not exists bank_iban text not null default '';
alter table private.market_settings add column if not exists bank_holder text not null default '';

alter table public.market_events drop constraint if exists market_events_kind_check;
alter table public.market_events add constraint market_events_kind_check
  check (kind in ('buy_stripe', 'buy_credits', 'buy_bank', 'sell'));

create table if not exists public.bank_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  gibb bigint not null check (gibb > 0),
  rappen bigint not null check (rappen >= 100),
  reference text not null unique,
  status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  transaction_id uuid
);
create index if not exists bank_orders_user_idx on public.bank_orders(user_id, created_at desc);
alter table public.bank_orders enable row level security;
drop policy if exists "read own bank orders" on public.bank_orders;
create policy "read own bank orders" on public.bank_orders for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.bank_orders from anon, authenticated;
grant select on public.bank_orders to authenticated;

-- Bestellung anlegen (Preis wird zum aktuellen Kurs festgehalten; Überweisung ab CHF 1.00)
create or replace function public.create_bank_order(p_gibb bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_s private.market_settings%rowtype;
  v_quote jsonb;
  v_rappen bigint;
  v_ref text;
  v_order public.bank_orders%rowtype;
begin
  select * into v_s from private.market_settings where singleton;
  if not v_s.enabled or not v_s.buy_enabled then return pg_catalog.jsonb_build_object('ok', false, 'error', 'buy_disabled'); end if;
  if not v_s.bank_enabled or pg_catalog.btrim(v_s.bank_iban) = '' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'bank_disabled'); end if;
  if (select count(*) from public.bank_orders o where o.user_id = v_me and o.status = 'pending') >= 3 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'too_many_open_orders');
  end if;
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'buy_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'buy_rappen')::bigint;
  if v_rappen < 100 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'bank_amount_too_small'); end if;
  loop
    v_ref := 'GIBB-' || pg_catalog.upper(pg_catalog.substr(pg_catalog.translate(pg_catalog.encode(extensions.gen_random_bytes(8), 'base64'), '+/=0O1Il', ''), 1, 6));
    exit when pg_catalog.char_length(v_ref) = 11 and not exists (select 1 from public.bank_orders o where o.reference = v_ref);
  end loop;
  insert into public.bank_orders (user_id, gibb, rappen, reference) values (v_me, p_gibb, v_rappen, v_ref) returning * into v_order;
  return pg_catalog.jsonb_build_object('ok', true, 'id', v_order.id, 'gibb', v_order.gibb, 'rappen', v_order.rappen,
    'reference', v_order.reference, 'iban', v_s.bank_iban, 'holder', v_s.bank_holder);
end;
$$;
revoke all on function public.create_bank_order(bigint) from public, anon;
grant execute on function public.create_bank_order(bigint) to authenticated;

create or replace function public.cancel_bank_order(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
begin
  update public.bank_orders set status = 'cancelled', decided_at = pg_catalog.now()
  where id = p_id and user_id = v_me and status = 'pending';
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.cancel_bank_order(uuid) from public, anon;
grant execute on function public.cancel_bank_order(uuid) to authenticated;

-- Bankdaten für die Anzeige (nur angemeldete Nutzer)
create or replace function public.get_bank_details()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object('enabled', s.bank_enabled and pg_catalog.btrim(s.bank_iban) <> '', 'iban', s.bank_iban, 'holder', s.bank_holder)
  from private.market_settings s where s.singleton;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

-- Chain-Seite: Bankdaten setzen
create or replace function public.node_set_bank_settings(p_key text, p_enabled boolean, p_iban text, p_holder text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_iban text := pg_catalog.upper(pg_catalog.regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_iban <> '' and v_iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_iban');
  end if;
  -- Für die Anzeige in Vierergruppen
  v_iban := pg_catalog.btrim(pg_catalog.regexp_replace(v_iban, '(.{4})', '\1 ', 'g'));
  update private.market_settings set bank_enabled = coalesce(p_enabled, false), bank_iban = v_iban,
    bank_holder = pg_catalog.left(pg_catalog.btrim(coalesce(p_holder, '')), 80), updated_at = pg_catalog.now()
  where singleton;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_bank_settings(text, boolean, text, text) from public;
grant execute on function public.node_set_bank_settings(text, boolean, text, text) to anon, authenticated, service_role;

-- Chain-Seite: Bestellungen auflisten
create or replace function public.node_list_bank_orders(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'orders', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', o.id, 'gibb', o.gibb, 'rappen', o.rappen, 'reference', o.reference, 'status', o.status,
      'created_at', o.created_at, 'decided_at', o.decided_at,
      'username', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer')
    ) order by (o.status = 'pending') desc, o.created_at desc)
    from (select * from public.bank_orders order by created_at desc limit 200) o
    left join public.profiles p on p.id = o.user_id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_bank_orders(text) from public;
grant execute on function public.node_list_bank_orders(text) to anon, authenticated, service_role;

-- Chain-Seite: Zahlung bestätigen (GIBB gutschreiben) oder ablehnen
create or replace function public.node_decide_bank_order(p_key text, p_id uuid, p_paid boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_order public.bank_orders%rowtype;
  v_tx uuid;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  select * into v_order from public.bank_orders where id = p_id for update;
  if v_order.id is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_order.status <> 'pending' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'already_decided'); end if;

  if not coalesce(p_paid, false) then
    update public.bank_orders set status = 'rejected', decided_at = pg_catalog.now() where id = p_id;
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (v_order.user_id, 'coin_purchase', 'Überweisung nicht erhalten',
              'Für die Bestellung ' || v_order.reference || ' ist keine Zahlung eingegangen. Die Bestellung wurde geschlossen.');
    exception when others then null;
    end;
    return pg_catalog.jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  update public.wallets set balance = balance + v_order.gibb, updated_at = pg_catalog.now() where user_id = v_order.user_id;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'wallet_not_found'); end if;
  v_tx := private.append_transaction(null, v_order.user_id, v_order.gibb, 'COIN_PURCHASE',
    'GIBB-Kauf per Überweisung · ' || v_order.reference || ' · CHF ' || pg_catalog.to_char(v_order.rappen::numeric / 100, 'FM999999990.00'));
  update public.bank_orders set status = 'paid', decided_at = pg_catalog.now(), transaction_id = v_tx where id = p_id;
  perform private.market_apply('buy_bank', v_order.user_id, v_order.gibb, v_order.rappen, 'bank:' || v_order.reference);
  begin
    insert into public.notifications (user_id, kind, title, message)
    values (v_order.user_id, 'coin_purchase', 'Coins gekauft', v_order.gibb || ' GIBB wurden deinem Wallet gutgeschrieben (Überweisung ' || v_order.reference || ').');
  exception when others then null;
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'status', 'paid', 'transaction_id', v_tx);
end;
$$;
revoke all on function public.node_decide_bank_order(text, uuid, boolean) from public;
grant execute on function public.node_decide_bank_order(text, uuid, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013210000_site_tabs.sql =====================
-- Einzelne Tabs der Hauptseite ein-/ausschalten (auf der Chain-Seite, mit dem Chain-Schlüssel).
-- Home und Konto bleiben immer sichtbar.

create or replace function public.get_site_features()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'disabled_tabs', coalesce((select s.value -> 'disabled_tabs' from private.admin_control_settings s where s.key = 'site_tabs'), '[]'::jsonb)
  );
$$;
revoke all on function public.get_site_features() from public;
grant execute on function public.get_site_features() to anon, authenticated;

create or replace function public.node_set_site_tabs(p_key text, p_disabled text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tabs text[];
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select coalesce(array_agg(distinct t), '{}') into v_tabs
  from unnest(coalesce(p_disabled, '{}')) t
  where t in ('send', 'games', 'community', 'activity', 'chain', 'market');
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('site_tabs', pg_catalog.jsonb_build_object('disabled_tabs', pg_catalog.to_jsonb(v_tabs)), null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true, 'disabled_tabs', pg_catalog.to_jsonb(v_tabs));
end;
$$;
revoke all on function public.node_set_site_tabs(text, text[]) from public;
grant execute on function public.node_set_site_tabs(text, text[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013220000_chain_page_admin.sql =====================
-- Admin-Bereich auf der Chain-Seite.
-- Die Chain-Seite (Ilja, mit Server-Code angemeldet) ruft die bestehenden Admin-Funktionen mit dem
-- Chain-Schlüssel auf – ausgeführt als Iljas Owner-Konto. Geschützte Aktionen verlangen weiterhin
-- den Admin-PIN (p_pin), so wie bisher im Admin-Panel der Hauptseite.

create or replace function private.node_owner_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select u.id from auth.users u where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com' limit 1; $$;
revoke all on function private.node_owner_id() from public, anon, authenticated;

-- Als Owner auftreten (nur innerhalb der laufenden Anfrage)
create or replace function private.node_act_as_owner()
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid := private.node_owner_id();
begin
  if v_owner is null then raise exception 'owner_not_found'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', v_owner::text, true);
  perform pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  perform pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_owner, 'role', 'authenticated', 'aal', 'aal2', 'amr', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('method', 'totp')))::text, true);
  return v_owner;
end;
$$;
revoke all on function private.node_act_as_owner() from public, anon, authenticated;

-- Allgemeiner Aufruf erlaubter Admin-Funktionen
create or replace function public.node_owner_call(p_key text, p_fn text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_args text;
  v_rows jsonb;
  v_table boolean;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_fn is null or p_fn not in (
    'admin_list_users', 'admin_pin_status', 'admin_coin_stats', 'admin_list_visual_roles', 'admin_list_account_locks',
    'admin_verify_pin', 'admin_set_pin', 'owner_reset_admin_pin', 'admin_set_role', 'admin_set_visual_role', 'admin_reset_coin_stats',
    'admin_list_operations', 'admin_list_control_center_page', 'admin_list_transfer_approvals', 'admin_update_operation',
    'admin_update_control', 'admin_create_class', 'admin_update_case', 'admin_update_catalog', 'admin_run_health_check',
    'admin_set_transfer_threshold', 'get_game_center_state', 'get_dino_admin_state', 'get_global_game_limits',
    'admin_set_game_enabled', 'admin_set_dino_game_settings', 'admin_set_global_game_limits',
    'admin_list_audit_logs', 'admin_visitor_stats', 'admin_add_class_member', 'admin_remove_class_member'
  ) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'function_not_allowed');
  end if;
  if p_args is not null and pg_catalog.jsonb_typeof(p_args) <> 'object' then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_args');
  end if;

  perform private.node_act_as_owner();
  select pg_catalog.string_agg(pg_catalog.format('%I => %L', e.key, e.value), ', ')
  into v_args
  from pg_catalog.jsonb_each_text(coalesce(p_args, '{}'::jsonb)) e
  where e.key ~ '^p_[a-z_]+$';

  begin
    execute pg_catalog.format(
      'select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r)), ''[]''::jsonb) from public.%I(%s) r',
      p_fn, coalesce(v_args, '')
    ) into v_rows;
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  -- Tabellen-Funktion (mehrere Zeilen/Spalten) oder einfacher Rückgabewert?
  select bool_or(p.proretset or t.typtype = 'c' or p.prorettype = 'pg_catalog.record'::pg_catalog.regtype)
  into v_table
  from pg_catalog.pg_proc p join pg_catalog.pg_type t on t.oid = p.prorettype
  where p.pronamespace = 'public'::pg_catalog.regnamespace and p.proname = p_fn;
  return pg_catalog.jsonb_build_object('ok', true, 'fn', p_fn, 'table', coalesce(v_table, true), 'rows', v_rows);
end;
$$;
revoke all on function public.node_owner_call(text, text, jsonb) from public;
grant execute on function public.node_owner_call(text, text, jsonb) to anon, authenticated, service_role;

-- Bannen / Entbannen (Login und Wallet). Ilja selbst kann nicht gebannt werden.
create or replace function public.node_set_account_status(p_key text, p_user uuid, p_status text, p_minutes integer, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_until timestamptz;
  v_reason text;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or p_status not in ('active', 'locked') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  if p_minutes is not null and p_minutes not in (60, 1440, 10080) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_lock_duration'); end if;
  v_owner := private.node_act_as_owner();
  if p_user = v_owner then return pg_catalog.jsonb_build_object('ok', false, 'error', 'cannot_lock_own_account'); end if;
  if p_status = 'locked' and private.is_protected_account(p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected');
  end if;
  if not exists (select 1 from public.profiles p where p.id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found'); end if;
  v_until := case when p_status = 'locked' and p_minutes is not null then pg_catalog.now() + pg_catalog.make_interval(mins => p_minutes) end;
  v_reason := case when p_status = 'locked'
    then coalesce(nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_reason, '')), 120), ''), 'Konto auf der Chain-Seite gebannt')
    else 'Bann auf der Chain-Seite aufgehoben' end;
  begin
    update auth.users set banned_until = case when p_status = 'locked' then coalesce(v_until, pg_catalog.now() + interval '100 years') end
    where id = p_user;
    perform public.admin_apply_wallet_status_v2(v_owner, p_user, p_status, v_reason, v_until);
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'status', p_status, 'locked_until', v_until);
end;
$$;
revoke all on function public.node_set_account_status(text, uuid, text, integer, text) from public;
grant execute on function public.node_set_account_status(text, uuid, text, integer, text) to anon, authenticated, service_role;

-- Konto endgültig löschen (mit Admin-PIN). Geschützte Konten (Ilja) bleiben.
create or replace function public.node_delete_account(p_key text, p_user uuid, p_pin text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_auth jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_owner := private.node_act_as_owner();
  if p_user is null or p_user = v_owner or private.is_protected_account(p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'account_is_protected');
  end if;
  v_auth := public.admin_authorize_account_deletion(v_owner, p_user, p_pin);
  if not coalesce((v_auth ->> 'ok')::boolean, false) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', coalesce(v_auth ->> 'error', 'account_delete_not_authorized'));
  end if;
  begin
    delete from auth.users where id = p_user;
    perform public.admin_finalize_account_deletion(v_owner, p_user);
  exception when others then
    return pg_catalog.jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return pg_catalog.jsonb_build_object('ok', true, 'display_name', v_auth ->> 'display_name');
end;
$$;
revoke all on function public.node_delete_account(text, uuid, text) from public;
grant execute on function public.node_delete_account(text, uuid, text) to anon, authenticated, service_role;

-- Passwort-Reset: liefert die E-Mail-Adresse (die Chain-Seite löst den Versand bei Supabase Auth aus)
create or replace function public.node_password_reset(p_key text, p_user uuid, p_sent boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_auth jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  v_owner := private.node_act_as_owner();
  if coalesce(p_sent, false) then
    begin
      perform public.admin_record_password_reset(v_owner, p_user);
    exception when others then null; -- nur Protokoll
    end;
    return pg_catalog.jsonb_build_object('ok', true);
  end if;
  v_auth := public.admin_authorize_password_reset(v_owner, p_user);
  if not coalesce((v_auth ->> 'ok')::boolean, false) or (v_auth ->> 'email') is null then
    return pg_catalog.jsonb_build_object('ok', false, 'error', coalesce(v_auth ->> 'error', 'password_reset_not_authorized'));
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'email', v_auth ->> 'email', 'display_name', v_auth ->> 'display_name');
end;
$$;
revoke all on function public.node_password_reset(text, uuid, boolean) from public;
grant execute on function public.node_password_reset(text, uuid, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013230000_owner_support_only.sql =====================
-- Owner-Rang = nur Support-Tickets bearbeiten.
-- * Alle Admin-Funktionen (private.require_admin) gehen nur noch für Ilja – praktisch nur über die
--   Chain-Seite (node_owner_call). Andere Owner und Admins haben keine Admin-Rechte mehr.
-- * Owner (super_admin) können auf der Hauptseite alle Support-Tickets sehen, beantworten und den
--   Status/die Priorität ändern.

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_wallet_status text;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if exists (
    select 1 from auth.mfa_factors f
    where f.user_id = v_user_id and f.status = 'verified'
  ) and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required';
  end if;
  select p.role, w.status into v_role, v_wallet_status
  from public.profiles p join public.wallets w on w.user_id = p.id
  where p.id = v_user_id;
  if v_role not in ('admin', 'super_admin') then raise exception 'admin_required'; end if;
  -- Admin-Funktionen nur noch für den Haupt-Owner (Ilja, über die Chain-Seite)
  if not private.is_ilja(v_user_id) then raise exception 'admin_required'; end if;
  if v_wallet_status <> 'active' then raise exception 'account_locked'; end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_admin() from public, anon, authenticated;

create or replace function private.require_support_owner()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if not exists (
    select 1 from public.profiles p join public.wallets w on w.user_id = p.id
    where p.id = v_user_id and p.role = 'super_admin' and w.status = 'active'
  ) then
    raise exception 'owner_required';
  end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_support_owner() from public, anon, authenticated;

-- Alle Tickets (neueste und offene zuerst)
create or replace function public.support_list_cases(p_status text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_support_owner();
  return coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', c.id, 'subject', c.subject, 'body', c.body, 'status', c.status, 'priority', c.priority,
      'created_at', c.created_at, 'updated_at', c.updated_at,
      'requester', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer'),
      'assigned', coalesce(nullif(a.username, ''), a.display_name)
    ) order by (c.status = 'closed'), c.updated_at desc)
    from (select * from public.support_cases where p_status is null or status = p_status order by updated_at desc limit 200) c
    left join public.profiles p on p.id = c.requester_id
    left join public.profiles a on a.id = c.assigned_to
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.support_list_cases(text) from public, anon;
grant execute on function public.support_list_cases(text) to authenticated;

-- Ticket bearbeiten und optional antworten (Antwort kommt als Mitteilung bei der Person an)
create or replace function public.support_update_case(p_case_id uuid, p_status text, p_priority text, p_reply text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_support_owner();
  v_case public.support_cases%rowtype;
  v_reply text := pg_catalog.left(pg_catalog.btrim(coalesce(p_reply, '')), 1000);
begin
  if p_status not in ('open', 'in_progress', 'waiting', 'closed') or p_priority not in ('low', 'normal', 'high', 'urgent') then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  update public.support_cases set status = p_status, priority = p_priority, assigned_to = v_me, updated_at = pg_catalog.now()
  where id = p_case_id returning * into v_case;
  if v_case.id is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_reply <> '' or p_status = 'closed' then
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (v_case.requester_id, 'support',
              case when p_status = 'closed' then 'Support-Ticket abgeschlossen' else 'Antwort vom Support' end,
              '„' || v_case.subject || '“: ' || coalesce(nullif(v_reply, ''), 'Dein Ticket wurde abgeschlossen.'));
    exception when others then null;
    end;
  end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.support_update_case(uuid, text, text, text) from public, anon;
grant execute on function public.support_update_case(uuid, text, text, text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013240000_site_tabs_account.sql =====================
-- Tabs "Konto" und "Support" (in Community) können auf der Chain-Seite ausgeschaltet werden (Home bleibt immer sichtbar).
create or replace function public.node_set_site_tabs(p_key text, p_disabled text[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tabs text[];
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select coalesce(array_agg(distinct t), '{}') into v_tabs
  from unnest(coalesce(p_disabled, '{}')) t
  where t in ('send', 'games', 'community', 'activity', 'chain', 'market', 'account', 'support');
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('site_tabs', pg_catalog.jsonb_build_object('disabled_tabs', pg_catalog.to_jsonb(v_tabs)), null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true, 'disabled_tabs', pg_catalog.to_jsonb(v_tabs));
end;
$$;
revoke all on function public.node_set_site_tabs(text, text[]) from public;
grant execute on function public.node_set_site_tabs(text, text[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013250000_support_unified.sql =====================
-- Ein gemeinsamer Support-Bereich: Tickets (support_cases) und gemeldete Transaktionen (abuse_reports).
-- Owner sehen und bearbeiten beides an einem Ort.

create or replace function public.support_list_all()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_support_owner();
  return coalesce((
    select pg_catalog.jsonb_agg(x.item order by (x.item ->> 'done')::boolean, x.updated_at desc)
    from (
      select c.updated_at, pg_catalog.jsonb_build_object(
        'kind', 'ticket', 'id', c.id, 'subject', c.subject, 'body', c.body, 'status', c.status, 'priority', c.priority,
        'created_at', c.created_at, 'updated_at', c.updated_at, 'done', c.status = 'closed',
        'requester', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer'),
        'assigned', coalesce(nullif(a.username, ''), a.display_name)
      ) as item
      from (select * from public.support_cases order by updated_at desc limit 200) c
      left join public.profiles p on p.id = c.requester_id
      left join public.profiles a on a.id = c.assigned_to
      union all
      select r.updated_at, pg_catalog.jsonb_build_object(
        'kind', 'report', 'id', r.id,
        'subject', 'Gemeldete Transaktion · ' || case r.category
          when 'suspicious_transfer' then 'Verdächtige Überweisung' when 'wrong_recipient' then 'Falscher Empfänger'
          when 'harassment' then 'Belästigung oder Druck' else 'Anderer Grund' end,
        'body', r.description, 'status', r.status, 'priority', 'normal',
        'created_at', r.created_at, 'updated_at', r.updated_at, 'done', r.status in ('resolved', 'dismissed'),
        'requester', coalesce(nullif(p.username, ''), p.display_name, 'Nutzer'),
        'transaction', case when t.id is null then 'Transaktion nicht mehr verfügbar'
          else t.sender_label || ' → ' || t.receiver_label || ' · ' || t.amount || ' GIBB' end,
        'note', r.resolution_note
      )
      from (select * from public.abuse_reports order by updated_at desc limit 200) r
      left join public.profiles p on p.id = r.reporter_user_id
      left join public.transactions t on t.id = r.transaction_id
    ) x
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.support_list_all() from public, anon;
grant execute on function public.support_list_all() to authenticated;

-- Gemeldete Transaktion bearbeiten (Owner)
create or replace function public.support_update_report(p_report_id uuid, p_status text, p_reply text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_support_owner();
  v_reporter uuid;
  v_reply text := nullif(pg_catalog.left(pg_catalog.btrim(coalesce(p_reply, '')), 500), '');
begin
  if p_status not in ('open', 'reviewing', 'resolved', 'dismissed') then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_request'); end if;
  update public.abuse_reports set status = p_status, resolution_note = coalesce(v_reply, resolution_note), reviewed_by = v_me, updated_at = pg_catalog.now()
  where id = p_report_id returning reporter_user_id into v_reporter;
  if v_reporter is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  begin
    insert into public.notifications (user_id, kind, title, message)
    values (v_reporter, 'report_status', 'Meldung aktualisiert',
      coalesce(v_reply, case p_status when 'reviewing' then 'Deine Meldung wird jetzt geprüft.' when 'resolved' then 'Deine Meldung wurde geprüft und abgeschlossen.' when 'dismissed' then 'Deine Meldung wurde geprüft und geschlossen.' else 'Deine Meldung ist wieder offen.' end));
  exception when others then null;
  end;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.support_update_report(uuid, text, text) from public, anon;
grant execute on function public.support_update_report(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013260000_owner_created_accounts.sql =====================
-- Keine Selbst-Registrierung mehr: Neue Konten legt nur Ilja auf der Chain-Seite an.
-- * Ein Konto über die Supabase-Anmeldung (signup) entsteht nur, wenn die Chain-Seite die E-Mail
--   vorher freigegeben hat (10 Minuten gültig). Alle anderen Registrierungen werden abgelehnt.
-- * Direkte Einträge im SQL Editor / durch Migrationen bleiben möglich.

create table if not exists private.signup_allowlist (
  email text primary key,
  username text,
  expires_at timestamptz not null
);
revoke all on table private.signup_allowlist from public, anon, authenticated;

create or replace function private.block_public_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Nur Registrierungen über die Supabase-Anmeldung (Rolle supabase_auth_admin) prüfen
  if current_user::text <> 'supabase_auth_admin' and session_user::text <> 'supabase_auth_admin' then
    return new;
  end if;
  if exists (
    select 1 from private.signup_allowlist a
    where a.email = pg_catalog.lower(coalesce(new.email, '')) and a.expires_at > pg_catalog.now()
  ) then
    delete from private.signup_allowlist where email = pg_catalog.lower(coalesce(new.email, ''));
    return new;
  end if;
  raise exception using errcode = '42501', message = 'signup_disabled';
end;
$$;
revoke all on function private.block_public_signup() from public, anon, authenticated;
drop trigger if exists block_public_signup on auth.users;
create trigger block_public_signup before insert on auth.users
  for each row execute function private.block_public_signup();

-- Chain-Seite: E-Mail für ein neues Konto freigeben (danach legt die Chain-Seite das Konto an)
create or replace function public.node_allow_signup(p_key text, p_email text, p_username text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_email, '')));
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_email'); end if;
  if v_username !~ '^[a-z0-9._-]{3,30}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_username'); end if;
  if exists (select 1 from auth.users u where pg_catalog.lower(u.email) = v_email) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'email_taken');
  end if;
  if exists (select 1 from public.profiles p where pg_catalog.lower(p.username) = v_username) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;
  delete from private.signup_allowlist where expires_at < pg_catalog.now();
  insert into private.signup_allowlist (email, username, expires_at)
  values (v_email, v_username, pg_catalog.now() + interval '10 minutes')
  on conflict (email) do update set username = excluded.username, expires_at = excluded.expires_at;
  return pg_catalog.jsonb_build_object('ok', true, 'email', v_email, 'username', v_username);
end;
$$;
revoke all on function public.node_allow_signup(text, text, text) from public;
grant execute on function public.node_allow_signup(text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013270000_card_payment_switch.sql =====================
-- Zahlarten im Kaufen-Tab einzeln auf der Chain-Seite ein-/ausschalten:
-- Karte/TWINT (Stripe, standardmässig AUS), mit Credits kaufen (standardmässig AN), Banküberweisung (bank_enabled).
alter table private.market_settings add column if not exists card_enabled boolean not null default false;
alter table private.market_settings add column if not exists credits_enabled boolean not null default true;

create or replace function public.get_bank_details()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'enabled', s.bank_enabled and pg_catalog.btrim(s.bank_iban) <> '',
    'iban', s.bank_iban, 'holder', s.bank_holder,
    'card_enabled', s.card_enabled, 'credits_enabled', s.credits_enabled
  )
  from private.market_settings s where s.singleton;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

create or replace function public.node_set_payment_methods(p_key text, p_card boolean, p_credits boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  update private.market_settings
  set card_enabled = coalesce(p_card, false), credits_enabled = coalesce(p_credits, true), updated_at = pg_catalog.now()
  where singleton;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_payment_methods(text, boolean, boolean) from public;
grant execute on function public.node_set_payment_methods(text, boolean, boolean) to anon, authenticated, service_role;

-- Mit Credits kaufen nur, wenn eingeschaltet
create or replace function public.market_buy_with_credits(p_gibb bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := private.require_active_user();
  v_quote jsonb;
  v_rappen bigint;
  v_wallet public.wallets%rowtype;
  v_after numeric;
begin
  if not coalesce((select s.credits_enabled from private.market_settings s where s.singleton), true) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'credits_disabled');
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_market'));
  v_quote := public.market_quote(p_gibb);
  if not (v_quote ->> 'ok')::boolean then return v_quote; end if;
  if not (v_quote ->> 'market_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'market_disabled'); end if;
  if not (v_quote ->> 'buy_enabled')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'buy_disabled'); end if;
  if not (v_quote ->> 'buy_possible')::boolean then return pg_catalog.jsonb_build_object('ok', false, 'error', 'price_limit'); end if;
  v_rappen := (v_quote ->> 'buy_rappen')::bigint;

  select * into v_wallet from public.wallets where user_id = v_me for update;
  if v_wallet.credits < v_rappen then return pg_catalog.jsonb_build_object('ok', false, 'error', 'insufficient_credits', 'needed', v_rappen); end if;

  update public.wallets set balance = balance + p_gibb, credits = credits - v_rappen, updated_at = pg_catalog.now() where user_id = v_me;
  perform private.append_transaction(null, v_me, p_gibb, 'MARKET_BUY', 'GIBB-Markt · Kauf für ' || v_rappen || ' Rp Credits');
  v_after := private.market_apply('buy_credits', v_me, p_gibb, v_rappen, null);
  return pg_catalog.jsonb_build_object('ok', true, 'gibb', p_gibb, 'rappen', v_rappen, 'price', v_after);
end;
$$;
revoke all on function public.market_buy_with_credits(bigint) from public, anon;
grant execute on function public.market_buy_with_credits(bigint) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013280000_node_list_users_primary.sql =====================
-- node_list_users markiert den Haupt-Owner (Ilja), damit die Chain-Seite ihn immer als "Full" zeigt.
create or replace function public.node_list_users(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key');
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'users', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', p.id, 'username', p.username, 'display_name', p.display_name, 'role', p.role,
      'balance', coalesce(w.balance, 0), 'status', coalesce(w.status, 'active'),
      'is_primary', private.is_ilja(p.id)
    ) order by pg_catalog.lower(coalesce(nullif(p.username, ''), p.display_name, '')))
    from public.profiles p left join public.wallets w on w.user_id = p.id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_users(text) from public;
grant execute on function public.node_list_users(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013290000_qr_bill_address.sql =====================
-- QR-Rechnung für den Kauf per Überweisung: Adresse der Empfängerin/des Empfängers (PLZ und Ort sind Pflicht).
alter table private.market_settings add column if not exists bank_street text not null default '';
alter table private.market_settings add column if not exists bank_zip text not null default '';
alter table private.market_settings add column if not exists bank_city text not null default '';

create or replace function public.get_bank_details()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'enabled', s.bank_enabled and pg_catalog.btrim(s.bank_iban) <> '',
    'iban', s.bank_iban, 'holder', s.bank_holder,
    'street', s.bank_street, 'zip', s.bank_zip, 'city', s.bank_city,
    'card_enabled', s.card_enabled, 'credits_enabled', s.credits_enabled
  )
  from private.market_settings s where s.singleton;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

create or replace function public.node_set_bank_address(p_key text, p_street text, p_zip text, p_city text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_zip text := pg_catalog.btrim(coalesce(p_zip, ''));
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_zip <> '' and v_zip !~ '^[0-9]{4}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_zip'); end if;
  update private.market_settings set
    bank_street = pg_catalog.left(pg_catalog.btrim(coalesce(p_street, '')), 70),
    bank_zip = v_zip,
    bank_city = pg_catalog.left(pg_catalog.btrim(coalesce(p_city, '')), 35),
    updated_at = pg_catalog.now()
  where singleton;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_bank_address(text, text, text, text) from public;
grant execute on function public.node_set_bank_address(text, text, text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261013300000_support_fix_full_owners.sql =====================
-- 1) Neue Support-Tickets: Absender automatisch setzen (fehlte -> "Das hat nicht geklappt").
alter table public.support_cases alter column requester_id set default auth.uid();

-- 2) "Support bearbeiten" nur für Full-Owner (Ilja + auf der Chain-Seite zu Full hochgestufte Owner).
--    Die Chain-Seite überträgt die Liste der Full-Owner mit ihrem Schlüssel.
create or replace function public.node_set_owner_levels(p_key text, p_full uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  insert into private.admin_control_settings (key, value, updated_by, updated_at)
  values ('owner_levels', pg_catalog.jsonb_build_object('full', pg_catalog.to_jsonb(coalesce(p_full, '{}'::uuid[]))), null, pg_catalog.clock_timestamp())
  on conflict (key) do update set value = excluded.value, updated_by = null, updated_at = excluded.updated_at;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.node_set_owner_levels(text, uuid[]) from public;
grant execute on function public.node_set_owner_levels(text, uuid[]) to anon, authenticated, service_role;

create or replace function private.is_full_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
    and exists (select 1 from public.profiles p where p.id = p_user_id and p.role = 'super_admin')
    and (
      private.is_ilja(p_user_id)
      or coalesce((select s.value -> 'full' from private.admin_control_settings s where s.key = 'owner_levels'), '[]'::jsonb) ? p_user_id::text
    );
$$;
revoke all on function private.is_full_owner(uuid) from public, anon, authenticated;

create or replace function private.require_support_owner()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if not private.is_full_owner(v_user_id)
     or not exists (select 1 from public.wallets w where w.user_id = v_user_id and w.status = 'active') then
    raise exception 'owner_required';
  end if;
  return v_user_id;
end;
$$;
revoke all on function private.require_support_owner() from public, anon, authenticated;

-- Für die Hauptseite: darf dieses Konto Support bearbeiten?
create or replace function public.get_support_access()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select private.is_full_owner(auth.uid()); $$;
revoke all on function public.get_support_access() from public, anon;
grant execute on function public.get_support_access() to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261013310000_verified_qr_buyers.sql =====================
-- QR-Rechnung nur für verifizierte Käufer: Ilja schaltet Konten auf der Chain-Seite frei.
-- Nicht verifizierte Konten bekommen die Adresse (PLZ/Ort/Strasse) gar nicht erst – sie können weiterhin
-- von Hand mit IBAN und Code überweisen.

create table if not exists private.verified_buyers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  verified_at timestamptz not null default now()
);
revoke all on table private.verified_buyers from public, anon, authenticated;

create or replace function public.get_bank_details()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s private.market_settings%rowtype;
  v_verified boolean := exists (select 1 from private.verified_buyers v where v.user_id = auth.uid());
  v_qr boolean;
begin
  select * into v_s from private.market_settings where singleton;
  v_qr := v_verified and v_s.bank_zip <> '' and v_s.bank_city <> '' and pg_catalog.btrim(v_s.bank_holder) <> '';
  return pg_catalog.jsonb_build_object(
    'enabled', v_s.bank_enabled and pg_catalog.btrim(v_s.bank_iban) <> '',
    'iban', v_s.bank_iban, 'holder', v_s.bank_holder,
    'verified', v_verified,
    'qr_allowed', v_qr,
    'street', case when v_qr then v_s.bank_street end,
    'zip', case when v_qr then v_s.bank_zip end,
    'city', case when v_qr then v_s.bank_city end,
    'card_enabled', v_s.card_enabled, 'credits_enabled', v_s.credits_enabled
  );
end;
$$;
revoke all on function public.get_bank_details() from public, anon;
grant execute on function public.get_bank_details() to authenticated;

create or replace function public.node_set_buyer_verified(p_key text, p_user uuid, p_verified boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_user is null or not exists (select 1 from auth.users u where u.id = p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if coalesce(p_verified, false) then
    insert into private.verified_buyers (user_id) values (p_user) on conflict (user_id) do nothing;
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (p_user, 'account', 'Konto verifiziert', 'Du kannst jetzt per QR-Rechnung GIBB kaufen.');
    exception when others then null;
    end;
  else
    delete from private.verified_buyers where user_id = p_user;
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'verified', coalesce(p_verified, false));
end;
$$;
revoke all on function public.node_set_buyer_verified(text, uuid, boolean) from public;
grant execute on function public.node_set_buyer_verified(text, uuid, boolean) to anon, authenticated, service_role;

create or replace function public.node_list_verified_buyers(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'ids', coalesce((select pg_catalog.jsonb_agg(v.user_id) from private.verified_buyers v), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_verified_buyers(text) from public;
grant execute on function public.node_list_verified_buyers(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261014090000_delete_closed_bank_orders.sql =====================
-- Abgelehnte und stornierte Banküberweisungen löschen (bezahlte bleiben als Nachweis).
-- * Chain-Seite: einzeln oder alle auf einmal (mit dem Chain-Schlüssel).
-- * Hauptseite: die eigene abgelehnte/stornierte Bestellung aus der Liste entfernen.

create or replace function public.node_delete_bank_orders(p_key text, p_id uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  delete from public.bank_orders
  where status in ('rejected', 'cancelled') and (p_id is null or id = p_id);
  get diagnostics v_count = row_count;
  if p_id is not null and v_count = 0 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_deletable'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'deleted', v_count);
end;
$$;
revoke all on function public.node_delete_bank_orders(text, uuid) from public;
grant execute on function public.node_delete_bank_orders(text, uuid) to anon, authenticated, service_role;

create or replace function public.delete_my_bank_order(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'authentication_required'; end if;
  delete from public.bank_orders where id = p_id and user_id = v_me and status in ('rejected', 'cancelled');
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_deletable'); end if;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.delete_my_bank_order(uuid) from public, anon;
grant execute on function public.delete_my_bank_order(uuid) to authenticated;

notify pgrst, 'reload schema';


-- ===================== 20261014120000_delete_any_bank_order.sql =====================
-- Chain-Seite: jede einzelne Banküberweisung löschbar (auch bezahlte/offene).
-- Ohne ID ("alle löschen") werden weiterhin nur abgelehnte/stornierte entfernt.
create or replace function public.node_delete_bank_orders(p_key text, p_id uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_id is not null then
    delete from public.bank_orders where id = p_id;
  else
    delete from public.bank_orders where status in ('rejected', 'cancelled');
  end if;
  get diagnostics v_count = row_count;
  if p_id is not null and v_count = 0 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_deletable'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'deleted', v_count);
end;
$$;
revoke all on function public.node_delete_bank_orders(text, uuid) from public;
grant execute on function public.node_delete_bank_orders(text, uuid) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261015090000_owner_stats_bulk_announcement.sql =====================
-- Chain-Seite (mit dem Schlüssel aus "sudo gibb-chain-key"):
-- * node_owner_stats: Kennzahlen und Tagesverläufe (neue Konten, aktive Konten, Umlauf, Einnahmen)
-- * node_bulk_adjust: allen aktiven Konten auf einmal GIBB gutschreiben (z. B. Weihnachtsbonus)
-- * node_get_announcement / node_set_announcement: Banner auf der Hauptseite

create or replace function public.node_owner_stats(p_key text, p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_from date := (pg_catalog.now() at time zone 'Europe/Zurich')::date - (v_days - 1);
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'days', v_days,
    'totals', pg_catalog.jsonb_build_object(
      'users', (select pg_catalog.count(*) from public.wallets),
      'circulation', (select coalesce(pg_catalog.sum(balance), 0) from public.wallets),
      'active_7d', (select pg_catalog.count(distinct t.sender_user_id) from public.transactions t where t.sender_user_id is not null and t.created_at > pg_catalog.now() - interval '7 days'),
      'tx_24h', (select pg_catalog.count(*) from public.transactions t where t.created_at > pg_catalog.now() - interval '24 hours'),
      'revenue_rappen', (select coalesce(pg_catalog.sum(rappen), 0) from public.bank_orders where status = 'paid'),
      'revenue_gibb', (select coalesce(pg_catalog.sum(gibb), 0) from public.bank_orders where status = 'paid'),
      'bank_pending', (select pg_catalog.count(*) from public.bank_orders where status = 'pending')
    ),
    'series', (
      select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'day', d.day,
        'new_users', (select pg_catalog.count(*) from public.wallets w where (w.created_at at time zone 'Europe/Zurich')::date = d.day),
        'active', (select pg_catalog.count(distinct t.sender_user_id) from public.transactions t where t.sender_user_id is not null and (t.created_at at time zone 'Europe/Zurich')::date = d.day),
        'tx', (select pg_catalog.count(*) from public.transactions t where (t.created_at at time zone 'Europe/Zurich')::date = d.day),
        'revenue_rappen', (select coalesce(pg_catalog.sum(b.rappen), 0) from public.bank_orders b where b.status = 'paid' and (coalesce(b.decided_at, b.created_at) at time zone 'Europe/Zurich')::date = d.day)
      ) order by d.day), '[]'::jsonb)
      from (select pg_catalog.generate_series(v_from, v_from + (v_days - 1), interval '1 day')::date as day) d
    )
  );
end;
$$;
revoke all on function public.node_owner_stats(text, integer) from public;
grant execute on function public.node_owner_stats(text, integer) to anon, authenticated, service_role;

create or replace function public.node_bulk_adjust(p_key text, p_amount bigint, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_reason text := pg_catalog.left(pg_catalog.btrim(coalesce(p_reason, '')), 120);
  v_wallet record;
  v_count integer := 0;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_amount'); end if;
  if pg_catalog.char_length(v_reason) < 3 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'reason_required'); end if;

  perform pg_advisory_xact_lock(pg_catalog.hashtext('gibb_coin_transfer_chain'));
  for v_wallet in
    select w.id, w.user_id from public.wallets w
    where coalesce(w.status, 'active') <> 'locked' and (w.locked_until is null or w.locked_until < pg_catalog.now())
    order by w.created_at
    for update
  loop
    update public.wallets set balance = balance + p_amount, updated_at = pg_catalog.now() where id = v_wallet.id;
    perform private.append_transaction(null, v_wallet.user_id, p_amount, 'ADMIN_MINT', 'Bonus für alle · ' || v_reason);
    begin
      insert into public.notifications (user_id, kind, title, message)
      values (v_wallet.user_id, 'admin_adjustment', 'Bonus erhalten', p_amount || ' GIBB für alle: ' || v_reason);
    exception when others then null; -- Mitteilung ist optional
    end;
    v_count := v_count + 1;
  end loop;
  return pg_catalog.jsonb_build_object('ok', true, 'users', v_count, 'total', v_count * p_amount);
end;
$$;
revoke all on function public.node_bulk_adjust(text, bigint, text) from public;
grant execute on function public.node_bulk_adjust(text, bigint, text) to anon, authenticated, service_role;

create or replace function public.node_get_announcement(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'announcement', coalesce(
    (select value from private.admin_control_settings where key = 'announcement'),
    '{"enabled":false,"title":"","message":"","until":null}'::jsonb));
end;
$$;
revoke all on function public.node_get_announcement(text) from public;
grant execute on function public.node_get_announcement(text) to anon, authenticated, service_role;

create or replace function public.node_set_announcement(p_key text, p_enabled boolean, p_title text, p_message text, p_until timestamptz default null, p_tone text default 'info')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_value jsonb;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if coalesce(p_enabled, false) and pg_catalog.char_length(pg_catalog.btrim(coalesce(p_message, ''))) < 2 then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'message_required');
  end if;
  v_value := pg_catalog.jsonb_build_object(
    'enabled', coalesce(p_enabled, false),
    'title', pg_catalog.left(pg_catalog.btrim(coalesce(p_title, '')), 80),
    'message', pg_catalog.left(pg_catalog.btrim(coalesce(p_message, '')), 400),
    'until', p_until,
    'tone', case when p_tone in ('info', 'success', 'warning') then p_tone else 'info' end
  );
  insert into private.admin_control_settings (key, value) values ('announcement', v_value)
  on conflict (key) do update set value = excluded.value, updated_at = pg_catalog.now(), updated_by = null;
  return pg_catalog.jsonb_build_object('ok', true, 'announcement', v_value);
end;
$$;
revoke all on function public.node_set_announcement(text, boolean, text, text, timestamptz, text) from public;
grant execute on function public.node_set_announcement(text, boolean, text, text, timestamptz, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';


-- ===================== 20261015120000_public_profile_badges.sql =====================
-- Öffentliche Profile: Zähler für Abzeichen und Statistik (nur Summen, keine Details).
-- Gesendet/Empfangen, gespielte Runden, gemintete Blöcke, Handel am Markt und Mitgliedsnummer.
create or replace function public.get_public_profile_extras(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_joined timestamptz;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  select w.created_at into v_joined from public.wallets w where w.user_id = p_user_id;
  if v_joined is null then return pg_catalog.jsonb_build_object('ok', false, 'error', 'profile_not_found'); end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'member_no', (select pg_catalog.count(*) from public.wallets w where w.created_at <= v_joined),
    'members', (select pg_catalog.count(*) from public.wallets),
    'sent', (select pg_catalog.count(*) from public.transactions t where t.sender_user_id = p_user_id and coalesce(t.type, '') not in ('GAME_ENTRY', 'MARKET_SELL')),
    'received', (select pg_catalog.count(*) from public.transactions t where t.receiver_user_id = p_user_id and t.sender_user_id is not null),
    'games', (select pg_catalog.count(*) from public.transactions t where t.sender_user_id = p_user_id and t.type = 'GAME_ENTRY'),
    'game_wins', (select pg_catalog.count(*) from public.transactions t where t.receiver_user_id = p_user_id and t.type = 'GAME_REWARD'),
    'blocks', (select pg_catalog.count(*) from public.transactions t where t.receiver_user_id = p_user_id and t.type = 'MINING_REWARD'),
    'trades', (select pg_catalog.count(*) from public.market_events e where e.user_id = p_user_id)
  );
end;
$$;
revoke all on function public.get_public_profile_extras(uuid) from public, anon;
grant execute on function public.get_public_profile_extras(uuid) to authenticated;

notify pgrst, 'reload schema';

