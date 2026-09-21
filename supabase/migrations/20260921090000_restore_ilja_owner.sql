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
