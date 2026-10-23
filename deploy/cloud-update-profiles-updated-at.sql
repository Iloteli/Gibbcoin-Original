-- profiles.updated_at gab es im alten Supabase-Projekt (aus einer frühen, nicht mehr vorhandenen Migration).
-- Im neuen Projekt fehlte die Spalte -> Profil speichern, Benutzername ändern und Ausrüsten schlugen fehl.
alter table public.profiles add column if not exists updated_at timestamptz not null default pg_catalog.now();

notify pgrst, 'reload schema';
