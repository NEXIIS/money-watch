import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { TransactionList } from '../components/TransactionList';
import type { Transaction, TransactionType } from '../types';

let seq = 0;
function tx(overrides: Partial<Transaction> & { type: TransactionType; amount: number }): Transaction {
  seq += 1;
  return {
    id: `t${seq}`,
    user_id: 'u1',
    description: `row ${seq}`,
    category: 'General',
    category_id: null,
    session_id: null,
    account_id: null,
    linked_to: null,
    date: '2020-01-15T00:00:00Z',
    created_at: '2020-01-15T00:00:00Z',
    ...overrides,
  };
}

describe('TransactionList type bucketing', () => {
  it('does not render an internal vault withdrawal as income', () => {
    render(<TransactionList transactions={[tx({ type: 'vault_withdrawal', amount: 5000 })]} />);

    // Positive amount, but it is an internal move: no "+" and no green income styling.
    expect(screen.getByText(/₦5,000\.00/)).not.toHaveTextContent('+');
    expect(screen.getByText('internal')).toBeInTheDocument();
  });

  it('renders a deposit as income and an expense as an outflow', () => {
    render(
      <TransactionList
        transactions={[
          tx({ type: 'deposit', amount: 1500, description: 'salary' }),
          tx({ type: 'expense', amount: -200, description: 'uber' }),
        ]}
      />
    );

    expect(screen.getByText(/₦1,500\.00/)).toHaveTextContent('+');
    expect(screen.getByText(/₦200\.00/)).toHaveTextContent('-');
    expect(screen.queryByText('internal')).not.toBeInTheDocument();
  });

  // A reconciliation corrects the ledger to match the bank. The money already
  // existed, so it is neither income nor spending and must not be signed like
  // a deposit or an expense.
  it('renders a reconciliation neutrally, labelled as reconciled', () => {
    render(
      <TransactionList
        transactions={[
          tx({ type: 'reconciliation', amount: -4200, description: 'Reconciled with GTBank Current: -4200' }),
        ]}
      />
    );

    const amount = screen.getByText(/₦4,200\.00/);
    expect(amount).not.toHaveTextContent('+');
    expect(amount).not.toHaveTextContent('-');
    expect(screen.getByText('reconciled')).toBeInTheDocument();
    expect(screen.queryByText('internal')).not.toBeInTheDocument();
  });
});

describe('TransactionList business date', () => {
  it('shows the business date, not the insertion timestamp', () => {
    const today = new Date().toISOString();
    render(
      <TransactionList
        transactions={[tx({ type: 'expense', amount: -100, date: '2020-01-15T00:00:00Z', created_at: today })]}
      />
    );

    // created_at is today; the row must not claim to be from today.
    expect(screen.queryByText('Today')).not.toBeInTheDocument();
    expect(screen.getByText(/15 Jan/)).toBeInTheDocument();
  });
});

describe('TransactionList edit/delete gating', () => {
  const onEdit = vi.fn();
  const onDelete = vi.fn();

  it('offers edit and delete for an expense', async () => {
    render(
      <TransactionList
        transactions={[tx({ type: 'expense', amount: -500 })]}
        onEditTransaction={onEdit}
        onDeleteTransaction={onDelete}
      />
    );

    await userEvent.click(screen.getByTitle('View Details'));
    expect(screen.getByRole('button', { name: /edit/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /delete/i })).toBeInTheDocument();
  });

  it('offers delete but not edit for an internal vault transfer', async () => {
    render(
      <TransactionList
        transactions={[tx({ type: 'vault_deposit', amount: -500 })]}
        onEditTransaction={onEdit}
        onDeleteTransaction={onDelete}
      />
    );

    await userEvent.click(screen.getByTitle('View Details'));
    expect(screen.queryByRole('button', { name: /edit/i })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /delete/i })).toBeInTheDocument();
  });

  it('offers neither for an overdraft row, which belongs to its expense', async () => {
    render(
      <TransactionList
        transactions={[tx({ type: 'vault_overdraft', amount: -500 })]}
        onEditTransaction={onEdit}
        onDeleteTransaction={onDelete}
      />
    );

    await userEvent.click(screen.getByTitle('View Details'));
    expect(screen.queryByRole('button', { name: /edit/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /delete/i })).not.toBeInTheDocument();
  });

  // The amount on a reconciliation is what the bank reported, so it must not be
  // hand-editable. Delete is still offered, and the RPC fully reverses it.
  it('offers delete but not edit for a reconciliation row', async () => {
    render(
      <TransactionList
        transactions={[tx({ type: 'reconciliation', amount: -4200 })]}
        onEditTransaction={onEdit}
        onDeleteTransaction={onDelete}
      />
    );

    await userEvent.click(screen.getByTitle('View Details'));
    expect(screen.queryByRole('button', { name: /edit/i })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /delete/i })).toBeInTheDocument();
  });

  it('now offers edit for a bank-synced withdrawal', async () => {
    render(
      <TransactionList
        transactions={[tx({ type: 'withdrawal', amount: -900 })]}
        onEditTransaction={onEdit}
        onDeleteTransaction={onDelete}
      />
    );

    await userEvent.click(screen.getByTitle('View Details'));
    expect(screen.getByRole('button', { name: /edit/i })).toBeInTheDocument();
  });
});