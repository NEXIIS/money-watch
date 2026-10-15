import { Landmark, ArrowRight } from 'lucide-react';

interface OnboardingBannerProps {
  onAddBankAccount: () => void;
}

/**
 * The ₦0 dead end, and the one thing that opens it.
 *
 * A new account starts with no bank account, no balance and an empty vault.
 * Every money path is then refused by the database, not just hidden by the UI:
 * `log_expense` answers "Insufficient total funds (Main + Vault)", and
 * `move_to_vault` has nothing to move. Adding a bank account with today's real
 * balance is the single action that gives the ledger something to spend, so the
 * banner deep-links straight into that form rather than making them hunt for it.
 *
 * Not dismissible: it resolves itself the moment an account exists.
 */
export function OnboardingBanner({ onAddBankAccount }: OnboardingBannerProps) {
  return (
    <section
      aria-labelledby="onboarding-heading"
      className="rounded-3xl border border-blue-500/25 bg-gradient-to-br from-blue-500/10 to-slate-900 p-5 space-y-4 shadow-xl"
    >
      <div className="flex items-start gap-3">
        <div className="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-2xl bg-blue-600/20">
          <Landmark size={20} className="text-blue-400" />
        </div>
        <div className="min-w-0">
          <h2 id="onboarding-heading" className="text-base font-semibold text-white">
            Start by adding your bank account
          </h2>
          <p className="mt-1 text-sm leading-relaxed text-slate-400">
            You are at <span className="font-semibold text-slate-200">₦0.00</span>, so
            logging an expense or filling your savings vault has nothing to draw from.
            Add the account you actually bank with and enter the balance it shows today —
            that balance becomes your starting point.
          </p>
        </div>
      </div>

      <ol className="space-y-2 pl-1 text-xs text-slate-400">
        <li className="flex gap-2">
          <span className="font-semibold text-blue-400">1.</span>
          <span>Give it a label you'll recognise, like{' '}
            <span className="text-slate-300">Primary</span>.</span>
        </li>
        <li className="flex gap-2">
          <span className="font-semibold text-blue-400">2.</span>
          <span>
            Enter what your bank says right now — that is your opening balance, not a
            guess.
          </span>
        </li>
        <li className="flex gap-2">
          <span className="font-semibold text-blue-400">3.</span>
          <span>
            You can add more accounts later, and reconcile any of them whenever your
            bank disagrees with the app.
          </span>
        </li>
      </ol>

      <button
        onClick={onAddBankAccount}
        className="flex w-full items-center justify-center gap-2 rounded-2xl bg-blue-600 py-3.5 text-sm font-semibold text-white shadow-lg shadow-blue-600/20 transition hover:bg-blue-500"
      >
        Add your first bank account
        <ArrowRight size={16} />
      </button>
    </section>
  );
}