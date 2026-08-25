-- The immutable transaction ledger references private.ledger_identities.
-- Capture the identity before any AFTER INSERT signup trigger can create the
-- initial-balance transaction. Using a BEFORE trigger avoids depending on the
-- alphabetical order of multiple auth.users triggers.

drop trigger if exists on_auth_user_ledger_identity on auth.users;

create trigger on_auth_user_ledger_identity
  before insert on auth.users
  for each row execute procedure private.capture_ledger_identity();
