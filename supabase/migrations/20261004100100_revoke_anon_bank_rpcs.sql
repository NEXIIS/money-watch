-- Lock the bank_account RPCs down to authenticated users.
--
-- Supabase grants EXECUTE on new functions to PUBLIC by default, so the three
-- functions added in 20261004100000 were callable by `anon`. Every pre-existing
-- RPC in this schema has anon EXECUTE revoked (log_expense, move_to_vault,
-- edit_transaction, delete_transaction, create_notification, get_daily_total),
-- so this restores the house rule rather than inventing one.
--
-- The functions already guard internally on auth.uid(), and anon has NULL uid
-- so every call raises 'Not authorized'. This is defence in depth: a
-- SECURITY DEFINER function should not be reachable by an unauthenticated role
-- at all, so that a future edit to a guard cannot silently become an escalation.

revoke execute on function public.reconcile_bank_account(uuid, numeric, timestamptz) from public, anon;
revoke execute on function public.add_bank_account(text, numeric, text) from public, anon;
revoke execute on function public.remove_bank_account(uuid) from public, anon;

grant execute on function public.reconcile_bank_account(uuid, numeric, timestamptz) to authenticated;
grant execute on function public.add_bank_account(text, numeric, text) to authenticated;
grant execute on function public.remove_bank_account(uuid) to authenticated;