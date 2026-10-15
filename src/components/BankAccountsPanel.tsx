import { useState } from 'react';
import { Landmark, Plus, RefreshCw, Trash2, X, AlertTriangle, Check } from 'lucide-react';
import type { BankAccount } from '../types';

interface BankAccountsPanelProps {
  accounts: BankAccount[];
  /** Deep link from the ₦0 onboarding banner: land with the form already open. */
  initiallyOpenAdd?: boolean;
  onAdd: (label: string, openingBalance: number, bankName?: string) => Promise<boolean>;
  onRemove: (accountId: string) => Promise<boolean>;
  onReconcile: (accountId: string, reportedBalance: number) => Promise<unknown>;
}

const naira = (n: number) =>
  `₦${n.toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/**
 * Bank accounts and reconciliation.
 *
 * The bank is authoritative: enter what your bank reports and the ledger
 * concedes to match, writing a visible `reconciliation` row so the change is
 * auditable rather than silent. The savings vault is never involved.
 */
export function BankAccountsPanel({
  accounts,
  initiallyOpenAdd = false,
  onAdd,
  onRemove,
  onReconcile,
}: BankAccountsPanelProps) {
  const [showAdd, setShowAdd] = useState(initiallyOpenAdd);
  const [label, setLabel] = useState('');
  const [bankName, setBankName] = useState('');
  const [opening, setOpening] = useState('');
  const [isSaving, setIsSaving] = useState(false);

  const [reconcilingId, setReconcilingId] = useState<string | null>(null);
  const [reported, setReported] = useState('');

  const handleAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = label.trim();
    if (!trimmed) return;

    const parsed = Number(opening);
    if (opening.trim() && (!Number.isFinite(parsed) || parsed < 0)) return;

    setIsSaving(true);
    const ok = await onAdd(trimmed, Number.isFinite(parsed) ? parsed : 0, bankName.trim() || undefined);
    setIsSaving(false);

    if (ok) {
      setLabel('');
      setBankName('');
      setOpening('');
      setShowAdd(false);
    }
  };

  const handleReconcile = async (account: BankAccount) => {
    const parsed = Number(reported);
    if (!Number.isFinite(parsed) || parsed < 0) return;

    setIsSaving(true);
    await onReconcile(account.id, parsed);
    setIsSaving(false);
    setReconcilingId(null);
    setReported('');
  };

  return (
    <div className="bg-slate-900 border border-slate-800 rounded-3xl p-6 space-y-5 shadow-xl">
      <div className="flex items-center justify-between border-b border-slate-800 pb-4">
        <h3 className="text-lg font-semibold text-white flex items-center gap-2">
          <Landmark size={18} className="text-slate-400" />
          Bank Accounts
        </h3>
        {!showAdd && (
          <button
            onClick={() => setShowAdd(true)}
            className="flex items-center gap-1.5 rounded-xl bg-slate-800 border border-slate-700 px-3 py-1.5 text-xs font-semibold text-slate-300 hover:bg-slate-700 transition"
          >
            <Plus size={14} />
            Add
          </button>
        )}
      </div>

      {showAdd && (
        <form onSubmit={handleAdd} className="space-y-3 rounded-2xl bg-slate-800/40 border border-slate-700/60 p-4">
          <div>
            <label className="block text-xs font-medium uppercase tracking-wider text-slate-500 mb-1.5">
              Label
            </label>
            <input
              type="text"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              placeholder="e.g. GTBank Current"
              autoFocus
              className="w-full rounded-xl bg-slate-800 border border-slate-700 px-3.5 py-2.5 text-sm text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-medium uppercase tracking-wider text-slate-500 mb-1.5">
                Bank (optional)
              </label>
              <input
                type="text"
                value={bankName}
                onChange={(e) => setBankName(e.target.value)}
                placeholder="GTBank"
                className="w-full rounded-xl bg-slate-800 border border-slate-700 px-3.5 py-2.5 text-sm text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
              />
            </div>
            <div>
              <label className="block text-xs font-medium uppercase tracking-wider text-slate-500 mb-1.5">
                Balance now
              </label>
              <div className="relative">
                <span className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-500 text-sm">₦</span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  inputMode="decimal"
                  value={opening}
                  onChange={(e) => setOpening(e.target.value)}
                  placeholder="0.00"
                  className="w-full rounded-xl bg-slate-800 border border-slate-700 pl-7 pr-3 py-2.5 text-sm text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
                />
              </div>
            </div>
          </div>

          <p className="text-[11px] text-slate-500 leading-relaxed">
            The balance you enter is what your app currently believes. When you later
            reconcile, any difference gets recorded as a visible adjustment.
          </p>

          <div className="flex gap-2">
            <button
              type="submit"
              disabled={isSaving || !label.trim()}
              className="flex-1 rounded-xl bg-blue-600 py-2.5 text-sm font-semibold text-white transition hover:bg-blue-700 disabled:opacity-50"
            >
              {isSaving ? 'Adding...' : 'Add Account'}
            </button>
            <button
              type="button"
              onClick={() => setShowAdd(false)}
              className="rounded-xl bg-slate-800 border border-slate-700 px-3.5 py-2.5 text-slate-400 hover:text-slate-200 transition"
              aria-label="Cancel"
            >
              <X size={16} />
            </button>
          </div>
        </form>
      )}

      {accounts.length === 0 && !showAdd && (
        <p className="text-sm text-slate-500 py-2">
          No accounts yet. Add one to start reconciling against your bank.
        </p>
      )}

      <div className="space-y-3">
        {accounts.map((acct) => {
          const drift =
            acct.reported_balance === null ? null : acct.reported_balance - acct.ledger_balance;
          const isReconciling = reconcilingId === acct.id;

          return (
            <div
              key={acct.id}
              className="rounded-2xl bg-slate-800/40 border border-slate-700/60 p-4 space-y-3"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-sm font-semibold text-white truncate">{acct.label}</p>
                  {acct.bank_name && (
                    <p className="text-xs text-slate-500 truncate">{acct.bank_name}</p>
                  )}
                </div>
                <button
                  onClick={() => onRemove(acct.id)}
                  className="p-1.5 rounded-lg text-slate-500 hover:text-red-400 hover:bg-red-500/10 transition flex-shrink-0"
                  title="Remove account"
                  aria-label={`Remove ${acct.label}`}
                >
                  <Trash2 size={15} />
                </button>
              </div>

              <div className="grid grid-cols-2 gap-3 text-sm">
                <div>
                  <p className="text-[10px] uppercase tracking-wider text-slate-500">App ledger</p>
                  <p className="font-semibold text-slate-200 tabular-nums">{naira(acct.ledger_balance)}</p>
                </div>
                <div>
                  <p className="text-[10px] uppercase tracking-wider text-slate-500">
                    Bank reported
                  </p>
                  <p className="font-semibold text-slate-200 tabular-nums">
                    {acct.reported_balance === null ? '—' : naira(acct.reported_balance)}
                  </p>
                </div>
              </div>

              {drift !== null && Math.abs(drift) >= 0.005 && (
                <p className="flex items-start gap-1.5 text-xs text-amber-400/90">
                  <AlertTriangle size={13} className="mt-0.5 flex-shrink-0" />
                  <span>
                    Out of sync by {drift > 0 ? '+' : '−'}
                    {naira(Math.abs(drift))}. Reconciling will correct your ledger.
                  </span>
                </p>
              )}

              {drift !== null && Math.abs(drift) < 0.005 && (
                <p className="flex items-center gap-1.5 text-xs text-emerald-400/90">
                  <Check size={13} />
                  <span>In sync with your bank</span>
                </p>
              )}

              {isReconciling ? (
                <div className="space-y-2">
                  <label className="block text-xs font-medium uppercase tracking-wider text-slate-500">
                    What does your bank say?
                  </label>
                  <div className="relative">
                    <span className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-500 text-sm">₦</span>
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      inputMode="decimal"
                      value={reported}
                      onChange={(e) => setReported(e.target.value)}
                      autoFocus
                      placeholder="0.00"
                      className="w-full rounded-xl bg-slate-800 border border-slate-700 pl-7 pr-3 py-2.5 text-sm text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
                    />
                  </div>
                  <p className="text-[11px] text-slate-500 leading-relaxed">
                    Your ledger moves to this figure and the difference is logged as a
                    visible adjustment. Your savings vault is not touched.
                  </p>
                  <div className="flex gap-2">
                    <button
                      onClick={() => handleReconcile(acct)}
                      disabled={isSaving || reported.trim() === ''}
                      className="flex-1 rounded-xl bg-blue-600 py-2.5 text-sm font-semibold text-white transition hover:bg-blue-700 disabled:opacity-50"
                    >
                      {isSaving ? 'Reconciling...' : 'Confirm'}
                    </button>
                    <button
                      onClick={() => {
                        setReconcilingId(null);
                        setReported('');
                      }}
                      className="rounded-xl bg-slate-800 border border-slate-700 px-3.5 py-2.5 text-slate-400 hover:text-slate-200 transition"
                      aria-label="Cancel reconciliation"
                    >
                      <X size={16} />
                    </button>
                  </div>
                </div>
              ) : (
                <button
                  onClick={() => {
                    setReconcilingId(acct.id);
                    setReported(acct.reported_balance === null ? String(acct.ledger_balance) : '');
                  }}
                  className="w-full flex items-center justify-center gap-2 rounded-xl bg-slate-800 border border-slate-700 py-2.5 text-sm font-semibold text-slate-300 hover:bg-slate-700 transition"
                >
                  <RefreshCw size={14} />
                  Reconcile
                </button>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
