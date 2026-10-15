-- Lock down SECURITY DEFINER functions and pin their search_path.
--
-- Problem: every SECURITY DEFINER function in public was executable by `anon`
-- (verified with has_function_privilege) and had a role-mutable search_path.
-- None of them verify that p_user_id belongs to the caller, and p_user_id is a
-- parameter. The anon key ships in the Vite bundle, so anyone could call
-- move_to_vault / withdraw_from_vault / sync_bank_to_app with another user's
-- UUID and drain or rewrite their balances.
--
-- This migration:
--   1. REVOKEs EXECUTE from anon on all public functions.
--   2. Pins search_path on the SECURITY DEFINER ones (fixes lint 0011).
--   3. Adds an auth.uid() guard so p_user_id can only be the caller's own id.
--
-- The app is unaffected: it always calls these as a signed-in user, so the
-- `authenticated` grants are retained.

-- ---------------------------------------------------------------------------
-- 1. Revoke anon EXECUTE on every function in public.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Pin search_path on every SECURITY DEFINER function (lint 0011).
--    public first so app objects resolve, pg_temp last so it cannot be
--    shadowed by a caller-created temp table.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosecdef
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', r.sig);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Ownership guards.
--
-- The functions that take p_user_id run with definer rights and would
-- otherwise trust the caller's argument. Each is rewritten to reject any
-- p_user_id that is not the authenticated caller.
--
-- Trigger functions (handle_new_user, create_default_categories,
-- sync_balance_from_transaction) are excluded: they fire as the definer and
-- p_user_id does not apply to them.
-- ---------------------------------------------------------------------------

-- move_to_vault ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.move_to_vault(p_user_id uuid, p_amount numeric)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_balance numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  SELECT current_balance INTO v_balance FROM public.users WHERE id = p_user_id FOR UPDATE;

  IF v_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'User not found');
  END IF;

  IF p_amount <= 0 THEN
    RETURN json_build_object('success', false, 'error', 'Amount must be positive');
  END IF;

  IF v_balance < p_amount THEN
    RETURN json_build_object('success', false, 'error', 'Insufficient funds');
  END IF;

  UPDATE public.users
  SET current_balance = current_balance - p_amount,
      savings_balance = savings_balance + p_amount
  WHERE id = p_user_id;

  INSERT INTO public.transactions (user_id, description, amount, type)
  VALUES (p_user_id, 'Transfer to Savings Vault', -p_amount, 'vault_deposit');

  RETURN json_build_object('success', true);
END;
$function$;

-- withdraw_from_vault ------------------------------------------------------
CREATE OR REPLACE FUNCTION public.withdraw_from_vault(p_user_id uuid, p_amount numeric)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_savings_balance NUMERIC;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  IF p_amount <= 0 THEN
    RETURN json_build_object('success', false, 'error', 'Amount must be positive');
  END IF;

  SELECT savings_balance INTO v_savings_balance
  FROM users
  WHERE id = p_user_id;

  IF v_savings_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'User not found');
  END IF;

  IF p_amount > v_savings_balance THEN
    RETURN json_build_object('success', false, 'error', 'Exceeds your Vault balance!');
  END IF;

  UPDATE users
  SET savings_balance = savings_balance - p_amount,
      current_balance = current_balance + p_amount
  WHERE id = p_user_id;

  INSERT INTO transactions (user_id, amount, category, description, type)
  VALUES (p_user_id, p_amount, 'Transfer', 'Withdrawal from Savings Vault', 'vault_withdrawal');

  RETURN json_build_object('success', true);
END;
$function$;

