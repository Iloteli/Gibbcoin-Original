alter table public.admin_audit_logs
  drop constraint if exists admin_audit_logs_action_check;

alter table public.admin_audit_logs
  add constraint admin_audit_logs_action_check check (
    action in (
      'ADMIN_MINT',
      'ADMIN_BURN',
      'BALANCE_SET',
      'ROLE_CHANGED',
      'WALLET_LOCKED',
      'WALLET_UNLOCKED',
      'ACCOUNT_LOCKED',
      'ACCOUNT_UNLOCKED'
    )
  );
