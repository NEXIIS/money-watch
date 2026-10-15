// Live schema types for Money-Watch.
//
// These mirror the deployed Supabase schema. Verified against the live
// database; the CHECK constraint on transactions.type is the authority for
// TransactionType.

/**
 * The exact set permitted by `transactions_type_check`:
 *
 *   CHECK ((type = ANY (ARRAY[
 *     'deposit','withdrawal','transfer',
 *     'vault_deposit','vault_withdrawal','vault_overdraft','expense',
 *     'reconciliation'
 *   ])))
 *
 * Note there is no 'credit' or 'debit' — money in is 'deposit', money out is
 * either 'expense' (manually logged) or 'withdrawal' (bank-synced).
 *
 * Semantics for stats and balance logic:
 *   - outflow  (reduces main balance): 'expense', 'withdrawal'
 *   - inflow   (increases main balance): 'deposit'
 *   - internal (moves between the user's own wallets, not spending):
 *              'vault_deposit', 'vault_withdrawal'
 *   - special: 'vault_overdraft' — shortfall covered from savings
 *   - special: 'reconciliation' — a visible correction that moved the ledger to
 *              match a bank's reported balance. Deliberately NOT inflow or
 *              outflow: the drift was money the bank already had, so counting
 *              it as income or spending would distort totals.
 *   - unused:  'transfer'
 */
export type TransactionType =
  | 'deposit'
  | 'withdrawal'
  | 'transfer'
  | 'vault_deposit'
  | 'vault_withdrawal'
  | 'vault_overdraft'
  | 'expense'
  | 'reconciliation';

export const OUTFLOW_TYPES: readonly TransactionType[] = ['expense', 'withdrawal'];
export const INFLOW_TYPES: readonly TransactionType[] = ['deposit'];
export const INTERNAL_TRANSFER_TYPES: readonly TransactionType[] = [
  'vault_deposit',
  'vault_withdrawal',
];
/**
 * Rows that move money but are not real-world spending. Rendered neutrally so
 * a vault shuffle or a bank reconciliation never reads as income or a purchase.
 */
export const NEUTRAL_TYPES: readonly TransactionType[] = [
  ...INTERNAL_TRANSFER_TYPES,
  'vault_overdraft',
  'reconciliation',
];

export interface UserWallet {
  id: string;
  email: string;
  /** Live column; the app currently reads/writes `username` instead. */
  name: string | null;
  current_balance: number;
  savings_balance: number;
  created_at: string;
  username: string | null;
  /**
   * Legacy single-account figure, written by `sync_bank_to_app`. Only
   * meaningful while a user has exactly one account — it is the bank's total
   * across ALL accounts, so it cannot be compared per-account. Superseded by
   * `BankAccount.reported_balance`; do not build new UI on this.
   */
  bank_balance: number;
  /** Legacy leftover, unused by the app. */
  balance: number | null;
}

export interface Transaction {
  id: string;
  user_id: string;
  description: string;
  /**
   * Sign convention: outflows are stored negative, inflows positive.
   * Internal vault transfers are signed by direction. Prefer deriving the
   * bucket from `type` rather than from the sign.
   */
  amount: number;
  type: TransactionType;
  /** Legacy text category. `category_id` is authoritative for the chart. */
  category: string;
  category_id: string | null;
  session_id: string | null;
  /**
   * Which bank account this row belongs to. NULL on rows created before
   * multi-account support, and on vault transfers (internal, not a bank move).
   */
  account_id: string | null;
  /**
   * A `vault_overdraft` row points at the `expense` it covered. Lets edits and
   * deletes hand the vault's share back to `savings_balance`. NULL on
   * everything else, and on overdraft rows that predate the column.
   */
  linked_to: string | null;
  /** Business date. Backfilled imports write this, not `created_at`. */
  date: string;
  created_at: string;
}

export interface ShoppingSession {
  id: string;
  user_id: string;
  name: string;
  budget_limit: number;
  current_spent: number;
  status: 'active' | 'completed';
  started_at: string;
  ended_at: string | null;
}

export interface Notification {
  id: string;
  user_id: string;
  type: string;
  title: string;
  message: string;
  is_read: boolean;
  created_at: string;
}

export interface UserCategory {
  id: string;
  name: string;
  color: string;
  /** Live column; defaults to 'both'. Unused by the app. */
  type: string | null;
}

/**
 * One real bank account, added by
 * `20261004100000_bank_accounts_and_reconciliation.sql`.
 *
 * `ledger_balance` is the app's running figure for this account.
 * `reported_balance` is the bank's most recent word. Drift between them is
 * resolved by `reconcile_bank_account()`, which moves the ledger AND writes a
 * visible `reconciliation` transaction — the bank is authoritative, but never
 * silently.
 *
 * The savings vault is deliberately NOT modelled here: reconciliation must
 * never touch `savings_balance`.
 */
export interface BankAccount {
  id: string;
  user_id: string;
  /** User-supplied name, unique per user. e.g. 'GTBank Current'. */
  label: string;
  bank_name: string | null;
  /** The app's own figure. Moves with tagged transactions and reconciliations. */
  ledger_balance: number;
  /** Anchor supplied when the account was added, for the first comparison. */
  opening_balance: number;
  /** The bank's last reported figure, or null if never reconciled. */
  reported_balance: number | null;
  reported_at: string | null;
  is_archived: boolean;
  created_at: string;
  updated_at: string;
}

/** Result of `reconcile_bank_account()`. */
export interface ReconcileResult {
  success: boolean;
  error?: string;
  account_id?: string;
  label?: string;
  reported?: number;
  previous_ledger?: number;
  /** reported - previous_ledger. Non-zero means the ledger was moved. */
  drift?: number;
  reconciled?: boolean;
  transaction_id?: string | null;
}
