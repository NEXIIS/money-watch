-- Align public.user_settings with the documented schema and lock it down.
--
-- The live table already existed with a different shape (no user_id, plus
-- phone_number/balance leftovers) and was readable/writable by anon via
-- "Public Access" / "Public Update" policies. This makes it per-user.

ALTER TABLE public.user_settings ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE public.user_settings ADD COLUMN IF NOT EXISTS daily_savings_goal   numeric(14,2);
ALTER TABLE public.user_settings ADD COLUMN IF NOT EXISTS weekly_savings_goal  numeric(14,2);
ALTER TABLE public.user_settings ADD COLUMN IF NOT EXISTS monthly_savings_goal numeric(14,2);
ALTER TABLE public.user_settings ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Backfill ownership from the single existing settings row before enforcing NOT NULL.
UPDATE public.user_settings
   SET user_id = (SELECT id FROM public.users ORDER BY created_at LIMIT 1)
 WHERE user_id IS NULL;

-- Remove any orphaned rows that could not be backfilled.
DELETE FROM public.user_settings WHERE user_id IS NULL;

ALTER TABLE public.user_settings ALTER COLUMN user_id SET NOT NULL;

-- Drop the world-accessible policies.
DROP POLICY IF EXISTS "Public Access" ON public.user_settings;
DROP POLICY IF EXISTS "Public Update" ON public.user_settings;
DROP POLICY IF EXISTS "Users can view own settings"   ON public.user_settings;
DROP POLICY IF EXISTS "Users can insert own settings" ON public.user_settings;
DROP POLICY IF EXISTS "Users can update own settings" ON public.user_settings;

ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own settings"
  ON public.user_settings FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own settings"
  ON public.user_settings FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own settings"
  ON public.user_settings FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_user_settings_user_id ON public.user_settings(user_id);
