-- Publish the tables the app subscribes to.
--
-- Problem: only `transactions` and `shopping_sessions` were in the
-- `supabase_realtime` publication, but `useWallet` also subscribes to
-- INSERT on `notifications` and would like to follow `users` balance
-- changes. The notification subscription therefore never fired: new
-- notifications only appeared after a manual refetch.
--
-- `users` is added so a second tab updates when the first tab moves money to
-- the vault, logs an expense, or has a session updated.

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['notifications', 'users'] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_publication_tables pt
       WHERE pt.pubname = 'supabase_realtime'
         AND pt.tablename = t
    ) THEN
      EXECUTE format('alter publication supabase_realtime add table %I', t);
    END IF;
  END LOOP;
END $$;