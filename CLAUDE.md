# GIBB Coin development guide

This repository contains the complete source for the GIBB Coin school wallet.

## Safe workflow

- Preserve every existing feature and file unless the repository owner explicitly asks for its removal.
- Create a branch for changes, keep commits focused, and open a pull request for review.
- Run `pnpm test` before pushing a finished change. It builds the production app and runs the regression tests.
- Never commit `.env` files, Supabase secret or service-role keys, passwords, access tokens, or temporary deployment credentials.
- Keep `.openai/hosting.json` and all Supabase migration files intact.

## Database changes

- Put every schema or database-function change in a new timestamped file under `supabase/migrations`.
- Keep wallet balances and coin movements server-authoritative and transactional.
- Enable and verify Row Level Security for exposed data.
- Test registration, transfers, game charges, rewards, and account deletion with rollback-safe checks.

## Publishing

- A GitHub push must pass the repository's verification workflow.
- The public production site is hosted with OpenAI Sites. After a reviewed GitHub change, publish the exact tested commit through the Sites deployment workflow so the live site and repository stay on the same version.
