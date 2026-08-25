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
- Every push to `main` must pass the GitHub Actions production workflow. Once the Cloudflare repository secrets are configured, that workflow publishes the exact tested commit automatically.
- The existing OpenAI Sites deployment remains available as a fallback. Do not remove or replace `.openai/hosting.json`.
