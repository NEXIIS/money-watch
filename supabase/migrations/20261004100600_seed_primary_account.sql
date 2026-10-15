-- Seed one real bank account for the existing user, so Make can
-- reconcile to it without ever sending a hardcoded p_user_id.
--
-- Vault (savings_balance) is deliberately NOT seeded from a bank account.
-- See 20261004100300 for the invariant: users.current_balance == sum(ledger_balance).

-- Your single real account, derived from your actual tracked total.
insert into public.bank_accounts
  (user_id, label, bank_name, opening_balance, ledger_balance)
values
  ('ffd354a7-08cd-4d09-8c4b-1318afa38970'::uuid,
   'Primary', 'FirstBank', 29000, 29000)
on conflict (user_id, label) do nothing;

-- Knows: the user who authorised the Make Gmail trigger.
-- This lets a single Gmail scenario serve every user (multiplex by To/Delimiter).
-- Your friends keep their own Gmail connections; the scenario just fans out
-- by 'label' per connection.

-- Keep the legacy column consistent so no old UI reads a stale 50,000.
update public.users
   set bank_balance = 29000
 where id = 'ffd354a7-08cd-4d09-8c4b-1318afa38970'::uuid;

do $$ begin
  raise notice 'migration %: seeded Primary(29000) for %',
    '20261004100600', 'ffd354a7-08cd-4d09-8c4b-1318afa38970';
end $$;
