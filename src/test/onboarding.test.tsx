import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { OnboardingBanner } from '../components/OnboardingBanner';
import { BankAccountsPanel } from '../components/BankAccountsPanel';

describe('OnboardingBanner', () => {
  it('names the dead end and offers the one action that fixes it', () => {
    render(<OnboardingBanner onAddBankAccount={() => {}} />);

    expect(screen.getByText('Start by adding your bank account')).toBeInTheDocument();
    // The banner must say the balance is the problem, not just that it is empty.
    expect(screen.getByText('₦0.00')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /add your first bank account/i })).toBeInTheDocument();
  });

  it('hands the click to the caller so it can deep-link into the add form', async () => {
    const onAddBankAccount = vi.fn();
    render(<OnboardingBanner onAddBankAccount={onAddBankAccount} />);

    await userEvent.click(screen.getByRole('button', { name: /add your first bank account/i }));

    expect(onAddBankAccount).toHaveBeenCalledTimes(1);
  });
});

describe('BankAccountsPanel deep link', () => {
  const noop = () => Promise.resolve(true);

  it('keeps the add form closed by default', () => {
    render(
      <BankAccountsPanel accounts={[]} onAdd={noop} onRemove={noop} onReconcile={noop} />,
    );

    expect(screen.queryByRole('button', { name: /add account/i })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^add$/i })).toBeInTheDocument();
  });

  it('opens the add form straight away when the banner sent the user here', () => {
    render(
      <BankAccountsPanel
        accounts={[]}
        initiallyOpenAdd
        onAdd={noop}
        onRemove={noop}
        onReconcile={noop}
      />,
    );

    expect(screen.getByRole('button', { name: /add account/i })).toBeInTheDocument();
    expect(screen.getByPlaceholderText('e.g. GTBank Current')).toBeInTheDocument();
  });

  it('submits the label and the opening balance as numbers, not strings', async () => {
    const onAdd = vi.fn().mockResolvedValue(true);
    render(
      <BankAccountsPanel
        accounts={[]}
        initiallyOpenAdd
        onAdd={onAdd}
        onRemove={noop}
        onReconcile={noop}
      />,
    );

    await userEvent.type(screen.getByPlaceholderText('e.g. GTBank Current'), 'Primary');
    await userEvent.type(screen.getByPlaceholderText('GTBank'), 'FirstBank');
    await userEvent.type(screen.getByPlaceholderText('0.00'), '24500.50');
    await userEvent.click(screen.getByRole('button', { name: /add account/i }));

    expect(onAdd).toHaveBeenCalledWith('Primary', 24500.5, 'FirstBank');
  });

  it('will not submit an empty label', async () => {
    const onAdd = vi.fn().mockResolvedValue(true);
    render(
      <BankAccountsPanel
        accounts={[]}
        initiallyOpenAdd
        onAdd={onAdd}
        onRemove={noop}
        onReconcile={noop}
      />,
    );

    // Only a balance typed, no label: the button stays disabled.
    await userEvent.type(screen.getByPlaceholderText('0.00'), '1000');
    expect(screen.getByRole('button', { name: /add account/i })).toBeDisabled();

    await userEvent.click(screen.getByRole('button', { name: /add account/i }));
    expect(onAdd).not.toHaveBeenCalled();
  });
});