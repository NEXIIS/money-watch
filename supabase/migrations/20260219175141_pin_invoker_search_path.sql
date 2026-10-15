-- Pin search_path on the remaining public functions, and repair the bank-sync
-- overloads.
--
-- Follow-up to 20260219175140, which handled the SECURITY DEFINER set. Three
-- functions were still role-mutable: add_funds / subtract_funds (the
-- p_balance overloads) and the create_default_categories trigger.
--
-- Two things are corrected here beyond search_path:
--
-- 1. Return type. The p_balance overloads return `void`, not `json`, so they
--    must be rewritten as void. An earlier attempt to return json failed with
--    SQLSTATE 42P13 (cannot change return type of existing function).
--
-- 2. shopping_sessions.is_active does not exist. The subtract_funds overload
--    ("Market Mode") selected
--      from shopping_sessions where user_id = ... and is_active = true
--    but that table's flag is `status = 'active'`. The column is absent, so
--    this function raised 42703 on every call and the whole bank-debit path
--    was dead. Fixed to use the status column, and the session update is
--    guarded on user_id.
--
-- Both overloads also gain the auth.uid() guard so a signed-in caller cannot
-- pass another user's p_user_id, matching the definer overloads.

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
  VALUES (p_user_id, p_amount, 'credit', p_description, COALESCE(p_date, now()), 'Income');

  UPDATE public.users
  SET
    bank_balance = p_balance,
    current_balance = (p_balance - v_savings)
  WHERE id = p_user_id;
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

  -- shopping_sessions flags active rows with status = 'active', not is_active.
  SELECT id INTO v_active_session_id
    FROM public.shopping_sessions
   WHERE user_id = p_user_id
     AND status = 'active'
   LIMIT 1;

  INSERT INTO public.transactions (user_id, amount, type, description, date, category, session_id)
  VALUES (p_user_id, p_amount, 'debit', p_description, COALESCE(p_date, now()), 'General', v_active_session_id);

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

CREATE OR REPLACE FUNCTION public.create_default_categories()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
BEGIN
  INSERT INTO public.user_categories (user_id, name, color)
  VALUES
    (NEW.id, 'Food & Drinks', '#F59E0B'),
    (NEW.id, 'Transportation', '#3B82F6'),
    (NEW.id, 'Entertainment', '#8B5CF6'),
    (NEW.id, 'Bills & Utilities', '#EF4444'),
    (NEW.id, 'Shopping', '#EC4899'),
    (NEW.id, 'Health & Fitness', '#10B981'),
    (NEW.id, 'General', '#64748B'),
    (NEW.id, 'Transfer', '#14B8A6');

  RETURN NEW;
END;
$function$;
