-- Drop the dead fund RPCs. They are the last thing in the database that can
-- silently break the ledger invariant.
--
-- WHY
-- ---
-- 1. Nothing calls them. No frontend import, no trigger, no other function
--    (verified via pg_depend: zero dependents).
--
-- 2. Every one of them bypasses bank_accounts. They move users.current_balance
--    without touching bank_accounts.ledger_balance, so calling any of them
--    breaks the invariant that every surviving money RPC asserts:
--        users.current_balance == sum(active bank_accounts.ledger_balance)
--    The next reconciliation would then read that divergence as bank drift and
--    write a bogus `reconciliation` row to "correct" a number that was never
--    wrong.
--
-- 3. The p_balance variants are worse: they overwrite
--        current_balance = (p_balance - savings_balance)
--    from a bank figure, which is the same vault-destroying shape as
--    sync_bank_to_app. Two of the five surviving definitions did that.
--
-- 4. They carried 5 definitions across 2 names, so PostgREST had to guess on
--    argument matching. That is how the stale overloads in 20261004100500
--    happened in the first place.
--
-- THE SANCTIONED REPLACEMENTS
--   add money    -> add_bank_account(label, opening_balance, bank_name) on the
--                   first account; add_bank_account(...) again for more.
--   correct money-> reconcile_bank_account(account_id, reported_balance)
--                   writes a visible drift row.
--   spend money  -> log_expense / move_to_vault / withdraw_from_vault, all of
--                   which maintain both ledgers.

drop function if exists public.add_funds(uuid, numeric, text, timestamptz);
drop function if exists public.add_funds(uuid, numeric, text, timestamptz, numeric);

drop function if exists public.subtract_funds(uuid, numeric, text, uuid);
drop function if exists public.subtract_funds(uuid, numeric, text, text, timestamptz);
drop function if exists public.subtract_funds(uuid, numeric, text, timestamptz, numeric);

do $$
declare v_left int;
begin
  select count(*) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('add_funds', 'subtract_funds');
  if v_left <> 0 then
    raise exception 'overloads survived the drop: %', v_left;
  end if;
end $$;