-- Carry the signup username from Auth metadata into `public.users`.
--
-- Problem: `handle_new_user` inserted only (id, email, balances), so every new
-- signup had `users.username = NULL`. The header falls back to the auth
-- metadata for display, but `SettingsView` seeded its "Display Name" field
-- from `users.username` and opened blank, and the fallback insert in
-- `useWallet.fetchWallet` only ran when the row was missing entirely.
--
-- `Auth.tsx` already sends `options.data.username` on signUp, so the value is
-- in `raw_user_meta_data`.

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
    -- Only fill a gap. Never clobber a name the user has since chosen, and
    -- never overwrite an email that Auth has since verified or changed.
    SET username = coalesce(public.users.username, excluded.username),
        email    = coalesce(public.users.email, excluded.email);

  RETURN new;
END;
$function$;