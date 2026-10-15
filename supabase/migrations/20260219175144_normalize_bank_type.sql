-- Normalise the caller-supplied p_type in sync_bank_to_app.
--
-- 20260219175143 fixed the hardcoded 'credit'/'debit' literals, but
-- sync_bank_to_app takes p_type as a parameter and inserts it straight into
-- transactions.type:
--
--   VALUES (..., p_type, 'Bank Alert', ...)
--
-- The column is guarded by transactions_type_check, which permits only
-- deposit/withdrawal/transfer/vault_deposit/vault_withdrawal/vault_overdraft/
-- expense. A caller passing the natural words 'credit' or 'debit' — which is
-- what the function's own CASE branch anticipated — would raise 23514.
--
-- This maps the informal aliases onto the real vocabulary and rejects anything
-- unrecognised, so a bad ingest fails loudly instead of silently aborting the
-- transaction inside the caller's error handler.

CREATE OR REPLACE FUNCTION public.sync_bank_to_app(
  p_user_id uuid,
  p_parsed_amount numeric,
  p_cleared_balance numeric,
  p_type text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_current_vault NUMERIC;
  v_new_vault NUMERIC;
  v_overdraft_amount NUMERIC;
  v_type TEXT;
  v_is_debit BOOLEAN;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  -- Map aliases onto the vocabulary transactions_type_check accepts.
  v_type := lower(trim(coalesce(p_type, '')));
  v_type := CASE v_type
    WHEN 'debit'      THEN 'withdrawal'
    WHEN 'credit'     THEN 'deposit'
    WHEN 'income'     THEN 'deposit'
    WHEN 'expense'    THEN 'withdrawal'
    WHEN 'inflow'     THEN 'deposit'
    WHEN 'outflow'    THEN 'withdrawal'
    ELSE v_type
  END;

  IF v_type NOT IN ('deposit', 'withdrawal') THEN
    RAISE EXCEPTION 'Unsupported bank transaction type: %', coalesce(p_type, '(null)')
      USING ERRCODE = '22023';
  END IF;

  v_is_debit := (v_type = 'withdrawal');

  SELECT savings_balance INTO v_current_vault FROM public.users WHERE id = p_user_id;

  IF p_cleared_balance < v_current_vault THEN
    v_overdraft_amount := v_current_vault - p_cleared_balance;
    v_new_vault := p_cleared_balance;

    INSERT INTO public.transactions (user_id, amount, type, description, category, date)
    VALUES (p_user_id, v_overdraft_amount, 'vault_overdraft', 'Auto-Cover: Dipped into Vault savings', 'General', now());
  ELSE
    v_new_vault := v_current_vault;
  END IF;

  UPDATE public.users
  SET current_balance = p_cleared_balance,
      savings_balance = v_new_vault
  WHERE id = p_user_id;

  INSERT INTO public.transactions (user_id, amount, type, description, category, date)
  VALUES (
    p_user_id,
    CASE WHEN v_is_debit THEN -p_parsed_amount ELSE p_parsed_amount END,
    v_type,
    'Bank Alert',
    'General',
    now()
  );
END;
$function$;
