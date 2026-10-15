-- Bank accounts + reconciliation.
--
-- Money-Watch previously treated "the number the bank said" as truth and
-- overwrote users.current_balance with it. That was wrong three ways:
--
--   1. It compared the bank's TOTAL against savings_balance and, when the
--      total was lower, silently shrank the user's vault and logged a fake
--      'vault_overdraft'. Savings often live in a different account from
--      checking, so a low checking balance destroyed an untouched goal.
--   2. It ignored the vault in the normal path too -- add_funds correctly did
--      current_balance = p_balance - v_savings while sync_bank_to_app did
--      current_balance = p_balance. Same job, different maths.
--   3. The overwrite wrote no transaction row, so when it erased a logged
--      expense there was no record that it had happened.
--
-- This migration makes the bank *authoritative but visible*: reconciliation
-- moves the ledger to the bank's figure AND writes a 'reconciliation' row so
-- the adjustment is auditable. The vault is never touched by reconciliation.

-- ---------------------------------------------------------------------------
-- 1. Per-user bank accounts
-- ---------------------------------------------------------------------------
create table if not exists public.bank_accounts (
  id               uuid primary key default extensions.uuid_generate_v4(),
  user_id          uuid not null references public.users(id) on delete cascade,

  -- What the user calls this account, e.g. 'GTBank Current'. Unique per user
  -- so reconciliation can be idempotent on (user_id, label).
  label            text not null,
  bank_name        text,

  -- The app's own figure for this account. Seeded from opening_balance, then
  -- moved by transactions tagged to this account and by reconciliations.
  ledger_balance   numeric not null default 0,

  -- The anchor the user gave us when adding the account, so the first
  -- reconciliation has something to compare against.
  opening_balance  numeric not null default 0,

  -- The bank's most recent word. Never used to mutate anything implicitly;
  -- only reconcile_bank_account() reads it.
  reported_balance numeric,
  reported_at      timestamptz,

  is_archived      boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint bank_accounts_label_key unique (user_id, label),
  -- A reported balance is a bank figure; it cannot be negative.
  constraint bank_accounts_reported_nonneg
    check (reported_balance is null or reported_balance >= 0)
);

comment on table public.bank_accounts is
  'One row per real bank account. ledger_balance is the app''s running figure; '
  'reported_balance is the bank''s last word. Drift between them is surfaced, '
  'not silently applied. The savings vault is deliberately NOT modelled here.';

create index if not exists bank_accounts_user_idx
  on public.bank_accounts (user_id) where not is_archived;

-- ---------------------------------------------------------------------------
-- 2. Allow transactions to belong to an account, and add 'reconciliation'
-- ---------------------------------------------------------------------------

-- 'reconciliation' is a correction the user can see, not a real-world
-- inflow/outflow. It must stay out of INFLOW_TYPES / OUTFLOW_TYPES in the
-- frontend or spending totals will silently change meaning.
alter table public.transactions
  drop constraint if exists transactions_type_check;

alter table public.transactions
  add constraint transactions_type_check
  check (type = any (array[
    'deposit', 'withdrawal', 'transfer',
    'vault_deposit', 'vault_withdrawal', 'vault_overdraft',
    'expense', 'reconciliation'
  ]::text[]));

alter table public.transactions
  add column if not exists account_id uuid
  references public.bank_accounts(id) on delete set null;

create index if not exists transactions_account_idx
  on public.transactions (account_id) where account_id is not null;

-- ---------------------------------------------------------------------------
-- 3. RLS on bank_accounts -- own rows only, matching the rest of the schema
-- ---------------------------------------------------------------------------
alter table public.bank_accounts enable row level security;

