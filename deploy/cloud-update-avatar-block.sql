-- Profilbild für einzelne Benutzer sperren (eingestellt auf der Chain-Seite).
-- Gesperrt = das Profilbild wird entfernt und ein neues wird nicht gespeichert.
create table if not exists private.avatar_blocks (
  user_id uuid primary key,
  created_at timestamptz not null default pg_catalog.now()
);
revoke all on table private.avatar_blocks from public, anon, authenticated;

create or replace function private.enforce_avatar_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.avatar_url is not null and exists (select 1 from private.avatar_blocks b where b.user_id = new.id) then
    new.avatar_url := null;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_avatar_block on public.profiles;
create trigger enforce_avatar_block
  before insert or update of avatar_url on public.profiles
  for each row execute function private.enforce_avatar_block();

create or replace function public.node_set_avatar_blocked(p_key text, p_user uuid, p_blocked boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if coalesce(p_blocked, false) then
    insert into private.avatar_blocks (user_id) values (p_user) on conflict (user_id) do nothing;
    update public.profiles set avatar_url = null where id = p_user and avatar_url is not null;
  else
    delete from private.avatar_blocks where user_id = p_user;
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'blocked', coalesce(p_blocked, false));
end;
$$;
revoke all on function public.node_set_avatar_blocked(text, uuid, boolean) from public;
grant execute on function public.node_set_avatar_blocked(text, uuid, boolean) to anon, authenticated, service_role;

-- Für die Hauptseite: darf ich ein Profilbild haben?
create or replace function public.get_my_avatar_blocked()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.avatar_blocks b where b.user_id = auth.uid());
$$;
revoke all on function public.get_my_avatar_blocked() from public, anon;
grant execute on function public.get_my_avatar_blocked() to authenticated;

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
      'is_primary', private.is_ilja(p.id),
      'avatar_url', p.avatar_url, 'profile_color', p.profile_color,
      'avatar_blocked', exists (select 1 from private.avatar_blocks b where b.user_id = p.id)
    ) order by pg_catalog.lower(coalesce(nullif(p.username, ''), p.display_name, '')))
    from public.profiles p left join public.wallets w on w.user_id = p.id
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.node_list_users(text) from public;
grant execute on function public.node_list_users(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
