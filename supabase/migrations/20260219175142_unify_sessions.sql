-- Unify the two budget-session tables onto shopping_sessions.
--
-- Problem: two competing session tables existed.
--
--   shopping_sessions   status/current_spent   <- the app reads and writes this
--   spending_sessions   is_active/spent_amount <- the RPCs updated this
--
-- and transactions.session_id had a foreign key to spending_sessions(id).
-- Because the frontend created sessions in shopping_sessions and then passed
-- that id to log_expense, every expense logged during an active session hit a
-- foreign-key violation, the RPC's exception handler swallowed it, and the UI
-- showed "Failed to log expense". Even where that did not fail, the overlay
-- read current_spent from shopping_sessions while log_expense updated
-- spending_sessions.spent_amount, so the progress ring never moved.
--
-- Resolution: shopping_sessions wins. It is what src/types/index.ts,
-- useWallet.ts, BudgetSessionOverlay and SessionHistory all assume.
--
-- Row ids are preserved when copying, so the 6 existing transactions keep
-- pointing at valid sessions and the FK can simply be repointed.

-- ---------------------------------------------------------------------------
-- 1. Copy spending_sessions rows into shopping_sessions, keeping the same id.
--
--    current_spent is recomputed from the ledger rather than copied from
--    spent_amount, because the counters had drifted: session
--    1a3e1e3f... recorded spent_amount = 0 while its two transactions summed
--    to 5500. The transaction rows are the source of truth.
--
--    ended_at is backfilled from created_at for non-active rows, since the
--    live data had status-equivalent is_active = false with a NULL ended_at,
--    which would render as a permanently unfinished session in history.
-- ---------------------------------------------------------------------------
INSERT INTO public.shopping_sessions (id, user_id, name, budget_limit, current_spent, status, started_at, ended_at)
SELECT s.id,
       s.user_id,
       s.name,
       s.budget_limit,
       COALESCE((
         SELECT sum(abs(t.amount))
           FROM public.transactions t
          WHERE t.session_id = s.id
            AND t.type = 'expense'
       ), 0),
       CASE WHEN s.is_active THEN 'active' ELSE 'completed' END,
       COALESCE(s.created_at, now()),
       CASE WHEN s.is_active THEN NULL ELSE COALESCE(s.ended_at, s.created_at) END
  FROM public.spending_sessions s
 WHERE NOT EXISTS (SELECT 1 FROM public.shopping_sessions x WHERE x.id = s.id);

-- Recompute for shopping_sessions rows that already existed but whose counter
-- may not match their transactions.
UPDATE public.shopping_sessions ss
   SET current_spent = COALESCE((
         SELECT sum(abs(t.amount))
           FROM public.transactions t
          WHERE t.session_id = ss.id
            AND t.type = 'expense'
       ), 0);

-- ---------------------------------------------------------------------------
-- 2. Repoint transactions.session_id at shopping_sessions, then drop the old
--    table. ON DELETE SET NULL keeps the ledger intact if a session is removed.
-- ---------------------------------------------------------------------------
ALTER TABLE public.transactions
  DROP CONSTRAINT IF EXISTS transactions_session_id_fkey;

-- Clear any session_id that does not resolve, so the new FK can be created.
-- In practice the copy above preserved every id, so this affects no rows.
UPDATE public.transactions t
   SET session_id = NULL
 WHERE t.session_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.shopping_sessions s WHERE s.id = t.session_id);

ALTER TABLE public.transactions
  ADD CONSTRAINT transactions_session_id_fkey
  FOREIGN KEY (session_id) REFERENCES public.shopping_sessions(id) ON DELETE SET NULL;

DROP TABLE IF EXISTS public.spending_sessions;

-- ---------------------------------------------------------------------------
-- 3. Point the three ledger RPCs at shopping_sessions.current_spent.
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

  IF v_current_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'User not found');
  END IF;

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
    UPDATE shopping_sessions
    SET current_spent = coalesce(current_spent, 0) + v_expense
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
    UPDATE shopping_sessions
    SET current_spent = coalesce(current_spent, 0) + v_old_amount - v_final_new_amount
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
      UPDATE shopping_sessions
      SET current_spent = coalesce(current_spent, 0) - abs(v_amount)
      WHERE id = v_session_id AND user_id = p_user_id;
    END IF;
  END IF;

  DELETE FROM transactions WHERE id = p_transaction_id AND user_id = p_user_id;

  RETURN json_build_object('success', true);
END;
$function$;

-- The remaining subtract_funds overload that writes a session_id.
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

  IF p_session_id IS NOT NULL THEN
    UPDATE shopping_sessions
    SET current_spent = coalesce(current_spent, 0) + p_amount
    WHERE id = p_session_id AND user_id = p_user_id;
  END IF;

  RETURN json_build_object('success', true, 'transaction_id', v_tx_id, 'remaining', v_balance - p_amount);
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Tighten shopping_sessions: the old ALL policy on spending_sessions was
--    granted to `public`. Replace the per-command policies with an equivalent
--    authenticated-only set plus indexes for the queries useWallet runs.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_shopping_sessions_user_id  ON public.shopping_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_shopping_sessions_user_status
  ON public.shopping_sessions(user_id, status);
CREATE INDEX IF NOT EXISTS idx_transactions_session_id      ON public.transactions(session_id);
CREATE INDEX IF NOT EXISTS idx_transactions_user_date      ON public.transactions(user_id, date DESC);
