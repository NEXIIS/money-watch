# Make.com → Money-Watch migration checklist

## What changed (your old scenario → new scenario)

| Old (v1) | New (v2) |
|---|---|
| `sync_bank_to_app` with hardcoded `p_user_id: "cff8115a-..."` | `reconcile_bank_account` with per-user `p_account_id` |
| `p_cleared_balance` overwrote `current_balance` and silently destroyed the vault when the bank total dropped | `p_reported_balance` only: drift = reported - ledger, ledger moves by exactly drift, a visible `reconciliation` row is written, vault untouched |
| Gmail filter `from:FirstBank subject:("Debit" OR "Credit")` | `from:(firstbank.com OR gtbank.com OR uba-group.com OR accessbankplc.com OR zenithbank.com) subject:("Debit" OR "Credit" OR "Alert")` |
| Parser regex `Cleared Balance` only | Also matches `Available Bal`, `Avl Bal`, `Ledger Balance` — different banks, same word |
| Route stops when regex fails (`continueWhenNoRes: false`) | Same, but the broader regex catches the actual formats Nigerian banks send |

## How it works now (the invariant)

```
users.current_balance  ==  SUM(active bank_accounts.ledger_balance)
```

Every time a Gmail alert fires:
1. Parser extracts the **bank's cleared/available balance** (`$2`)
2. Lookup the user's `bank_accounts` row (label = "Primary" or their chosen label)
3. Call `reconcile_bank_account(p_account_id, p_reported_balance)`

That RPC:
- `drift = p_reported_balance - ledger_balance`
- If `drift ≠ 0`: writes a `reconciliation` row for exactly `drift`, adds it to `users.current_balance` **and** to `bank_accounts.ledger_balance`
- `savings_balance` is **never** read or written

So the panel and dashboard always agree — `divergence = 0` is a hard invariant enforced by 4 migrations.

## How multi-user works without hardcoded `p_user_id`

The **Gmail connection label** is your multiplex key:

- You (gs35421gamer@gmail.com) → connection `5184148`
- Friend A → their own google-email connection in Make
- Friend B → their own...

Each connection **has its own scenario run**. The Supabase lookup is scoped to the account that triggered the alert:

```
GET /rest/v1/bank_accounts?label=eq.Primary&select=id
  -> Authorization: Bearer <service_role>
  -> appends: &user_id=eq.{{43.__IMTCONN__}}   (make.com injects the connection's user_id)
```

Your service key (in connection 5259937) calls the RPC; `auth.uid()` inside the RPC sees the correct user because the Supabase client is impersonating the webhook caller.

## Files

| File | Purpose |
|---|---|
| `supabase/docs/make_scenario.blueprint.json` | Import this in Make: Scenarios → ⋮ → Import blueprint. Re-bind __IMTCONN__ to **your** Gmail + Supabase connections. |
| `supabase/migrations/20261004100000..100500` | The 6 migrations that built the invariant. Run `npx supabase migration up --linked` on the linked project before first live alert. |

## Smoke test (one run, no money moved)

```bash
# In Supabase SQL editor (your real user):
SELECT id, label, ledger_balance, reported_balance
FROM bank_accounts
WHERE user_id = 'ffd354a7-08cd-4d09-8c4b-1318afa38970'::uuid;
```

Then fire one alert (you can trigger it manually: forward a FirstBank "Debit" email to your gs35421gamer@gmail.com inbox). Watch the dashboard:

- "Available Balance" should equal the new `ledger_balance`
- A `reconciliation` row appears in Recent Transactions, labelled "Reconciled with Primary: ±₦..."
- Savings Vault stays ₦9,000

## What to NOT do

- **Don't** keep calling `sync_bank_to_app` with `p_cleared_balance` — that's the overwrite path.
- **Don't** hardcode any `p_user_id` — the account already belongs to the right user.
- **Don't** edit the `reconciliation` row (the UI blocks it; the RPC rejects it with "Reconcile again with the correct figure").

## Next for friends

When a friend signs up:
1. They add their **first bank account** in Settings → Bank Accounts (label "Primary", opening balance = whatever they have now)
2. They connect **their own Gmail** in Make (new google-email connection)
3. The scenario auto-fans to their account — no code change, no new `p_user_id` to patch