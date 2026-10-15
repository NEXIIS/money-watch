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
* `type` (text, nullable, default `'debit'`) — guarded by `transactions_type_check`,
  which permits exactly: `deposit`, `withdrawal`, `transfer`, `vault_deposit`,
  `vault_withdrawal`, `vault_overdraft`, `expense`. There is no `'credit'` or
  `'debit'` value — money in is `'deposit'`, money out is `'expense'` (manual)
  or `'withdrawal'` (bank-synced). `sync_bank_to_app` normalises aliases
  (`credit`→`deposit`, `debit`→`withdrawal`) and rejects anything else.
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
> RLS is authenticated-user-only. Anon demo policies and the `user_settings` `Public Access` / `Public Update` policies were removed by `20260219175139_remove_anon_demo_policies.sql` and `20260219175138_secure_user_settings.sql` — do not reintroduce them.
>
> **⚠️ Migration files are NOT authoritative.** The linked project's schema was created outside this repo's migration pipeline; `supabase_migrations.schema_migrations` was empty until `supabase migration repair` was run to backfill the first two. The live database additionally has `users.name`, `users.balance`, `transactions.date`, `transactions.category`, and RPC bodies that differ from these files. Before writing a new migration, inspect the live schema (supabase MCP `execute_sql`, or `supabase db pull`) and prefer `supabase db pull` to reconcile. Do not assume a file in this folder describes what is actually deployed.

## Key Logic & UX Rules
* **Notifications `markAsRead`:** Optimistic update in local state (`is_read: true`), immediate Supabase update, and revert to `is_read: false` on error. The notification **stays in the list** when read — it is not removed. (The previously documented 40-second delayed save is **no longer in the code** — if you reintroduce it, flush on `beforeunload`/visibility change so intent isn't lost.) Covered by `src/test/useWallet.test.ts`.
* **Dynamic Limits — NOT YET BUILT:** `user_settings` is now per-user and RLS-locked (`20260219175138_secure_user_settings.sql`) and carries the daily/weekly/monthly limit and savings-goal columns, but **no UI writes to it and no code reads it**. `SettingsView.tsx` currently only edits `username` and signs out. Treat this as a pending feature, not existing behavior.
* **Time-Travel Math — NOT YET BUILT:** daily/weekly/monthly bucketing of transactions against `user_settings` limits is documented intent, not implemented. Do not assume it runs.

## Important Notes for AI Assistants
* Always refer to the app as **Money-Watch**, not "FinTrack" or a generic fintech app.
* Respect the existing Tailwind styling and Lucide icon usage when generating new UI components.
* Ensure all new state management or database queries rigidly account for the user's specific UUID via Supabase Auth.
* Verify changes with `npm run typecheck`, `npm run lint`, and a Playwright smoke test before claiming done.
