-- Ilja wird zur höchsten Rolle befördert: super_admin (Owner)
-- Mit dieser Rolle kann Ilja:
-- - Konten bannen/entbannen
-- - Konten dauerhaft löschen
-- - Admin-Rechte vergeben/entfernen
-- - Coins aus der Admin-Reserve gutschreiben/enziehen

update public.profiles
set role = 'super_admin'
where id in (
  select u.id
  from auth.users u
  where pg_catalog.lower(u.email) = 'ilja.podorieszach@icloud.com'
);

notify pgrst, 'reload schema';
