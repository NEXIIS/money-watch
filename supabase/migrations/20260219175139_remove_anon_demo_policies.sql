-- Remove demo anon policies (authenticated-user-only RLS)
DROP POLICY IF EXISTS "Allow anon read users" ON public.users;
DROP POLICY IF EXISTS "Allow anon read transactions" ON public.transactions;
DROP POLICY IF EXISTS "Allow anon read sessions" ON public.shopping_sessions;
DROP POLICY IF EXISTS "Allow anon insert transactions" ON public.transactions;
DROP POLICY IF EXISTS "Allow anon insert sessions" ON public.shopping_sessions;
DROP POLICY IF EXISTS "Allow anon update users" ON public.users;
DROP POLICY IF EXISTS "Allow anon update sessions" ON public.shopping_sessions;
DROP POLICY IF EXISTS "Allow anon insert users" ON public.users;
