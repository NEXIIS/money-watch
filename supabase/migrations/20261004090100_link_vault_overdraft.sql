-- Make the vault-overdraft lifecycle reversible, and let edits change category.
--
-- Problem 1 (money leak): `log_expense` writes two rows when the main balance
-- cannot cover an expense: the `expense` row (-amount) and a
-- `vault_overdraft` row (-shortfall) recording the vault's share. Nothing
-- linked them. `delete_transaction` refunded the full expense amount to
-- `current_balance` without returning the shortfall to `savings_balance` and
-- without removing the overdraft row, so deleting an overdrafted expense
-- created money out of nothing. `edit_transaction` leaked the same way
-- whenever the new amount was smaller than the old one.
--
-- Problem 2 (dead parameter): `edit_transaction` accepted `p_new_category`
-- and never wrote it, and `delete_transaction` silently ignored refunds for
-- `deposit` rows.
--
-- This migration:
--   1. Adds `transactions.linked_to`, a self-FK to the expense a vault
--      adjustment belongs to.
--   2. log_expense inserts the expense first, then links the overdraft row.
--   3. delete_transaction reverses the main/vault split through linked_to,
--      refunds deposits, and refuses to delete an overdraft row on its own.
--   4. edit_transaction reverses the old amount and re-applies the new one
--      through the same helper logic, and writes the category.
--
-- Sign convention: outflow types ('expense', 'withdrawal') are stored
-- negative, 'deposit' positive, vault transfers signed by direction.

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS linked_to uuid REFERENCES public.transactions(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_linked_to ON public.transactions(linked_to);

-- Backfill the links for rows created before this migration. Both rows are
-- written inside one transaction, so the timestamps are identical.
UPDATE public.transactions o
   SET linked_to = (
     SELECT e.id
       FROM public.transactions e
      WHERE e.user_id = o.user_id
        AND e.type = 'expense'
        AND e.session_id IS NOT DISTINCT FROM o.session_id
        AND e.created_at BETWEEN o.created_at - interval '5 seconds'
                              AND o.created_at + interval '5 seconds'
      ORDER BY abs(extract(epoch FROM (o.created_at - e.created_at))) ASC
      LIMIT 1
   )
 WHERE o.type = 'vault_overdraft'
   AND o.linked_to IS NULL;

-- log_expense ---------------------------------------------------------------
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
  v_shortfall numeric := 0;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  v_expense := abs(p_amount);

  SELECT current_balance, savings_balance
    INTO v_current_balance, v_savings_balance
    FROM public.users WHERE id = p_user_id
    FOR UPDATE;

  IF v_current_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'User not found');
  END IF;

  IF v_current_balance >= v_expense THEN
    UPDATE public.users
    SET current_balance = current_balance - v_expense
    WHERE id = p_user_id;
  ELSE
    v_shortfall := v_expense - v_current_balance;

    IF v_savings_balance < v_shortfall THEN
      RETURN json_build_object('success', false, 'error', 'Insufficient total funds (Main + Vault).');
    END IF;

    UPDATE public.users
    SET current_balance = 0,
        savings_balance = savings_balance - v_shortfall
    WHERE id = p_user_id;
  END IF;

  INSERT INTO public.transactions
    (user_id, type, amount, description, category, category_id, session_id)
  VALUES (
    p_user_id, 'expense', -v_expense, p_description,
    coalesce((SELECT c.name FROM public.user_categories c WHERE c.id = p_category_id), 'General'),
    p_category_id,
    p_session_id
  )
  RETURNING id INTO v_transaction_id;

  -- The vault's share of the bill. Linked to the expense so deleting or
  -- editing that expense can hand the money back.
  IF v_shortfall > 0 THEN
    INSERT INTO public.transactions
      (user_id, type, amount, description, category, category_id, session_id, linked_to)
    VALUES (
      p_user_id, 'vault_overdraft', -v_shortfall,
      'Vault Overdraft: Covered shortfall',
      coalesce((SELECT c.name FROM public.user_categories c WHERE c.id = p_category_id), 'General'),
      p_category_id,
      p_session_id,
      v_transaction_id
    );
  END IF;

  IF p_session_id IS NOT NULL THEN
    UPDATE public.shopping_sessions
    SET current_spent = coalesce(current_spent, 0) + v_expense
    WHERE id = p_session_id AND user_id = p_user_id;
  END IF;

  RETURN json_build_object('success', true, 'transaction_id', v_transaction_id);
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- delete_transaction --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_transaction(
  p_transaction_id uuid,
  p_user_id uuid
)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_amount numeric;
  v_type text;
  v_session_id uuid;
  v_overdraft numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  SELECT t.amount, t.type, t.session_id
    INTO v_amount, v_type, v_session_id
    FROM public.transactions t
   WHERE t.id = p_transaction_id AND t.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Transaction not found');
  END IF;

  -- Overdraft rows are the vault's half of an expense. Deleting one on its
  -- own would take money out of the vault with nothing to give back.
  IF v_type = 'vault_overdraft' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'This is an automatic vault adjustment. Delete the expense that used the vault instead.'
    );
  END IF;

  PERFORM 1 FROM public.users WHERE id = p_user_id FOR UPDATE;

  SELECT coalesce(sum(abs(t.amount)), 0)
    INTO v_overdraft
    FROM public.transactions t
   WHERE t.linked_to = p_transaction_id
     AND t.user_id = p_user_id
     AND t.type = 'vault_overdraft';

  IF v_type IN ('expense', 'withdrawal') THEN
    -- Give back what came out of the main balance and what the vault covered.
    UPDATE public.users
    SET current_balance = current_balance + abs(v_amount) - v_overdraft,
        savings_balance  = savings_balance + v_overdraft
    WHERE id = p_user_id;

    DELETE FROM public.transactions
     WHERE linked_to = p_transaction_id
       AND user_id = p_user_id
       AND type = 'vault_overdraft';

    IF v_session_id IS NOT NULL THEN
      UPDATE public.shopping_sessions
      SET current_spent = greatest(coalesce(current_spent, 0) - abs(v_amount), 0)
      WHERE id = v_session_id AND user_id = p_user_id;
    END IF;
  ELSIF v_type = 'deposit' THEN
    UPDATE public.users
    SET current_balance = current_balance - v_amount
    WHERE id = p_user_id;
  ELSIF v_type IN ('vault_deposit', 'vault_withdrawal') THEN
    -- Reverse the internal transfer so the two wallets stay consistent.
    UPDATE public.users
    SET current_balance = current_balance + v_amount,
        savings_balance  = savings_balance - v_amount
    WHERE id = p_user_id;
  END IF;

  DELETE FROM public.transactions WHERE id = p_transaction_id AND user_id = p_user_id;

  RETURN json_build_object('success', true);
