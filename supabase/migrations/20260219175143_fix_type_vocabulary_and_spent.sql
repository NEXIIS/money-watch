-- Correct two defects introduced by 20260219175142 and 20260219175140.
--
-- 1. Session spent counters were zeroed.
--    20260219175142 recomputed shopping_sessions.current_spent with
--      ... filter (where t.type = 'expense')
--    but every session-linked transaction in the live ledger has
--    type = 'withdrawal' (written by the bank-sync subtract_funds overload).
--    There are 0 'expense' rows carrying a session_id, so all 8 sessions were
--    reset to 0 and the ₦13,000 of real session spend was lost from the
--    counters. The transactions themselves were untouched, so the correct
--    values are recoverable from the ledger.
--
--    Correct rule: count real outflow ('expense' + 'withdrawal') and exclude
--    the internal vault_* transfers, which move money between the user's own
--    wallets and are not spending.
--
-- 2. Several functions write type literals the table rejects.
--    transactions_type_check permits exactly:
--      deposit, withdrawal, transfer,
--      vault_deposit, vault_withdrawal, vault_overdraft, expense
--    but 20260219175140/141 rewrote add_funds, handle_credit, handle_debit
--    and two subtract_funds overloads to write 'credit' / 'debit', which are
--    not in that list. Every call would have raised 23514 and been swallowed by
--    the functions' own EXCEPTION handlers, returning a generic error. The
--    pre-existing add_funds already had this bug; the rewrite propagated it.
--
--    Mapping applied:
--      'credit'  -> 'deposit'     (money in)
--      'debit'   -> 'withdrawal'  (money out)
--    The 'Income' / 'General' values are category literals, not type, and stay.

-- ---------------------------------------------------------------------------
-- 1. Rebuild the session counters from the ledger.
-- ---------------------------------------------------------------------------
UPDATE public.shopping_sessions s
   SET current_spent = COALESCE((
         SELECT sum(abs(t.amount))
           FROM public.transactions t
          WHERE t.session_id = s.id
            AND t.type IN ('expense', 'withdrawal')
       ), 0);

