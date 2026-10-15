-- Make the email -> reconciliation path actually reachable, and make it multi-user.
--
-- WHY THIS MIGRATION EXISTS
-- ------------------------
-- Every money RPC so far guarded itself with:
--     if auth.uid() is distinct from p_user_id then raise 'Not authorized'
-- Make's Supabase connection talks to PostgREST with the project API key, which
-- carries NO jwt sub. So auth.uid() is NULL for both the anon key and the
-- service_role key, and that guard rejects every call coming from Make. Worse,
-- reconcile_bank_account swallows its own exceptions, so Make received
-- HTTP 200 {"success": false, "error": "Not authorized"} -- a silent no-op that
-- looks like a working automation.
--
-- The old scenario hid this by hardcoding p_user_id, which is exactly the
-- single-user assumption we are removing.
--
-- THIS MIGRATION
--   1. apply_reconciliation()               - the one copy of the drift math.
--   2. reconcile_bank_account()             - unchanged signature/contract,
--                                             now a thin wrapper over (1).
--   3. reconcile_bank_account_by_email()    - service_role ONLY. Resolves
--                                             email -> user -> account
--                                             server-side, so no blueprint ever
--                                             carries a user id.
--
-- The invariant is unchanged and still holds after every path below:
--   users.current_balance == sum(active bank_accounts.ledger_balance)
-- savings_balance is never read or written by any of these functions.

-- ---------------------------------------------------------------- core

create or replace function public.apply_reconciliation(
  p_user_id            uuid,
  p_account_id         uuid,
  p_reported_balance   numeric,
  p_reported_at        timestamptz default null
)
returns json
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_owner   uuid;
  v_ledger  numeric;
  v_label   text;
  v_drift   numeric;
  v_tx_id   uuid;
  v_at      timestamptz := coalesce(p_reported_at, now());
begin
  -- Two ways in, and nobody else:
  --   service_role  - the machine path (Make). Holds the service key.
  --   auth.uid()    - the signed-in owner reconciling their own account.
  -- anon and any authenticated non-owner match neither branch and are refused.
  if auth.role() is distinct from 'service_role'
     and auth.uid() is distinct from p_user_id then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if p_reported_balance is null or p_reported_balance < 0 then
    raise exception 'Reported balance must be zero or greater'
      using errcode = '22023';
  end if;

  select user_id, ledger_balance, label
    into v_owner, v_ledger, v_label
    from public.bank_accounts
   where id = p_account_id and not is_archived
   for update;

  if v_owner is null then
    raise exception 'Account not found' using errcode = 'P0002';
  end if;

  if v_owner is distinct from p_user_id then
    raise exception 'Account does not belong to that user'
      using errcode = '42501';
  end if;

  v_drift := p_reported_balance - v_ledger;

  if v_drift <> 0 then
    -- The visible part: an auditable correction, never a silent overwrite.
    insert into public.transactions
      (user_id, account_id, type, amount, description, category, date)
    values (
      v_owner,
      p_account_id,
      'reconciliation',
      v_drift,
      format('Reconciled with %s: %s',
             coalesce(v_label, 'bank'),
             case when v_drift > 0 then '+' else '-' end
               || abs(v_drift)::text),
      'General',
      v_at
    )
    returning id into v_tx_id;

    -- Move the global ledger by the same amount. The vault is untouched.
    update public.users
       set current_balance = current_balance + v_drift
     where id = v_owner;

    update public.bank_accounts
       set ledger_balance = ledger_balance + v_drift
     where id = p_account_id;
  end if;

  update public.bank_accounts
     set reported_balance = p_reported_balance,
         reported_at      = v_at
   where id = p_account_id;

  return json_build_object(
    'success',         true,
    'account_id',      p_account_id,
    'label',           v_label,
    'reported',        p_reported_balance,
    'previous_ledger', v_ledger,
    'drift',           v_drift,
    'reconciled',      v_drift <> 0,
    'transaction_id',  v_tx_id
  );
end;
$function$;

revoke all on function public.apply_reconciliation(uuid, uuid, numeric, timestamptz)
  from public, anon;
grant execute on function public.apply_reconciliation(uuid, uuid, numeric, timestamptz)
  to authenticated, service_role;

-- ------------------------------------------------- authenticated entry point
-- Same name, same arguments, same returned JSON as before: the Bank Accounts
-- panel calls this and its contract is unchanged.

