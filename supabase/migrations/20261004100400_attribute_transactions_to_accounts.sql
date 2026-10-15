-- Attribute ledger transactions to a bank account.
--
-- add_bank_account established the invariant
--
--     users.current_balance = SUM(active bank_accounts.ledger_balance)
--
-- but nothing maintained it afterwards. log_expense decremented
-- users.current_balance and inserted a row with account_id = NULL, leaving
-- bank_accounts.ledger_balance untouched. So the moment a user logged an
-- expense the account panel and the dashboard disagreed again -- the exact
-- class of bug 20261004100300 was written to eliminate, and the SQL harness
-- missed it because it only ever called reconcile.
--
-- Fix: give the transaction-writing RPCs an account, and move the account's
-- ledger by the amount that actually left the main balance.
--
-- The amount deducted from the main balance is NOT always the expense total.
-- log_expense covers a shortfall from the vault, and the vault is app-internal
-- -- no bank account paid that part. So the account ledger is reduced by
-- (expense - shortfall), which for a single-account user is exact: the bank
-- account paid precisely what its own balance was reduced by.
--
-- Attribution rules:
--   p_account_id given    -> use it (must belong to the caller)
--   NULL, one active acct -> use it (the overwhelmingly common case)
--   NULL, many accounts   -> refuse, rather than silently guess. Guessing would
--                            make the panel wrong in a way nothing surfaces.
--
-- Vault transfers (vault_deposit / vault_withdrawal / vault_overdraft) are
-- internal and deliberately carry no account: no bank account moved.

create or replace function public.log_expense(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_category_id uuid,
  p_session_id uuid default null::uuid,
  p_account_id uuid default null::uuid
)
returns json
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
declare
  v_transaction_id uuid;
  v_current_balance numeric;
  v_savings_balance numeric;
  v_expense numeric;
  v_shortfall numeric := 0;
  v_from_main numeric;
  v_account uuid;
  v_active int;
begin
  if auth.uid() is distinct from p_user_id then
    return json_build_object('success', false, 'error', 'Not authorized');
  end if;

  v_expense := abs(p_amount);

  -- Resolve which bank account this expense belongs to.
  if p_account_id is not null then
    if not exists (
      select 1 from public.bank_accounts
       where id = p_account_id and user_id = p_user_id and not is_archived
    ) then
      return json_build_object('success', false, 'error', 'Account not found');
    end if;
    v_account := p_account_id;
  else
    select count(*) into v_active
      from public.bank_accounts where user_id = p_user_id and not is_archived;

    if v_active = 1 then
      select id into v_account
        from public.bank_accounts where user_id = p_user_id and not is_archived;
    elsif v_active > 1 then
      return json_build_object(
        'success', false,
        'error', 'Pick which account this expense belongs to.'
      );
    end if;
    -- v_active = 0: the user has no accounts yet, so the expense is untracked
    -- by any account. That is fine; the global ledger still moves.
  end if;

  select current_balance, savings_balance
    into v_current_balance, v_savings_balance
    from public.users where id = p_user_id
    for update;

  if v_current_balance is null then
    return json_build_object('success', false, 'error', 'User not found');
  end if;

  if v_current_balance >= v_expense then
    update public.users
    set current_balance = current_balance - v_expense
    where id = p_user_id;
    v_from_main := v_expense;
  else
    v_shortfall := v_expense - v_current_balance;

    if v_savings_balance < v_shortfall then
      return json_build_object('success', false, 'error', 'Insufficient total funds (Main + Vault).');
    end if;

    update public.users
    set current_balance = 0,
        savings_balance = savings_balance - v_shortfall
    where id = p_user_id;
    -- Only what the main balance actually paid came out of the bank.
    v_from_main := v_current_balance;
  end if;

  -- Keep the account ledger in step with the global one. A negative floor is
  -- allowed here: the account may legitimately have been overspent before
  -- anyone reconciled it, and the next reconciliation will correct it.
  if v_account is not null then
    update public.bank_accounts
    set ledger_balance = ledger_balance - v_from_main
    where id = v_account and user_id = p_user_id;
  end if;

  insert into public.transactions
    (user_id, type, amount, description, category, category_id, session_id, account_id)
  values (
    p_user_id, 'expense', -v_expense, p_description,
    coalesce((select c.name from public.user_categories c where c.id = p_category_id), 'General'),
    p_category_id,
    p_session_id,
    v_account
  )
  returning id into v_transaction_id;

  -- The vault's share of the bill. Linked to the expense so deleting or
  -- editing that expense can hand the money back. Internal, so no account.
  if v_shortfall > 0 then
    insert into public.transactions
      (user_id, type, amount, description, category, category_id, session_id, linked_to)
    values (
      p_user_id, 'vault_overdraft', -v_shortfall,
      'Vault Overdraft: Covered shortfall',
      coalesce((select c.name from public.user_categories c where c.id = p_category_id), 'General'),
      p_category_id,
      p_session_id,
      v_transaction_id
    );
  end if;

  if p_session_id is not null then
    update public.shopping_sessions
    set current_spent = coalesce(current_spent, 0) + v_expense
    where id = p_session_id and user_id = p_user_id;
  end if;

  return json_build_object('success', true, 'transaction_id', v_transaction_id);