-- ---------------------------------------------------------------------------
-- 2. Replace the invalid type literals.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_funds(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_date timestamp with time zone
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_new_balance numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('status', 'error', 'message', 'Not authorized');
  END IF;

  IF p_amount <= 0 THEN
    RETURN json_build_object('status', 'error', 'message', 'Amount must be positive');
  END IF;

  INSERT INTO public.transactions (user_id, type, amount, description, category, date)
  VALUES (p_user_id, 'deposit', p_amount, p_description, 'Income', COALESCE(p_date, now()));

  UPDATE public.users
  SET current_balance = current_balance + p_amount
  WHERE id = p_user_id
  RETURNING current_balance INTO v_new_balance;

  RETURN json_build_object('status', 'success', 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('status', 'error', 'message', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.add_funds(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_date timestamp with time zone,
  p_balance numeric DEFAULT NULL::numeric
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_savings numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT savings_balance INTO v_savings FROM public.users WHERE id = p_user_id;
  IF v_savings IS NULL THEN v_savings := 0; END IF;

  INSERT INTO public.transactions (user_id, amount, type, description, date, category)
  VALUES (p_user_id, p_amount, 'deposit', p_description, COALESCE(p_date, now()), 'Income');

  UPDATE public.users
  SET
    bank_balance = p_balance,
    current_balance = (p_balance - v_savings)
  WHERE id = p_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_credit(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_date timestamp with time zone,
  p_balance numeric DEFAULT NULL::numeric
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_new_balance numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  IF p_amount <= 0 THEN
    RETURN json_build_object('success', false, 'error', 'Amount must be positive');
  END IF;

  INSERT INTO public.transactions (user_id, type, amount, description, category, date)
  VALUES (p_user_id, 'deposit', p_amount, p_description, 'Income', COALESCE(p_date, now()));

  UPDATE public.users
  SET current_balance = current_balance + p_amount
  WHERE id = p_user_id
  RETURNING current_balance INTO v_new_balance;

  RETURN json_build_object('success', true, 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_debit(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_date timestamp with time zone,
  p_balance numeric DEFAULT NULL::numeric
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_tx_id uuid;
  v_new_balance numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  IF p_amount <= 0 THEN
    RETURN json_build_object('success', false, 'error', 'Amount must be positive');
  END IF;

  INSERT INTO public.transactions (user_id, type, amount, description, category, date)
  VALUES (p_user_id, 'withdrawal', -p_amount, p_description, 'General', COALESCE(p_date, now()))
  RETURNING id INTO v_tx_id;

  UPDATE public.users
  SET current_balance = current_balance - p_amount
  WHERE id = p_user_id
  RETURNING current_balance INTO v_new_balance;

  RETURN json_build_object('success', true, 'transaction_id', v_tx_id, 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.subtract_funds(
  p_user_id uuid,
  p_amount numeric,
  p_category text,
  p_description text,
  p_date timestamp with time zone
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_balance numeric;
  v_tx_id uuid;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  IF p_amount <= 0 THEN
    RETURN json_build_object('success', false, 'error', 'Amount must be positive');
  END IF;

  SELECT current_balance INTO v_balance FROM public.users WHERE id = p_user_id FOR UPDATE;

  IF v_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'User not found');
  END IF;

  UPDATE public.users
  SET current_balance = current_balance - p_amount
  WHERE id = p_user_id;

  INSERT INTO public.transactions (user_id, type, amount, description, category, date)
  VALUES (p_user_id, 'withdrawal', -p_amount, p_description, COALESCE(p_category, 'General'), COALESCE(p_date, now()))
  RETURNING id INTO v_tx_id;

  RETURN json_build_object('success', true, 'transaction_id', v_tx_id, 'remaining', v_balance - p_amount);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.subtract_funds(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_date timestamp with time zone,
  p_balance numeric DEFAULT NULL::numeric
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_savings numeric;
  v_active_session_id uuid;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT savings_balance INTO v_savings FROM public.users WHERE id = p_user_id;
  IF v_savings IS NULL THEN v_savings := 0; END IF;

  SELECT id INTO v_active_session_id
    FROM public.shopping_sessions
   WHERE user_id = p_user_id
     AND status = 'active'
   LIMIT 1;

  INSERT INTO public.transactions (user_id, amount, type, description, date, category, session_id)
  VALUES (p_user_id, p_amount, 'withdrawal', p_description, COALESCE(p_date, now()), 'General', v_active_session_id);

  IF v_active_session_id IS NOT NULL THEN
    UPDATE public.shopping_sessions
    SET current_spent = coalesce(current_spent, 0) + p_amount
    WHERE id = v_active_session_id
      AND user_id = p_user_id;
  END IF;

  UPDATE public.users
  SET
    bank_balance = p_balance,
    current_balance = (p_balance - v_savings)
  WHERE id = p_user_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. edit_transaction: align the sign-flip branch with the real vocabulary.
--    Only 'deposit' is the inflow type; 'credit'/'income' were dead code.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edit_transaction(
  p_transaction_id uuid,
  p_user_id uuid,
  p_new_amount numeric,
  p_new_description text,
  p_new_category text
)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_old_amount NUMERIC;
  v_type TEXT;
  v_session_id UUID;
  v_final_new_amount NUMERIC;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  SELECT amount, type, session_id INTO v_old_amount, v_type, v_session_id
  FROM transactions
  WHERE id = p_transaction_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Transaction not found');
  END IF;

  -- Outflow types are stored negative, inflow types positive.
  -- Only vocabulary from transactions_type_check appears here; 'credit' and
  -- 'income' are legacy and can never occur in the column.
  IF v_type IN ('expense', 'withdrawal') AND p_new_amount > 0 THEN
    v_final_new_amount := p_new_amount * -1;
  ELSIF v_type = 'deposit' AND p_new_amount < 0 THEN
    v_final_new_amount := p_new_amount * -1;
  ELSE
    v_final_new_amount := p_new_amount;
  END IF;

  UPDATE transactions
  SET amount = v_final_new_amount,
      description = p_new_description
  WHERE id = p_transaction_id AND user_id = p_user_id;

  -- Internal vault transfers move money between the user's own wallets, so they
  -- must not move the main balance.
  IF v_type NOT IN ('vault_deposit', 'vault_withdrawal') THEN
    UPDATE users
    SET current_balance = current_balance - v_old_amount + v_final_new_amount
    WHERE id = p_user_id;
  END IF;

  IF v_session_id IS NOT NULL AND v_type IN ('expense', 'withdrawal') THEN
    UPDATE shopping_sessions
    SET current_spent = coalesce(current_spent, 0) + v_old_amount - v_final_new_amount
    WHERE id = v_session_id AND user_id = p_user_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. delete_transaction: same treatment. Refunding an internal transfer would
--    have moved the main balance without any corresponding outflow.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_transaction(
  p_transaction_id uuid,
  p_user_id uuid
)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_amount NUMERIC;
  v_type TEXT;
  v_session_id UUID;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  SELECT amount, type, session_id INTO v_amount, v_type, v_session_id
  FROM transactions
  WHERE id = p_transaction_id AND user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Transaction not found');
  END IF;

  IF v_type IN ('expense', 'withdrawal') THEN
    UPDATE users
    SET current_balance = current_balance + abs(v_amount)
    WHERE id = p_user_id;

    IF v_session_id IS NOT NULL THEN
      UPDATE shopping_sessions
      SET current_spent = coalesce(current_spent, 0) - abs(v_amount)
      WHERE id = v_session_id AND user_id = p_user_id;
    END IF;
  ELSIF v_type IN ('vault_deposit', 'vault_withdrawal') THEN
    -- Reverse the internal transfer so the two wallets stay consistent.
    UPDATE users
    SET current_balance = current_balance + v_amount,
        savings_balance = savings_balance - v_amount
    WHERE id = p_user_id;
  END IF;

  DELETE FROM transactions WHERE id = p_transaction_id AND user_id = p_user_id;

  RETURN json_build_object('success', true);
END;
$function$;