drop policy if exists "Users can manage their own bank accounts" on public.bank_accounts;
create policy "Users can manage their own bank accounts"
  on public.bank_accounts
  for all
  to authenticated
  using      (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Realtime so a reconciliation lands in an open dashboard immediately.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND tablename = 'bank_accounts'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.bank_accounts;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Keep updated_at honest
-- ---------------------------------------------------------------------------
create or replace function public.touch_bank_accounts_updated_at()
returns trigger
language plpgsql
set search_path = 'public', 'pg_temp'
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_touch_bank_accounts on public.bank_accounts;
create trigger trg_touch_bank_accounts
  before update on public.bank_accounts
  for each row execute function public.touch_bank_accounts_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Fix sync_bank_to_app: log the adjustment, never touch the vault
-- ---------------------------------------------------------------------------
-- Same signature so the existing make.com scenario keeps working. Behaviour
-- changes: the bank figure is recorded and applied as a *logged* correction
-- to the ledger, and savings_balance is never read or written.
create or replace function public.sync_bank_to_app(
  p_user_id uuid,
  p_parsed_amount numeric,
  p_cleared_balance numeric,
  p_type text
)
returns void
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_type text;
  v_is_debit boolean;
  v_savings numeric;
  v_tx_id uuid;
begin
  if auth.uid() is distinct from p_user_id then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  -- Map aliases onto the vocabulary transactions_type_check accepts.
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

  -- Apply the alert to the ledger. This is an incremental mutation, exactly
  -- like log_expense, so it composes with the rest of the app instead of
  -- fighting it.
  update public.users
     set current_balance = current_balance
                           + case when v_is_debit then -p_parsed_amount
                                  else p_parsed_amount end
   where id = p_user_id
  returning current_balance into v_savings;

  if v_savings is null then
    raise exception 'User not found' using errcode = 'P0002';
  end if;

  insert into public.transactions
    (user_id, type, amount, description, category, date)
  values (
    p_user_id,
    v_type,
    case when v_is_debit then -p_parsed_amount else p_parsed_amount end,
    'Bank Alert',
    'General',
    now()
  )
  returning id into v_tx_id;

  -- Keep the legacy single-account column roughly truthful without letting it
  -- drive anything. p_cleared_balance is the bank TOTAL across all accounts,
  -- so this is only meaningful while a user has exactly one account; the
  -- per-account model in bank_accounts supersedes it.
  update public.users
     set bank_balance = p_cleared_balance
   where id = p_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. reconcile_bank_account: the bank is authoritative, but visibly
-- ---------------------------------------------------------------------------
-- Drift = reported - ledger. If it is non-zero we move the ledger by exactly
-- that amount AND write a 'reconciliation' row, so the adjustment is visible
-- in the transaction list and reversible by hand. savings_balance is never
-- read or written here.
create or replace function public.reconcile_bank_account(
  p_account_id uuid,
  p_reported_balance numeric,
  p_reported_at timestamptz default null
)
returns json
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
declare
  v_user_id uuid;
  v_ledger numeric;
  v_label text;
  v_drift numeric;
  v_tx_id uuid;
  v_at timestamptz;
begin
  v_at := coalesce(p_reported_at, now());

  select user_id, ledger_balance, label
    into v_user_id, v_ledger, v_label
    from public.bank_accounts
   where id = p_account_id and not is_archived
   for update;

  if v_user_id is null then
    raise exception 'Account not found' using errcode = 'P0002';
  end if;

  if auth.uid() is distinct from v_user_id then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if p_reported_balance is null or p_reported_balance < 0 then
    raise exception 'Reported balance must be zero or greater'
      using errcode = '22023';
  end if;

  v_drift := p_reported_balance - v_ledger;

  if v_drift <> 0 then
    -- The visible part: an auditable correction, never a silent overwrite.
    insert into public.transactions
      (user_id, account_id, type, amount, description, category, date)
    values (
      v_user_id,
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
     where id = v_user_id;

    update public.bank_accounts
       set ledger_balance = ledger_balance + v_drift
     where id = p_account_id;
  end if;

  update public.bank_accounts
     set reported_balance = p_reported_balance,
         reported_at      = v_at
   where id = p_account_id;

  return json_build_object(
    'success',        true,
    'account_id',     p_account_id,
    'label',          v_label,
    'reported',       p_reported_balance,
    'previous_ledger', v_ledger,
    'drift',          v_drift,
    'reconciled',     v_drift <> 0,
    'transaction_id', v_tx_id
  );
exception when others then
  return json_build_object('success', false, 'error', sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Account CRUD. Vault is never involved in any of these.
-- ---------------------------------------------------------------------------
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
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  if p_label is null or btrim(p_label) = '' then
    raise exception 'Account label is required' using errcode = '22023';
  end if;

  insert into public.bank_accounts
    (user_id, label, bank_name, opening_balance, ledger_balance)
  values
    (auth.uid(), btrim(p_label), p_bank_name,
     coalesce(p_opening_balance, 0), coalesce(p_opening_balance, 0))
  on conflict (user_id, label) do update
      set bank_name       = excluded.bank_name,
          opening_balance = excluded.opening_balance,
          is_archived     = false
    returning id into v_id;

  return json_build_object('success', true, 'account_id', v_id);
exception when unique_violation then
  return json_build_object('success', false, 'error', 'That account label already exists');
when others then
  return json_build_object('success', false, 'error', sqlerrm);
end;
$$;

create or replace function public.remove_bank_account(p_account_id uuid)
returns json
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  update public.bank_accounts
     set is_archived = true
   where id = p_account_id
     and user_id = auth.uid()
     and not is_archived;

  if not found then
    return json_build_object('success', false, 'error', 'Account not found');
  end if;

  -- Transactions survive; only the link is dropped, so history stays intact.
  return json_build_object('success', true);
end;
$$;