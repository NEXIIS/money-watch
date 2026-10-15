import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { QuickStats } from '../components/QuickStats';
import { ExpenseChart } from '../components/ExpenseChart';
import type { Transaction, TransactionType } from '../types';

let seq = 0;
function tx(type: TransactionType, amount: number): Transaction {
  seq += 1;
  return {
    id: `t${seq}`,
    user_id: 'u1',
    description: `${type} ${seq}`,
    amount,
    type,
    category: 'General',
    category_id: null,
    session_id: null,
    linked_to: null,
    date: '2026-02-20T00:00:00Z',
    created_at: '2026-02-20T00:00:00Z',
  };
}

// Mirrors the real ledger: 34 rows / 1 deposit 1111 / 8 expense / 10 withdrawal
// (all negative) / 6 vault_deposit (negative) / 6 vault_withdrawal (positive) /
// 3 vault_overdraft (negative). Internal transfers total 137500 and must never
// reach the spend figures.
const LEDGER: Transaction[] = [
  tx('deposit', 1111),
  ...Array.from({ length: 8 }, (_, i) => tx('expense', -(2000 + i * 1000))),
  ...Array.from({ length: 10 }, (_, i) => tx('withdrawal', -(500 + i * 2000))),
  ...Array.from({ length: 6 }, (_, i) => tx('vault_deposit', -(1000 + i * 6000))),
  ...Array.from({ length: 6 }, (_, i) => tx('vault_withdrawal', 1000 + i * 6000)),
  ...Array.from({ length: 3 }, (_, i) => tx('vault_overdraft', -(500 + i * 250))),
];

describe('QuickStats bucketing', () => {
  it('counts inflow from deposit only', () => {
    render(<QuickStats transactions={LEDGER} />);
    expect(screen.getByText('Total In').nextSibling).toHaveTextContent('₦1,111');
  });

  it('sums expense + withdrawal as outflow and ignores internal transfers', () => {
    // 8 expense: 2000..9000 step 1000 = 44000.
    // 10 withdrawal: 500..19500 step 2000 = 95000.
    // Total 139000, i.e. the 137500 of vault movement is left out.
    render(<QuickStats transactions={LEDGER} />);
    expect(screen.getByText('Total Out').nextSibling).toHaveTextContent('₦139,000');
  });

  it('excludes the 12 vault transfers from the spend total', () => {
    render(<QuickStats transactions={LEDGER} />);
    // 139000 outflow + 137500 internal = 276500; sign-based bucketing would
    // land there because vault_deposit rows are stored negative.
    expect(screen.getByText('Total Out').nextSibling).not.toHaveTextContent('276,500');
  });

  it('reports the row count and footnotes the internal transfers', () => {
    render(<QuickStats transactions={LEDGER} />);
    expect(screen.getByText('Transactions').nextSibling).toHaveTextContent('34');
    expect(screen.getByText(/12 internal transfers excluded/)).toBeInTheDocument();
  });

  it('is not fooled by an internal transfer carrying a spending-like sign', () => {
    // vault_deposit is stored negative. Sign-based bucketing would count this
    // as spending; type-based bucketing must not.
    render(<QuickStats transactions={[tx('vault_deposit', -90000)]} />);
    expect(screen.getByText('Total Out').nextSibling).toHaveTextContent('₦0');
  });

  it('counts vault_overdraft as neither inflow nor outflow', () => {
    render(<QuickStats transactions={[tx('vault_overdraft', -500)]} />);
    expect(screen.getByText('Total In').nextSibling).toHaveTextContent('₦0');
    expect(screen.getByText('Total Out').nextSibling).toHaveTextContent('₦0');
  });
});

describe('ExpenseChart outflow selection', () => {
  // The chart renders null when it finds no outflow rows, so "does a chart
  // appear" is the observable signal for whether a row type was counted.

  it('renders for a manual expense', () => {
    const { container } = render(<ExpenseChart transactions={[tx('expense', -3000)]} />);
    expect(container.textContent).toContain('Spending by Category');
  });

  it('renders for a bank-synced withdrawal', () => {
    // Filtering on type === 'expense' alone would leave chartData empty here
    // and return null, which is exactly the regression this pins.
    const { container } = render(<ExpenseChart transactions={[tx('withdrawal', -7000)]} />);
    expect(container.textContent).toContain('Spending by Category');
  });

  it('groups an expense and a withdrawal into one category slice', () => {
    const { container } = render(
      <ExpenseChart transactions={[tx('expense', -3000), tx('withdrawal', -7000)]} />
    );
    // Both rows share category 'General' / category_id null, so they collapse
    // to a single 'Uncategorized' legend entry rather than two.
    expect(container.querySelectorAll('.text-slate-300')).toHaveLength(1);
    expect(container.textContent).toContain('Uncategorized');
  });

  it('renders nothing when only internal vault transfers are present', () => {
    const { container } = render(
      <ExpenseChart transactions={[tx('vault_withdrawal', 40000), tx('vault_deposit', -35000)]} />
    );
    expect(container.textContent).toBe('');
  });

  it('renders nothing for an empty ledger', () => {
    const { container } = render(<ExpenseChart transactions={[]} />);
    expect(container.textContent).toBe('');
  });
});