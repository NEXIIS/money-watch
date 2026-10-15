-- Make edit_transaction and delete_transaction understand 'reconciliation'.
--
-- Both RPCs were written before the type existed, and both would have handled
-- it wrongly:
--
--   edit_transaction: 'reconciliation' falls into the catch-all
--     `ELSIF v_type NOT IN ('vault_deposit','vault_withdrawal')` branch, which
--     happily rewrites the amount. But that number is supposed to be whatever
--     the bank said -- hand-editing it means the ledger no longer matches any
--     reported figure, and there is no way to tell how it got there.
--
--   delete_transaction: 'reconciliation' matches no branch at all, so the row
--     is deleted while the balance adjustment it made stays applied. The
--     transaction vanishes but the money does not come back, leaving the ledger
--     silently out of step with its own history.
--
-- Neither RPC touched bank_accounts.ledger_balance either, so any edit or
-- delete would leave the per-account ledger disagreeing with the transactions
-- that make it up.
--
-- Fix: reject edits (re-reconcile instead, which is the only legitimate source
-- of the figure), and make deletes fully reversible.

create or replace function public.edit_transaction(
  p_transaction_id uuid,
  p_user_id uuid,
  p_new_amount numeric,
  p_new_description text,
  p_new_category text
)
returns json
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
declare
  v_old_amount numeric;
  v_type text;
  v_session_id uuid;
  v_old_category_id uuid;
  v_final_new_amount numeric;
  v_category_id uuid;
  v_main numeric;
  v_savings numeric;
  v_overdraft numeric;
  v_main_after numeric;
  v_savings_after numeric;
  v_deduct numeric;
  v_new_shortfall numeric;
begin
  if auth.uid() is distinct from p_user_id then
    return json_build_object('success', false, 'error', 'Not authorized');
  end if;

  select t.amount, t.type, t.session_id, t.category_id
    into v_old_amount, v_type, v_session_id, v_old_category_id
    from public.transactions t
   where t.id = p_transaction_id and t.user_id = p_user_id;

  if not found then
    return json_build_object('success', false, 'error', 'Transaction not found');
  end if;

  if v_type = 'vault_overdraft' then
    return json_build_object(
      'success', false,
      'error', 'This is an automatic vault adjustment. Edit the expense that used the vault instead.'
    );
  end if;

  -- The amount on a reconciliation is the bank's figure, not the user's
  -- typing. Re-reconciling with the correct number is the only honest way to
  -- change it, and it leaves its own audit row.
  if v_type = 'reconciliation' then
    return json_build_object(
      'success', false,
      'error', 'This row records what your bank reported. Reconcile the account again with the correct figure.'
    );
  end if;

  if p_new_amount is null or abs(p_new_amount) <= 0 then
    return json_build_object('success', false, 'error', 'Amount must be greater than zero');
  end if;

  -- Normalise the sign from the type, not from what the client sent.
  if v_type in ('expense', 'withdrawal') then
    v_final_new_amount := -abs(p_new_amount);
  elsif v_type = 'deposit' then
    v_final_new_amount := abs(p_new_amount);
  else
    v_final_new_amount := p_new_amount;
  end if;

  -- Only accept a category id that actually belongs to this user.
  if p_new_category ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     and exists (
       select 1 from public.user_categories c
        where c.id = p_new_category::uuid and c.user_id = p_user_id
     )
  then
    v_category_id := p_new_category::uuid;
  end if;

  select u.current_balance, u.savings_balance
    into v_main, v_savings
    from public.users u
   where u.id = p_user_id
   for update;

  if v_main is null then
    return json_build_object('success', false, 'error', 'User not found');
  end if;

  if v_type in ('expense', 'withdrawal') then
    select coalesce(sum(abs(t.amount)), 0)
      into v_overdraft
      from public.transactions t
     where t.linked_to = p_transaction_id
       and t.user_id = p_user_id
       and t.type = 'vault_overdraft';

    -- Balances as if the old expense had never happened, then check the new
    -- amount is affordable before writing anything.
    v_main_after    := v_main + abs(v_old_amount) - v_overdraft;
    v_savings_after := v_savings + v_overdraft;
    v_deduct        := least(abs(v_final_new_amount), v_main_after);
    v_new_shortfall := abs(v_final_new_amount) - v_deduct;

    if v_new_shortfall > 0 and v_savings_after < v_new_shortfall then
      return json_build_object('success', false, 'error', 'Insufficient total funds (Main + Vault).');
    end if;

    update public.users
    set current_balance = v_main_after - v_deduct,
        savings_balance  = v_savings_after - v_new_shortfall
    where id = p_user_id;

    delete from public.transactions
     where linked_to = p_transaction_id
       and user_id = p_user_id
       and type = 'vault_overdraft';

    if v_new_shortfall > 0 then
      insert into public.transactions
        (user_id, type, amount, description, category, category_id, session_id, linked_to)
      values (
        p_user_id, 'vault_overdraft', -v_new_shortfall,
        'Vault Overdraft: Covered shortfall',
        coalesce(
          (select c.name from public.user_categories c
            where c.id = coalesce(v_category_id, v_old_category_id)),
          'General'
        ),
        coalesce(v_category_id, v_old_category_id),
        v_session_id,
        p_transaction_id
      );
    end if;
  elsif v_type not in ('vault_deposit', 'vault_withdrawal') then
    -- Deposits and anything else that moves the main balance.
    update public.users
    set current_balance = current_balance - v_old_amount + v_final_new_amount
    where id = p_user_id;
  end if;

  update public.transactions
  set amount = v_final_new_amount,
      description = p_new_description,
      category_id = coalesce(v_category_id, v_old_category_id),
      category = coalesce(
        (select c.name from public.user_categories c
          where c.id = coalesce(v_category_id, v_old_category_id)),
        category
      )
   where id = p_transaction_id
     and user_id = p_user_id;

  if v_session_id is not null and v_type in ('expense', 'withdrawal') then
    update public.shopping_sessions
    set current_spent = greatest(
      coalesce(current_spent, 0) - abs(v_old_amount) + abs(v_final_new_amount), 0
    )
    where id = v_session_id and user_id = p_user_id;
  end if;

  return json_build_object('success', true);
end;
$$;

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

  -- Overdraft rows are the vault's half of an expense. Deleting one on its
  -- own would take money out of the vault with nothing to give back.
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
    -- Give back what came out of the main balance and what the vault covered.
    update public.users
    set current_balance = current_balance + abs(v_amount) - v_overdraft,
        savings_balance  = savings_balance + v_overdraft
    where id = p_user_id;

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
    -- Reverse the internal transfer so the two wallets stay consistent.
    update public.users
    set current_balance = current_balance + v_amount,
        savings_balance  = savings_balance - v_amount
    where id = p_user_id;
  elsif v_type = 'reconciliation' then
    -- Undo the correction. Previously this type matched no branch, so the row
    -- was deleted while its balance adjustment stayed applied -- the ledger
    -- drifted away from its own history with nothing to show for it.
    update public.users
    set current_balance = current_balance - v_amount
    where id = p_user_id;

    -- Keep the per-account ledger consistent with the transactions under it.
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