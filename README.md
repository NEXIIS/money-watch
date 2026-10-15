# Money-Watch

A real-time personal finance dashboard for tracking spending, managing a savings
vault, and staying on top of budget sessions.

## Stack

React 18, TypeScript, Vite, Tailwind CSS, Supabase (Postgres + GoTrue + Realtime).

## Setup

```bash
npm install
cp .env.example .env      # fill in VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
npm run dev
```

The Supabase project must be linked for migrations:

```bash
npx supabase link --project-ref <ref>
npx supabase migration up --linked
```

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Vite dev server |
| `npm run build` | Production build |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run lint` | ESLint |
| `npm test` | Vitest (threads pool) |

## Architecture

See [AGENTS.md](./AGENTS.md) for the full database schema, RPC contracts, and
key logic rules. It is the canonical reference for AI agents working in this
repo.

### Data model at a glance

- **users** — one row per auth user. Three balances: `current_balance` (spendable),
  `savings_balance` (vault), `bank_balance` (last known bank figure).
- **transactions** — the ledger. `type` is constrained by `transactions_type_check`
  to: `deposit`, `withdrawal`, `transfer`, `vault_deposit`, `vault_withdrawal`,
  `vault_overdraft`, `expense`. Money in is `deposit`; money out is `expense`
  (manual) or `withdrawal` (bank-synced). Vault transfers are internal moves.
  `linked_to` ties a `vault_overdraft` row to the expense it covered, so edits
  and deletes can reverse the vault share correctly.
- **shopping_sessions** — budgeted shopping runs with `current_spent` tracking.
- **notifications** — in-app alerts, delivered live via Realtime.
- **user_settings** — per-user limits and savings goals (schema only; no UI writes to it yet).
- **user_categories** — user-defined spending categories, seeded with 8 defaults
  on signup via the `create_default_categories` trigger.

### Money invariants

All balance mutations go through SECURITY DEFINER RPCs that verify
`auth.uid() = p_user_id`. The vault overdraft is the subtle one: when an expense
exceeds the main balance, `log_expense` deducts the shortfall from savings and
writes a linked `vault_overdraft` row. `edit_transaction` and `delete_transaction`
both reverse that split correctly — the vault share returns to savings and the
overdraft row is removed. An unaffordable edit is rejected atomically (nothing
is written).