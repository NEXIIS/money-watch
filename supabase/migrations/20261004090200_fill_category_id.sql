-- Give every transaction row a `category_id`, and fix the invalid default.
--
-- Problem 1: `transactions.type` still defaulted to `'debit'`, a value
-- `transactions_type_check` rejects. Any insert that omitted `type` failed
-- with a confusing constraint error instead of storing a row.
--
-- Problem 2: every RPC that writes bank-synced rows (`sync_bank_to_app`,
-- `handle_debit`, `subtract_funds`, `process_transaction`) set only the legacy
-- `category` text column, leaving `category_id` NULL. `ExpenseChart` groups by
-- `category_id`, so those rows rendered as an "Uncategorized" slice. This
-- migration fixes it in one place — a BEFORE INSERT trigger — instead of
-- rewriting seven RPC bodies, so any future insert path is covered too.

ALTER TABLE public.transactions
  ALTER COLUMN type SET DEFAULT 'expense';

CREATE OR REPLACE FUNCTION public.fill_transaction_category_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_name text;
BEGIN
  IF NEW.category_id IS NULL THEN
    v_name := nullif(btrim(coalesce(NEW.category, '')), '');

    -- Prefer an exact match on the legacy text, then the user's General bucket.
    SELECT c.id INTO NEW.category_id
      FROM public.user_categories c
     WHERE c.user_id = NEW.user_id
       AND lower(c.name) = lower(v_name)
     LIMIT 1;

    IF NEW.category_id IS NULL THEN
      SELECT c.id INTO NEW.category_id
        FROM public.user_categories c
       WHERE c.user_id = NEW.user_id
         AND lower(c.name) = 'general'
       LIMIT 1;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_fill_transaction_category_id ON public.transactions;

CREATE TRIGGER trg_fill_transaction_category_id
BEFORE INSERT ON public.transactions
FOR EACH ROW EXECUTE FUNCTION public.fill_transaction_category_id();

-- Backfill the rows that already exist (the vault transfers, which were
-- inserted with category 'Transfer' / 'General' but no category_id).
UPDATE public.transactions t
   SET category_id = c.id
  FROM public.user_categories c
 WHERE t.category_id IS NULL
   AND c.user_id = t.user_id
   AND lower(c.name) = lower(coalesce(t.category, ''))
   AND t.category_id IS DISTINCT FROM c.id;

-- Re-grant EXECUTE on the new function to authenticated only, matching the
-- lockdown applied in 20260219175140_secure_definer_functions.sql.
REVOKE EXECUTE ON FUNCTION public.fill_transaction_category_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fill_transaction_category_id() TO authenticated;