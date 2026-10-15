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
 *     'vault_deposit','vault_withdrawal','vault_overdraft','expense'
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
 *   - unused:  'transfer'
 */
export type TransactionType =
  | 'deposit'
  | 'withdrawal'
  | 'transfer'
  | 'vault_deposit'
  | 'vault_withdrawal'
  | 'vault_overdraft'
  | 'expense';

export const OUTFLOW_TYPES: readonly TransactionType[] = ['expense', 'withdrawal'];
export const INFLOW_TYPES: readonly TransactionType[] = ['deposit'];
export const INTERNAL_TRANSFER_TYPES: readonly TransactionType[] = [
  'vault_deposit',
  'vault_withdrawal',
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
  /** Bank-reported balance, maintained by the sync_* RPCs. */
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