-- create_notification -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_notification(
  p_user_id uuid,
  p_type text,
  p_title text,
  p_message text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  INSERT INTO public.notifications (user_id, type, title, message)
  VALUES (p_user_id, p_type, p_title, p_message)
  RETURNING id INTO v_id;

  RETURN json_build_object('success', true, 'notification_id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- add_funds (SECURITY DEFINER overload) ------------------------------------
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
  VALUES (p_user_id, 'credit', p_amount, p_description, 'Income', COALESCE(p_date, now()));

  UPDATE public.users
  SET current_balance = current_balance + p_amount
  WHERE id = p_user_id
  RETURNING current_balance INTO v_new_balance;

  RETURN json_build_object('status', 'success', 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('status', 'error', 'message', SQLERRM);
END;
$function$;

-- subtract_funds (SECURITY DEFINER overloads) ------------------------------
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
  VALUES (p_user_id, 'debit', -p_amount, p_description, COALESCE(p_category, 'General'), COALESCE(p_date, now()))
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
  p_session_id uuid DEFAULT NULL::uuid
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

  IF v_balance < p_amount THEN
    RETURN json_build_object('success', false, 'error', 'Insufficient funds');
  END IF;

  UPDATE public.users
  SET current_balance = current_balance - p_amount
  WHERE id = p_user_id;

  INSERT INTO public.transactions (user_id, type, amount, description, category, session_id)
  VALUES (p_user_id, 'expense', -p_amount, p_description, 'General', p_session_id)
  RETURNING id INTO v_tx_id;

  RETURN json_build_object('success', true, 'transaction_id', v_tx_id, 'remaining', v_balance - p_amount);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- sync_bank_to_app ---------------------------------------------------------
-- This is the intended entry point for parsed bank alerts. It stays
-- authenticated-only; the server-side ingest path (edge function with the
-- service role) bypasses these grants entirely.
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
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT savings_balance INTO v_current_vault FROM public.users WHERE id = p_user_id;

  IF p_cleared_balance < v_current_vault THEN
    v_overdraft_amount := v_current_vault - p_cleared_balance;
    v_new_vault := p_cleared_balance;

    INSERT INTO public.transactions (user_id, amount, type, description, date)
    VALUES (p_user_id, v_overdraft_amount, 'vault_overdraft', 'Auto-Cover: Dipped into Vault savings', now());
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
    CASE WHEN p_type = 'debit' THEN -p_parsed_amount ELSE p_parsed_amount END,
    p_type,
    'Bank Alert',
    'General',
    now()
  );
END;
$function$;

-- process_transaction ------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_transaction(
  p_user_id uuid,
  p_amount numeric,
  p_type text,
  p_category text,
  p_description text,
  p_cleared_balance numeric
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_transaction_id UUID;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  INSERT INTO public.transactions (user_id, amount, type, category, description, date)
  VALUES (p_user_id, p_amount, p_type, COALESCE(p_category, 'General'), p_description, now())
  RETURNING id INTO v_transaction_id;

  UPDATE public.users
  SET current_balance = p_cleared_balance
  WHERE id = p_user_id;

  RETURN json_build_object('success', true, 'transaction_id', v_transaction_id);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- handle_credit / handle_debit --------------------------------------------
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
  VALUES (p_user_id, 'credit', p_amount, p_description, 'Income', COALESCE(p_date, now()));

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
  VALUES (p_user_id, 'debit', -p_amount, p_description, 'General', COALESCE(p_date, now()))
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

-- ---------------------------------------------------------------------------
-- 4. The three SECURITY INVOKER functions that take p_user_id are RLS-checked
--    already, but they still trust the argument, so they get the same guard.
--    (Invoker + RLS means the anon key cannot reach other users' rows, but a
--    signed-in user could still pass someone else's id for the balance write.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_expense(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_category_id uuid,
  p_session_id uuid DEFAULT NULL::uuid
)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_transaction_id uuid;
  v_current_balance numeric;
  v_savings_balance numeric;
  v_expense numeric;
  v_shortfall numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  v_expense := abs(p_amount);

  SELECT current_balance, savings_balance
    INTO v_current_balance, v_savings_balance
    FROM users WHERE id = p_user_id
    FOR UPDATE;

  IF v_current_balance >= v_expense THEN
    UPDATE users SET current_balance = current_balance - v_expense WHERE id = p_user_id;
  ELSE
    v_shortfall := v_expense - v_current_balance;

    IF v_savings_balance >= v_shortfall THEN
      UPDATE users
      SET current_balance = 0,
          savings_balance = savings_balance - v_shortfall
      WHERE id = p_user_id;

      INSERT INTO transactions (user_id, type, amount, description, category_id, session_id)
      VALUES (p_user_id, 'vault_overdraft', -v_shortfall, 'Vault Overdraft: Covered shortfall', p_category_id, p_session_id);
    ELSE
      RETURN json_build_object('success', false, 'error', 'Insufficient total funds (Main + Vault).');
    END IF;
  END IF;

  INSERT INTO transactions (user_id, type, amount, description, category_id, session_id)
  VALUES (p_user_id, 'expense', -v_expense, p_description, p_category_id, p_session_id)
  RETURNING id INTO v_transaction_id;

  IF p_session_id IS NOT NULL THEN
    UPDATE spending_sessions
    SET spent_amount = coalesce(spent_amount, 0) + v_expense
    WHERE id = p_session_id AND user_id = p_user_id;
  END IF;

  RETURN json_build_object('success', true, 'transaction_id', v_transaction_id);
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

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

  IF v_type = 'expense' AND p_new_amount > 0 THEN
    v_final_new_amount := p_new_amount * -1;
  ELSEIF v_type IN ('income', 'credit', 'deposit') AND p_new_amount < 0 THEN
    v_final_new_amount := p_new_amount * -1;
  ELSE
    v_final_new_amount := p_new_amount;
  END IF;

  UPDATE transactions
  SET amount = v_final_new_amount,
      description = p_new_description
  WHERE id = p_transaction_id AND user_id = p_user_id;

  UPDATE users
  SET current_balance = current_balance - v_old_amount + v_final_new_amount
  WHERE id = p_user_id;

  IF v_session_id IS NOT NULL AND v_type = 'expense' THEN
    UPDATE spending_sessions
    SET spent_amount = coalesce(spent_amount, 0) + v_old_amount - v_final_new_amount
    WHERE id = v_session_id AND user_id = p_user_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$function$;

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

  IF v_type = 'expense' THEN
    UPDATE users
    SET current_balance = current_balance + abs(v_amount)
    WHERE id = p_user_id;

    IF v_session_id IS NOT NULL THEN
      UPDATE spending_sessions
      SET spent_amount = coalesce(spent_amount, 0) - abs(v_amount)
      WHERE id = v_session_id AND user_id = p_user_id;
    END IF;
  END IF;

  DELETE FROM transactions WHERE id = p_transaction_id AND user_id = p_user_id;

  RETURN json_build_object('success', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. The three parameterless "total" helpers are SECURITY INVOKER with no
--    user filter, so they aggregate across every user's rows whenever RLS is
--    not in force for the caller. Scope them to the caller explicitly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_daily_total()
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT coalesce(sum(amount), 0)
    FROM transactions
   WHERE user_id = auth.uid()
     AND date >= current_date
     AND date < current_date + interval '1 day';
$function$;

CREATE OR REPLACE FUNCTION public.get_weekly_total()
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT coalesce(sum(amount), 0)
    FROM transactions
   WHERE user_id = auth.uid()
     AND date >= date_trunc('week', now());
$function$;

CREATE OR REPLACE FUNCTION public.get_monthly_total()
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT coalesce(sum(amount), 0)
    FROM transactions
   WHERE user_id = auth.uid()
     AND date >= date_trunc('month', now());
$function$;

-- ---------------------------------------------------------------------------
-- 6. Re-grant EXECUTE to authenticated. PUBLIC keeps the default grant for
--    anything created later, so strip that too.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
  END LOOP;
END $$;
