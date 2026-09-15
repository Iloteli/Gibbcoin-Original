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