create or replace function public.reconcile_bank_account(
  p_account_id       uuid,
  p_reported_balance numeric,
  p_reported_at      timestamptz default null
)
returns json
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_owner uuid;
begin
  select user_id into v_owner
    from public.bank_accounts
   where id = p_account_id and not is_archived;

  if v_owner is null then
    return json_build_object('success', false, 'error', 'Account not found');
  end if;

  if auth.uid() is distinct from v_owner then
    return json_build_object('success', false, 'error', 'Not authorized');
  end if;

  return public.apply_reconciliation(
    v_owner, p_account_id, p_reported_balance, p_reported_at
  );
exception when others then
  return json_build_object('success', false, 'error', sqlerrm);
end;
$function$;

revoke all on function public.reconcile_bank_account(uuid, numeric, timestamptz)
  from public, anon;
grant execute on function public.reconcile_bank_account(uuid, numeric, timestamptz)
  to authenticated, service_role;

-- --------------------------------------------------- service_role entry point
-- The only function Make is allowed to call, and it deliberately carries an
-- email instead of an id: the blueprint has no idea which Money-Watch user an
-- alert belongs to, and never has to.
--
-- Every failure mode returns a distinct `status` instead of raising, so a Make
-- router can branch ("unknown_user" -> do nothing, "ambiguous_account" -> pick a
-- label) rather than showing a red run. Nothing is ever written on those paths.

create or replace function public.reconcile_bank_account_by_email(
  p_email            text,
  p_reported_balance numeric,
  p_reported_at      timestamptz default null,
  p_label            text default null
)
returns json
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_n      int;
  v_uid    uuid;
  v_n_acct int;
  v_acct   uuid;
begin
  if auth.role() is distinct from 'service_role' then
    return json_build_object(
      'success', false, 'status', 'forbidden', 'error', 'service_role required'
    );
  end if;

  if v_email = '' or v_email = 'unresolved' then
    return json_build_object(
      'success', false, 'status', 'no_email', 'error', 'p_email is empty'
    );
  end if;

  select count(*) into v_n
    from public.users
   where lower(btrim(email)) = v_email;

  if v_n = 0 then
    return json_build_object(
      'success', false, 'status', 'unknown_user',
      'error', 'No Money-Watch user with that email'
    );
  end if;

  if v_n > 1 then
    return json_build_object(
      'success', false, 'status', 'ambiguous_user',
      'error', v_n::text || ' users share that email'
    );
  end if;

  select id into v_uid
    from public.users
   where lower(btrim(email)) = v_email;

  -- A named label wins; otherwise a single active account is unambiguous.
  if p_label is not null and btrim(p_label) <> '' then
    select id into v_acct
      from public.bank_accounts
     where user_id = v_uid and label = btrim(p_label) and not is_archived;
  end if;

  if v_acct is null then
    select count(*) into v_n_acct
      from public.bank_accounts
     where user_id = v_uid and not is_archived;

    if v_n_acct = 0 then
      return json_build_object(
        'success', false, 'status', 'no_account',
        'error', 'User has no active bank account'
      );
    end if;

    if v_n_acct > 1 then
      return json_build_object(
        'success', false, 'status', 'ambiguous_account',
        'error', 'User has ' || v_n_acct::text || ' active accounts; pass p_label'
      );
    end if;

    select id into v_acct
      from public.bank_accounts
     where user_id = v_uid and not is_archived;
  end if;

  return public.apply_reconciliation(
    v_uid, v_acct, p_reported_balance, p_reported_at
  );
exception when others then
  return json_build_object('success', false, 'error', sqlerrm);
end;
$function$;

-- service_role only. No authenticated path into this function exists at all.
revoke all on function public.reconcile_bank_account_by_email(text, numeric, timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.reconcile_bank_account_by_email(text, numeric, timestamptz, text)
  to service_role;

-- The email lookup runs on every alert.
create index if not exists idx_users_email_lower
  on public.users (lower(btrim(email)));

-- Overwrite trap: CREATE OR REPLACE with a changed signature would leave the
-- old overload behind and PostgREST would keep calling it. Signatures are
-- identical above, so assert that rather than trust it.
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('reconcile_bank_account',
                       'reconcile_bank_account_by_email',
                       'apply_reconciliation');
  if v_n <> 3 then
    raise exception 'unexpected overload count %: expected exactly 3', v_n;
  end if;
end $$;
