-- Make add_bank_account keep the global ledger in step with the accounts.
--
-- Bug found by browser-testing the new panel: adding an account seeded
-- bank_accounts.ledger_balance but never touched users.current_balance. The two
-- are two representations of the same money, so they diverged immediately. On a
-- fresh account the symptom was stark -- the panel read "App ledger ₦43,500"
-- while the dashboard read ₦-6,500, a divergence of exactly the 50,000 opening
-- balance. Reconciling then moved the global ledger by the drift alone, so the
-- two figures never converged.
--
-- The SQL harness missed this because it set users.current_balance directly
-- rather than going through add_bank_account.
--
-- Model, matching "the bank is the guiding light":
--
--   first account  -> the opening balance IS your tracked money, so adopt it:
--                     current_balance := p_opening_balance
--   later accounts -> genuinely additional money at another bank:
--                     current_balance := current_balance + p_opening_balance
--
-- After this, users.current_balance equals the sum of the active accounts'
-- ledger_balance, so a reconcile drift of zero really does mean "in sync".
--
-- Note the opening balance is the non-vault (checking) figure. savings_balance
-- is app-internal and is never seeded from a bank account.

create or replace function public.add_bank_account(
  p_label text,
  p_opening_balance numeric default 0,
  p_bank_name text default null
)
returns json
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_id        uuid;
  v_opening   numeric;
  v_existing  int;
  v_inserted  boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if p_label is null or btrim(p_label) = '' then
    raise exception 'Account label is required' using errcode = '22023';
  end if;

  v_opening := coalesce(p_opening_balance, 0);

  if v_opening < 0 then
    raise exception 'Opening balance cannot be negative' using errcode = '22023';
  end if;

  select count(*) into v_existing
    from public.bank_accounts
   where user_id = auth.uid() and not is_archived;

  -- Lock the user row so two concurrent adds cannot both read v_existing = 0
  -- and each adopt, wiping the first account's contribution.
  perform 1 from public.users where id = auth.uid() for update;

  insert into public.bank_accounts
    (user_id, label, bank_name, opening_balance, ledger_balance)
  values
    (auth.uid(), btrim(p_label), p_bank_name, v_opening, v_opening)
  on conflict (user_id, label) do update
      set bank_name       = excluded.bank_name,
          is_archived     = false,
          -- Re-declaring an existing label restates its anchor, but the money
          -- is already in the global ledger, so leave both balances alone.
          -- Only the reported figures are refreshed, and only when known.
          opening_balance = case
            when public.bank_accounts.reported_balance is null
              then excluded.opening_balance
            else public.bank_accounts.opening_balance
          end,
          ledger_balance = public.bank_accounts.ledger_balance
    returning id, (xmax = 0) into v_id, v_inserted;

  -- Only a genuinely new account moves the global ledger.
  if v_inserted then
    if v_existing = 0 then
      update public.users
         set current_balance = v_opening
       where id = auth.uid();
    else
      update public.users
         set current_balance = current_balance + v_opening
       where id = auth.uid();
    end if;
  end if;

  return json_build_object(
    'success',    true,
    'account_id', v_id,
    'created',    v_inserted
  );
exception when others then
  return json_build_object('success', false, 'error', sqlerrm);
end;
$$;

-- reconcile_bank_account assumed the account ledger and the global ledger were
-- in step, and moved both by the same drift. That is only true if the opening
-- balance reached the global ledger, which it previously did not. Re-assert the
-- invariant defensively so a drifted account cannot silently move money twice:
-- the account's own ledger is the authority for the drift, and the global
-- ledger follows it by exactly the same amount. No change needed to the math,
-- but document the dependency at the call site.
comment on function public.reconcile_bank_account(uuid, numeric, timestamptz) is
  'Moves the global ledger to the bank''s figure and writes a visible '
  'reconciliation row. Requires add_bank_account to have seeded '
  'users.current_balance from the opening balance, so that '
  'users.current_balance = sum(active bank_accounts.ledger_balance). '
  'savings_balance is never read or written here.';