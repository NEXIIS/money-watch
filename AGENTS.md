# Money-Watch — Agent Context

This file is the canonical context for AI agents working in this repo.
Keep it accurate — if code and docs disagree, update this file in the same PR.

## Project Overview
* **App Name:** Money-Watch
* **Core Stack:** React 18, TypeScript, Vite, Tailwind CSS, Supabase.
* **Primary Goal:** A real-time financial dashboard to track spending, set dynamic limits, and manage savings goals.

## Explicit Database Schema (Supabase)
This is the single source of truth for the database architecture. Do not assume or hallucinate columns outside of this list. Migrations live in `supabase/migrations/`.

### 1. `users` Table
* `id` (uuid, primary key)
* `email` (text)
* `name` (text, nullable)
* `username` (text, nullable)
* `current_balance` (numeric, default 0)
* `savings_balance` (numeric, default 0)
* `bank_balance` (numeric, default 0)

### 2. `user_settings` Table
* `id` (uuid, primary key)
* `user_id` (uuid, foreign key to users.id, NOT NULL)
* `daily_limit` (numeric, nullable)
* `weekly_limit` (numeric, nullable)
* `monthly_limit` (numeric, nullable)
* `daily_savings_goal` (numeric, nullable)
* `weekly_savings_goal` (numeric, nullable)
* `monthly_savings_goal` (numeric, nullable)
* `created_at` (timestamptz, default now())
* `updated_at` (timestamptz, default now())
* `phone_number` (text, nullable) — legacy leftover, unused by the app
* `balance` (numeric, nullable) — legacy leftover, unused by the app

### 3. `transactions` Table
* `id` (uuid, primary key)
* `user_id` (uuid, foreign key to users.id)
* `amount` (numeric)
* `category` (text)
* `description` (text, nullable)
* `date` (timestamptz, default now())
* `created_at` (timestamptz, default now())
* `session_id` (uuid, nullable, foreign key to shopping_sessions.id)
* `category_id` (uuid, nullable, foreign key to user_categories.id)
* `type` (text, nullable, default `'expense'`) — guarded by `transactions_type_check`,
  which permits exactly: `deposit`, `withdrawal`, `transfer`, `vault_deposit`,
  `vault_withdrawal`, `vault_overdraft`, `expense`. There is no `'credit'` or
  `'debit'` value — money in is `'deposit'`, money out is `'expense'` (manual)
  or `'withdrawal'` (bank-synced). `sync_bank_to_app` normalises aliases
  (`credit`→`deposit`, `debit`→`withdrawal`) and rejects anything else.
  (The default used to be the invalid `'debit'`; fixed by
  `20261004090200_fill_category_id.sql`.)
* `linked_to` (uuid, nullable, FK to `transactions.id`, `ON DELETE SET NULL`) —
  added by `20261004090100_link_vault_overdraft.sql`. A `vault_overdraft` row
  points at the `expense` it covered, so edits/deletes can hand the vault's share
  back to `savings_balance`. Overdraft rows are **not** independently
  editable/deletable; the RPCs reject that. The trigger
  `trg_fill_transaction_category_id` (`BEFORE INSERT`) fills `category_id` from
  the legacy `category` text when it is NULL, so bank-synced rows are never
  "Uncategorized" in the chart.
* `date` is the business date (backdated imports write it); `created_at` is the
  insertion timestamp. The UI sorts by `date`, not `created_at`.
* `shopping_sessions` is the only session table (`spending_sessions` was dropped
  by `20260219175142_unify_sessions.sql`). `transactions.session_id` →
  `shopping_sessions(id) ON DELETE SET NULL`.
* `category` is a legacy text column (defaults to `'General'`);
  `category_id` → `user_categories(id)` is authoritative for the chart.

> **Stats rule: bucket by `type`, never by sign.** `QuickStats` and
> `ExpenseChart` use the `OUTFLOW_TYPES` / `INFLOW_TYPES` sets in
> `src/types/index.ts`. Outflow = `expense` + `withdrawal`; inflow = `deposit`;
> `vault_*` transfers are internal wallet moves and are excluded (counted only
> in the "internal transfers" footnote). QuickStats feeds from
> `chartTransactions` (100 rows), not `fetchTransactions` (5 rows).

### 4. `notifications` Table
* `id` (uuid, primary key)
* `user_id` (uuid, foreign key to users.id)
* `type` (text, NOT NULL - e.g., 'alert', 'info', 'transfer')
* `title` (text)
* `message` (text)
* `is_read` (boolean, default false)
* `created_at` (timestamptz, default now())

