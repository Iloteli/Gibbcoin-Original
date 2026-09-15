# Gemini review guidance

GIBB Coin is a school wallet. Review changes for:

- server-authoritative balances and transactional coin movements;
- Supabase RLS, SECURITY DEFINER functions, and authorization checks;
- accidental exposure of service-role keys, passwords, or personal data;
- regressions in authentication, MFA, account deletion, bans, transfers, games, and payments;
- TypeScript safety, accessibility, and the existing German user experience.

Do not recommend client-side balance mutations or bypassing the production migration safeguards.
