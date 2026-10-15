-- Repair two orphan vault_overdraft rows (Mar 2026) that had no matching expense.
-- The vault's -500 share was never refunded to savings_balance.
-- Precondition: user's balances are 30000/8000; after: 29000/9000.
DO $$
DECLARE
  uid uuid := 'ffd354a7-08cd-4d09-8c4b-1318afa38970';
  before_main numeric;
  before_sav numeric;
  n int;
BEGIN
  SELECT current_balance, savings_balance INTO before_main, before_sav FROM users WHERE id = uid;
  RAISE NOTICE 'BEFORE % %', before_main, before_sav;

  UPDATE users
     SET current_balance = current_balance - 1000,
         savings_balance = savings_balance + 1000
   WHERE id = uid;

  DELETE FROM transactions
   WHERE id IN (
     '2c866897-141a-414e-9475-19fe19f13515',
     '81415e50-00e4-4aa8-a8a3-9fef80ea61ec'
   );
  GET DIAGNOSTICS n = ROW_COUNT;

  SELECT current_balance, savings_balance INTO before_main, before_sav FROM users WHERE id = uid;
  RAISE NOTICE 'AFTER % % deleted=%', before_main, before_sav, n;
END $$;