exception
  when others then
    return json_build_object('success', false, 'error', sqlerrm);
end;
$$;

-- Deleting an expense has to hand the money back to the account it left, or
-- the panel drifts the moment a row is removed.
create or replace function public.delete_transaction(
  p_transaction_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
declare
  v_amount numeric;
  v_type text;
  v_session_id uuid;
  v_overdraft numeric;
  v_account_id uuid;
  v_main_paid numeric;
begin
  if auth.uid() is distinct from p_user_id then
    return json_build_object('success', false, 'error', 'Not authorized');
  end if;

  select t.amount, t.type, t.session_id, t.account_id
    into v_amount, v_type, v_session_id, v_account_id
    from public.transactions t
   where t.id = p_transaction_id and t.user_id = p_user_id;

  if not found then
    return json_build_object('success', false, 'error', 'Transaction not found');
  end if;

  if v_type = 'vault_overdraft' then
    return json_build_object(
      'success', false,
      'error', 'This is an automatic vault adjustment. Delete the expense that used the vault instead.'
    );
  end if;

  perform 1 from public.users where id = p_user_id for update;

  select coalesce(sum(abs(t.amount)), 0)
    into v_overdraft
    from public.transactions t
   where t.linked_to = p_transaction_id
     and t.user_id = p_user_id
     and t.type = 'vault_overdraft';

  if v_type in ('expense', 'withdrawal') then
    -- What came out of the main balance, as opposed to the vault's share.
    v_main_paid := abs(v_amount) - v_overdraft;

    update public.users
    set current_balance = current_balance + v_main_paid,
        savings_balance  = savings_balance + v_overdraft
    where id = p_user_id;

    -- Return it to the account it was taken from.
    if v_account_id is not null then
      update public.bank_accounts
      set ledger_balance = ledger_balance + v_main_paid
      where id = v_account_id and user_id = p_user_id;
    end if;

    delete from public.transactions
     where linked_to = p_transaction_id
       and user_id = p_user_id
       and type = 'vault_overdraft';

    if v_session_id is not null then
      update public.shopping_sessions
      set current_spent = greatest(coalesce(current_spent, 0) - abs(v_amount), 0)
      where id = v_session_id and user_id = p_user_id;
    end if;
  elsif v_type = 'deposit' then
    update public.users
    set current_balance = current_balance - v_amount
    where id = p_user_id;
  elsif v_type in ('vault_deposit', 'vault_withdrawal') then
    update public.users
    set current_balance = current_balance + v_amount,
        savings_balance  = savings_balance - v_amount
    where id = p_user_id;
  elsif v_type = 'reconciliation' then
    update public.users
    set current_balance = current_balance - v_amount
    where id = p_user_id;

    if v_account_id is not null then
      update public.bank_accounts
      set ledger_balance = ledger_balance - v_amount
      where id = v_account_id and user_id = p_user_id;
    end if;
  end if;

  delete from public.transactions where id = p_transaction_id and user_id = p_user_id;

  return json_build_object('success', true);
end;
$$;

-- sync_bank_to_app applies a single bank alert to a single balance. With
-- accounts in play the alert belongs to whichever account the user nominates,
-- so it takes an optional account and keeps that account's ledger in step.
create or replace function public.sync_bank_to_app(
  p_user_id uuid,
  p_parsed_amount numeric,
  p_cleared_balance numeric,
  p_type text,
  p_account_id uuid default null::uuid
)
returns void
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_type text;
  v_is_debit boolean;
  v_new_balance numeric;
  v_account uuid;
  v_active int;
  v_delta numeric;
begin
  if auth.uid() is distinct from p_user_id then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  v_type := lower(trim(coalesce(p_type, '')));
  v_type := case v_type
    when 'debit'      then 'withdrawal'
    when 'credit'     then 'deposit'
    when 'income'     then 'deposit'
    when 'expense'    then 'withdrawal'
    when 'inflow'     then 'deposit'
    when 'outflow'    then 'withdrawal'
    else v_type
  end;

  if v_type not in ('deposit', 'withdrawal') then
    raise exception 'Unsupported bank transaction type: %', coalesce(p_type, '(null)')
      using errcode = '22023';
  end if;

  v_is_debit := (v_type = 'withdrawal');
  v_delta := case when v_is_debit then -abs(p_parsed_amount) else abs(p_parsed_amount) end;

  if p_account_id is not null then
    if not exists (
      select 1 from public.bank_accounts
       where id = p_account_id and user_id = p_user_id and not is_archived
    ) then
      raise exception 'Account not found' using errcode = 'P0002';
    end if;
    v_account := p_account_id;
  else
    select count(*) into v_active
      from public.bank_accounts where user_id = p_user_id and not is_archived;
    if v_active = 1 then
      select id into v_account
        from public.bank_accounts where user_id = p_user_id and not is_archived;
    end if;
  end if;

  -- Incremental, exactly like log_expense, so it composes with the app instead
  -- of rescaling the balance to the bank's total. savings_balance is untouched:
  -- a bank alert says nothing about the vault.
  update public.users
     set current_balance = current_balance + v_delta
   where id = p_user_id
  returning current_balance into v_new_balance;

  if v_new_balance is null then
    raise exception 'User not found' using errcode = 'P0002';
  end if;

  if v_account is not null then
    update public.bank_accounts
    set ledger_balance = ledger_balance + v_delta
    where id = v_account and user_id = p_user_id;
  end if;

  insert into public.transactions
    (user_id, account_id, type, amount, description, category, date)
  values (
    p_user_id,
    v_account,
    v_type,
    v_delta,
    'Bank Alert',
    'General',
    now()
  );

  -- Legacy single-account mirror. p_cleared_balance is the bank TOTAL across
  -- all accounts, so this is only meaningful for a one-account user. Kept for
  -- compatibility; bank_accounts supersedes it.
  update public.users
     set bank_balance = p_cleared_balance
   where id = p_user_id;
end;
$$;

grant execute on function public.log_expense(uuid, numeric, text, uuid, uuid, uuid) to authenticated;
grant execute on function public.sync_bank_to_app(uuid, numeric, numeric, text, uuid) to authenticated;
revoke execute on function public.log_expense(uuid, numeric, text, uuid, uuid, uuid) from public, anon;
revoke execute on function public.sync_bank_to_app(uuid, numeric, numeric, text, uuid) from public, anon;