# Make.com → Money-Watch: bank reconciliation wiring

## The one thing that was broken

Every money RPC guarded itself with:

```sql
if auth.uid() is distinct from p_user_id then raise exception 'Not authorized';
```

Make calls PostgREST with a project API key, and **neither the `anon` key nor the
`service_role` key carries a `jwt.sub`**. So `auth.uid()` is `NULL` on every call
Make makes, and that guard rejects all of them. `reconcile_bank_account` catches
its own exceptions and returns `{"success": false, "error": "Not authorized"}`,
so Make saw **HTTP 200 on every run** — a scenario that looked healthy and moved
no money.

The old blueprint masked this by hardcoding `p_user_id: "cff8115a-..."`, which is
both the reason it only ever worked for one user and the reason it did not work
at all.

`20261004100700_service_reconciliation.sql` fixes it with a third entry point:

| Function | Caller | Guard |
|---|---|---|
| `apply_reconciliation(uuid, uuid, numeric, timestamptz)` | internal core | `service_role` **or** `auth.uid() = p_user_id` |
| `reconcile_bank_account(uuid, numeric, timestamptz)` | the app's Bank Accounts panel | `auth.uid()` must own the account (unchanged contract) |
| `reconcile_bank_account_by_email(text, numeric, timestamptz, text)` | **Make only** | `auth.role() = 'service_role'`, no other path exists |

The email variant resolves `email → user → account` **server-side**, so no
blueprint ever carries a user id again. A friend who signs up needs nothing
wired on their behalf.

## The scenario: 3 modules, no router

The old scenario split into Debit/Credit routes and captured the transaction
amount. Both are dead weight now — reconciliation only needs the figure the bank
reports. Direction and amount are already in your ledger; the bank telling you
the same number twice is a no-op by design.

1. **Gmail — Watch New Emails.** Broad `from:` list across nine Nigerian banks,
   `subject:` widened to `debit OR credit OR alert OR "account"`. No `has:link`
   clause (unparenthesised `OR` made that whole query fire on any email
   containing a link).
2. **Parser.** One capture group, the reported balance, matching the wording
   variants banks actually use — `Cleared Bal`, `Available Bal`, `Avl. Bal`,
   `Ledger Bal`, `Book Bal`, `Current Bal`, with an optional `NGN`/`₦` prefix.
   Case-insensitive, multiline.
3. **Supabase — Make an API Call.** `POST /rest/v1/rpc/reconcile_bank_account_by_email`.

Body:

```json
{
  "p_email": "{{coalesce(43.to[1].email; get(43.headers; \"Delivered-To\"); \"UNRESOLVED\")}}",
  "p_reported_at": "{{43.internalDate}}",
  "p_reported_balance": {{parseNumber(53.`$1`; "."; ",")}}
}
```

`p_email` is the address the alert was **delivered to**, which is the address the
user registered with their bank. That is assumed to be their Money-Watch email.
`coalesce` falls back to the `Delivered-To` header, then to `UNRESOLVED`, which
the RPC rejects with `no_email` rather than guessing.

`p_reported_at` is the alert's own timestamp, so the audit row is dated when the
bank sent it rather than when Make happened to run.

If your bank's alerts arrive at an address that is not your Money-Watch email,
change the `p_email` field once — it is a single mapping, no code change.

## Setup

1. **The Supabase connection must hold the `service_role` key.** Settings →
   Connections → Money-Watch → edit → API key → `service_role`. With the `anon`
   key every call returns `{"status": "forbidden"}`. This is a server-side key:
   it never reaches the browser, and make.com stores it for you.
2. Import `make_scenario.blueprint.json`: Scenarios → ⋮ → Import blueprint.
3. Re-bind `__IMTCONN__` on both modules when prompted (`5184148` = your Gmail,
   `5259937` = Supabase). Connection ids are workspace-scoped, so they will not
   survive the import.
4. **Turn the old scenario off.** Both write to the same ledger.

## Reading the result

The RPC never raises. It returns JSON, and the run goes green either way — check
the response body of the Supabase module:

| Response | Meaning |
|---|---|
| `{"success":true, "drift":0, "reconciled":false}` | bank agrees with the ledger, nothing written |
| `{"success":true, "drift":-1500, "reconciled":true, "transaction_id":…}` | drift applied, audit row created |
| `{"status":"unknown_user"}` | that email has no Money-Watch account |
| `{"status":"no_account"}` | registered, but no bank account added yet |
| `{"status":"ambiguous_account"}` | more than one active account — add `"p_label": "Primary"` |
| `{"status":"forbidden"}` | the connection is not using the `service_role` key |
| `{"status":"ambiguous_user"}` | two accounts share that email — a signup bug, worth fixing |

## What happens on a real match

```
drift = p_reported_balance - bank_accounts.ledger_balance
```

- `drift ≠ 0` → one `reconciliation` transaction for exactly `drift`, visible in
  Recent Transactions as *"Reconciled with Primary: ±₦…"*, and
  `current_balance` + `ledger_balance` both move by the same amount.
- `drift = 0` → `reported_balance`/`reported_at` are stamped, no row written.
- `savings_balance` is **never** read or written. The vault survives a bank total
  that drops below it, which is the case that broke the old overwrite path.

`users.current_balance == sum(active bank_accounts.ledger_balance)` holds after
every one of those paths.

## Adding a friend

1. They sign up and add a bank account in Settings → Bank Accounts (the label
   becomes `p_label` when they have more than one).
2. They connect their own Gmail in make.com.
3. Done. Nothing else to configure, and no id to copy anywhere.

## Rules

- Never hardcode a `p_user_id` in a scenario again — the email is the key.
- Never reintroduce `sync_bank_to_app` with `p_cleared_balance`. It overwrites
  `current_balance` from the bank's total, which silently shrinks the vault.
- Never edit a `reconciliation` row by hand. The panel blocks it; re-reconcile.
