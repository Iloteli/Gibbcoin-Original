-- Profil der Hauptseite (Anzeigename, Benutzername, Über mich, Farbe, Bild) auch auf der Chain-Seite bearbeiten.
-- Die Chain-Seite ruft das mit ihrem Schlüssel auf – und nur für das eigene, angemeldete Konto.
create or replace function public.node_get_profile(p_key text, p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row public.profiles%rowtype;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  select * into v_row from public.profiles where id = p_user;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'profile', pg_catalog.jsonb_build_object(
    'username', v_row.username, 'display_name', v_row.display_name, 'bio', v_row.bio,
    'profile_color', v_row.profile_color, 'avatar_url', v_row.avatar_url));
end;
$$;
revoke all on function public.node_get_profile(text, uuid) from public;
grant execute on function public.node_get_profile(text, uuid) to anon, authenticated, service_role;

-- Gleiche Regeln wie update_my_profile_atomic. Das Bild kann hier nur behalten oder entfernt werden.
create or replace function public.node_update_profile(p_key text, p_user uuid, p_username text, p_display_name text, p_bio text, p_profile_color text, p_remove_avatar boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_username text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
  v_name text := pg_catalog.btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(pg_catalog.btrim(coalesce(p_bio, '')), '');
  v_color text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_profile_color, '')));
  v_row public.profiles%rowtype;
begin
  if not private.node_key_ok(p_key) then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_key'); end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_username'); end if;
  if pg_catalog.char_length(v_name) not between 2 and 60 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_display_name'); end if;
  if v_bio is not null and pg_catalog.char_length(v_bio) > 180 then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_bio'); end if;
  if v_color !~ '^#[0-9a-f]{6}$' then return pg_catalog.jsonb_build_object('ok', false, 'error', 'invalid_profile_color'); end if;
  if exists (select 1 from public.profiles where pg_catalog.lower(username) = v_username and id <> p_user) then
    return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
  end if;
  update public.profiles
  set username = v_username, display_name = v_name, bio = v_bio, profile_color = v_color,
      avatar_url = case when coalesce(p_remove_avatar, false) then null else avatar_url end
  where id = p_user
  returning * into v_row;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return pg_catalog.jsonb_build_object('ok', true, 'profile', pg_catalog.jsonb_build_object(
    'username', v_row.username, 'display_name', v_row.display_name, 'bio', v_row.bio,
    'profile_color', v_row.profile_color, 'avatar_url', v_row.avatar_url));
exception when unique_violation then
  return pg_catalog.jsonb_build_object('ok', false, 'error', 'username_taken');
end;
$$;
revoke all on function public.node_update_profile(text, uuid, text, text, text, text, boolean) from public;
grant execute on function public.node_update_profile(text, uuid, text, text, text, text, boolean) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