END;
$function$;

-- edit_transaction ----------------------------------------------------------
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
  v_old_amount numeric;
  v_type text;
  v_session_id uuid;
  v_old_category_id uuid;
  v_final_new_amount numeric;
  v_category_id uuid;
  v_main numeric;
  v_savings numeric;
  v_overdraft numeric;
  v_main_after numeric;
  v_savings_after numeric;
  v_deduct numeric;
  v_new_shortfall numeric;
BEGIN
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    RETURN json_build_object('success', false, 'error', 'Not authorized');
  END IF;

  SELECT t.amount, t.type, t.session_id, t.category_id
    INTO v_old_amount, v_type, v_session_id, v_old_category_id
    FROM public.transactions t
   WHERE t.id = p_transaction_id AND t.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'Transaction not found');
  END IF;

  IF v_type = 'vault_overdraft' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'This is an automatic vault adjustment. Edit the expense that used the vault instead.'
    );
  END IF;

  IF p_new_amount IS NULL OR abs(p_new_amount) <= 0 THEN
    RETURN json_build_object('success', false, 'error', 'Amount must be greater than zero');
  END IF;

  -- Normalise the sign from the type, not from what the client sent.
  IF v_type IN ('expense', 'withdrawal') THEN
    v_final_new_amount := -abs(p_new_amount);
  ELSIF v_type = 'deposit' THEN
    v_final_new_amount := abs(p_new_amount);
  ELSE
    v_final_new_amount := p_new_amount;
  END IF;

  -- Only accept a category id that actually belongs to this user.
  IF p_new_category ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     AND EXISTS (
       SELECT 1 FROM public.user_categories c
        WHERE c.id = p_new_category::uuid AND c.user_id = p_user_id
     )
  THEN
    v_category_id := p_new_category::uuid;
  END IF;

  SELECT u.current_balance, u.savings_balance
    INTO v_main, v_savings
    FROM public.users u
   WHERE u.id = p_user_id
   FOR UPDATE;

  IF v_main IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'User not found');
  END IF;

  IF v_type IN ('expense', 'withdrawal') THEN
    SELECT coalesce(sum(abs(t.amount)), 0)
      INTO v_overdraft
      FROM public.transactions t
     WHERE t.linked_to = p_transaction_id
       AND t.user_id = p_user_id
       AND t.type = 'vault_overdraft';

    -- Balances as if the old expense had never happened, then check the new
    -- amount is affordable before writing anything.
    v_main_after   := v_main + abs(v_old_amount) - v_overdraft;
    v_savings_after := v_savings + v_overdraft;
    v_deduct        := least(abs(v_final_new_amount), v_main_after);
    v_new_shortfall := abs(v_final_new_amount) - v_deduct;

    IF v_new_shortfall > 0 AND v_savings_after < v_new_shortfall THEN
      RETURN json_build_object('success', false, 'error', 'Insufficient total funds (Main + Vault).');
    END IF;

    UPDATE public.users
    SET current_balance = v_main_after - v_deduct,
        savings_balance  = v_savings_after - v_new_shortfall
    WHERE id = p_user_id;

    DELETE FROM public.transactions
     WHERE linked_to = p_transaction_id
       AND user_id = p_user_id
       AND type = 'vault_overdraft';

    IF v_new_shortfall > 0 THEN
      INSERT INTO public.transactions
        (user_id, type, amount, description, category, category_id, session_id, linked_to)
      VALUES (
        p_user_id, 'vault_overdraft', -v_new_shortfall,
        'Vault Overdraft: Covered shortfall',
        coalesce(
          (SELECT c.name FROM public.user_categories c
            WHERE c.id = coalesce(v_category_id, v_old_category_id)),
          'General'
        ),
        coalesce(v_category_id, v_old_category_id),
        v_session_id,
        p_transaction_id
      );
    END IF;
  ELSIF v_type NOT IN ('vault_deposit', 'vault_withdrawal') THEN
    -- Deposits and anything else that moves the main balance.
    UPDATE public.users
    SET current_balance = current_balance - v_old_amount + v_final_new_amount
    WHERE id = p_user_id;
  END IF;

  UPDATE public.transactions
  SET amount = v_final_new_amount,
      description = p_new_description,
      category_id = coalesce(v_category_id, v_old_category_id),
      category = coalesce(
        (SELECT c.name FROM public.user_categories c
          WHERE c.id = coalesce(v_category_id, v_old_category_id)),
        category
      )
   WHERE id = p_transaction_id
     AND user_id = p_user_id;

  IF v_session_id IS NOT NULL AND v_type IN ('expense', 'withdrawal') THEN
    UPDATE public.shopping_sessions
    SET current_spent = greatest(
      coalesce(current_spent, 0) - abs(v_old_amount) + abs(v_final_new_amount), 0
    )
    WHERE id = v_session_id AND user_id = p_user_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$function$;