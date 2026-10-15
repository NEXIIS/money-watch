-- Gap 1: get_daily/weekly/monthly_total only count outflows (expense + withdrawal),
-- not deposits. Deposits are inflows and must never reduce the "spent this week" figure.
CREATE OR REPLACE FUNCTION public.get_daily_total()
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(sum(amount), 0)
    FROM transactions
   WHERE user_id = auth.uid()
     AND date >= current_date
     AND date < current_date + interval '1 day'
     AND type IN ('expense', 'withdrawal');
$function$;

CREATE OR REPLACE FUNCTION public.get_weekly_total()
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(sum(amount), 0)
    FROM transactions
   WHERE user_id = auth.uid()
     AND date >= date_trunc('week', now())
     AND type IN ('expense', 'withdrawal');
$function$;

CREATE OR REPLACE FUNCTION public.get_monthly_total()
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(sum(amount), 0)
    FROM transactions
   WHERE user_id = auth.uid()
     AND date >= date_trunc('month', now())
     AND type IN ('expense', 'withdrawal');
$function$;

-- Gap 2: handle_new_user must create a user_settings row so the Dynamic Limits
-- feature has somewhere to write when the UI is ready.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
BEGIN
  INSERT INTO public.users (id, email, username, current_balance, savings_balance)
  VALUES (
    new.id,
    new.email,
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'username', '')), ''),
    0,
    0
  )
  ON CONFLICT (id) DO UPDATE
    SET username = coalesce(public.users.username, excluded.username),
        email    = coalesce(public.users.email, excluded.email);

  INSERT INTO public.user_settings (user_id)
  SELECT new.id
  WHERE NOT EXISTS (SELECT 1 FROM public.user_settings WHERE user_id = new.id);

  RETURN new;
END;
$function$;

-- Backfill: every existing user needs a settings row.
INSERT INTO public.user_settings (user_id)
SELECT u.id
FROM public.users u
WHERE NOT EXISTS (SELECT 1 FROM public.user_settings us WHERE us.user_id = u.id);