> Note: `useWallet.ts` also queries `shopping_sessions` and `user_categories` tables and uses RPCs (`move_to_vault`, `withdraw_from_vault`, `log_expense`, `edit_transaction`, `delete_transaction`, `create_notification`). Consult `supabase/migrations/` for their definitions.
>
> **Realtime publication:** `supabase_realtime` contains `transactions`,
> `shopping_sessions`, `notifications`, and `users` (the latter two added by
> `20261004090000_add_realtime_publication.sql`). If you subscribe to a new
> table in `useWallet`, you must `alter publication supabase_realtime add table`
> or the subscription will silently never fire.
>
> **Two balance models coexist — don't mix them.** The app's own RPCs
> (`move_to_vault`, `withdraw_from_vault`, `log_expense`, `edit_transaction`,
> `delete_transaction`) mutate `current_balance` incrementally. The bank-sync
> RPCs (`sync_bank_to_app`, the 5-arg `add_funds`/`subtract_funds`) instead
> **overwrite** `current_balance` from the bank's cleared balance
> (`p_balance - savings_balance`) and write `bank_balance`. Mixing them in one
> flow double-counts. None of the bank-sync RPCs are called by the frontend
> yet; treat them as the not-yet-wired "bank alerts" path.
>
> RLS is authenticated-user-only. Anon demo policies and the `user_settings` `Public Access` / `Public Update` policies were removed by `20260219175139_remove_anon_demo_policies.sql` and `20260219175138_secure_user_settings.sql` — do not reintroduce them.
>
> **Migration state.** The linked project was originally created outside this
> pipeline, but `supabase_migrations.schema_migrations` is now in sync: all 15
> files in `supabase/migrations/` are recorded and applied. `supabase migration
> up --linked` works, and it wraps each file in a transaction that rolls back on
> error — which makes a deliberately-raising migration a safe, zero-pollution
> way to test write paths. Still verify against the live schema before writing a
> new migration (`supabase db pull`, or the supabase MCP `execute_sql`).

## Key Logic & UX Rules
* **Show the business date, not the insert time.** `TransactionList` renders
  `tx.date || tx.created_at` for both the relative label and the exact-time
  detail. Backdated imports write `date`, so using `created_at` made old rows
  read "Today".
* **Bucket by `type` in the UI too, not just in stats.** `TransactionList`
  colours and arrows by `INFLOW_TYPES` / `OUTFLOW_TYPES` and renders internal
  transfers (`vault_deposit`, `vault_withdrawal`, `vault_overdraft`,
  `transfer`) neutrally. Do not reintroduce `amount > 0` sign checks — a
  `vault_withdrawal` is positive but is not income.
* **Edit/delete gating in `TransactionList`:** Edit is offered for `expense`,
  `withdrawal`, and `deposit` only. Delete is offered for those plus the
  `vault_*` transfers (the RPC reverses both wallets). `vault_overdraft`
  offers neither — it is the vault's half of an expense, and the RPCs reject
  operating on it directly. The client sends the amount magnitude;
  `edit_transaction` normalises the sign from the row's `type`.
* **Only report success that actually happened.** `endSession` returns a
  `boolean` and swallows its own errors, so `App.handleEndSession` gates the
  toast and the overlay close on `true`. `handleLogExpense` closes the modal
  and refetches only on success, leaving it open so `LogExpenseModal` can show
  its inline error.
* **Notifications `markAsRead`:** Optimistic update in local state (`is_read: true`), immediate Supabase update, and revert to `is_read: false` on error. The notification **stays in the list** when read — it is not removed. (The previously documented 40-second delayed save is **no longer in the code** — if you reintroduce it, flush on `beforeunload`/visibility change so intent isn't lost.) Covered by `src/test/useWallet.test.ts`.
* **Dynamic Limits — NOT YET BUILT (RPCs fixed):** `user_settings` is now per-user and RLS-locked, every new signup gets a settings row via `handle_new_user`. The daily/weekly/monthly limit and savings-goal columns exist, but **no UI writes to them and no code reads them**. `SettingsView.tsx` currently only edits `username` and signs out. The backing RPCs now count outflows only (`type IN ('expense','withdrawal')`) — they were summing signed amounts and netting deposits against spending. Treat the UI as pending, not the RPCs.
* **Time-Travel Math — NOT YET BUILT:** daily/weekly/monthly bucketing of transactions against `user_settings` limits is documented intent, not implemented. Do not assume it runs.
* **Known gaps:** there is no UI to add funds (new users start at ₦0 and every
  action is blocked), and no category CRUD despite `LogExpenseModal` telling the
  user to "Create one first if empty!". Transaction history is capped at 5 rows
  in the list and 100 for the chart; session history at 3.

## Important Notes for AI Assistants
* Always refer to the app as **Money-Watch**, not "FinTrack" or a generic fintech app.
* Respect the existing Tailwind styling and Lucide icon usage when generating new UI components.
* Ensure all new state management or database queries rigidly account for the user's specific UUID via Supabase Auth.
* Verify changes with `npm run typecheck`, `npm run lint`, and `npm test` before
  claiming done. There is no Playwright suite in the repo; for anything touching
  the database, smoke-test against the linked project (a deliberately-raising
  migration is a zero-pollution way to exercise write paths — see "Migration
  state" above).
