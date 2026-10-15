-- Drop the superseded log_expense / sync_bank_to_app overloads.
--
-- CREATE OR REPLACE only replaces a function when the argument list matches
-- exactly. Adding p_account_id therefore did not replace the old signature --
-- it created a second, same-named function alongside it:
--
--   log_expense(uuid, numeric, text, uuid, uuid)          <- stale
--   log_expense(uuid, numeric, text, uuid, uuid, uuid)    <- current
--   sync_bank_to_app(uuid, numeric, numeric, text)         <- stale
--   sync_bank_to_app(uuid, numeric, numeric, text, uuid)   <- current
--
-- Symptom: the browser kept using the stale 5-arg log_expense, so logging an
-- expense moved users.current_balance but left bank_accounts.ledger_balance
-- alone and the account panel disagreed with the dashboard again. The SQL
-- harness passed because it called the 6-arg overload positionally, which is
-- unambiguous -- only the PostgREST path resolved to the wrong one.
--
-- Dropping the stale copies leaves exactly one function per name. Callers that
-- omit p_account_id still work: it has a DEFAULT, so both positional and
-- named-argument calls resolve against the single remaining signature.

drop function if exists public.log_expense(uuid, numeric, text, uuid, uuid);
drop function if exists public.sync_bank_to_app(uuid, numeric, numeric, text);

-- Re-assert the grants against the surviving signatures, since dropping the
-- overloads does not carry privileges across.
revoke execute on function public.log_expense(uuid, numeric, text, uuid, uuid, uuid) from public, anon;
revoke execute on function public.sync_bank_to_app(uuid, numeric, numeric, text, uuid) from public, anon;
grant  execute on function public.log_expense(uuid, numeric, text, uuid, uuid, uuid) to authenticated;
grant  execute on function public.sync_bank_to_app(uuid, numeric, numeric, text, uuid) to authenticated;