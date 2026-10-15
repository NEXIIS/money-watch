import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';

// vi.mock factories are hoisted, so shared mocks must be created via vi.hoisted().
const { fromMock, channelMock } = vi.hoisted(() => {
  const ch: Record<string, unknown> = {};
  ch.on = vi.fn(() => ch);
  ch.subscribe = vi.fn(() => ch);
  return { fromMock: vi.fn(), channelMock: ch };
});

vi.mock('../lib/supabase', () => ({
  supabase: {
    from: fromMock,
    channel: vi.fn(() => channelMock),
    removeChannel: vi.fn(),
    auth: {
      getUser: vi.fn().mockResolvedValue({ data: { user: null } }),
    },
    rpc: vi.fn(),
  },
}));

import { useWallet } from '../hooks/useWallet';

const USER_ID = '00000000-0000-0000-0000-000000000001';

const NOTIFICATION = {
  id: 'n1',
  user_id: USER_ID,
  type: 'info',
  title: 'Hi',
  message: 'x',
  is_read: false,
  created_at: '2026-01-01',
};

function mockTables(notifications: unknown[], updateError: { message: string } | null) {
  fromMock.mockImplementation((table: string) => {
    // Thenable query builder so the hook can both chain .maybeSingle() and await.
    const builder: Record<string, unknown> = {};
    builder.select = () => builder;
    builder.eq = () => builder;
    builder.order = () => builder;
    builder.limit = () => builder;
    builder.maybeSingle = () => Promise.resolve({ data: null, error: null });
    builder.update = () => ({ eq: () => Promise.resolve({ error: updateError }) });
    builder.then = (resolve: (value: unknown) => void) =>
      Promise.resolve({
        data: table === 'notifications' ? notifications : [],
        error: null,
      }).then(resolve);
    return builder;
  });
}

describe('useWallet notifications markAsRead', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('keeps the notification in the list and marks it read on success', async () => {
    mockTables([NOTIFICATION], null);

    const { result } = renderHook(() => useWallet(USER_ID));
    await waitFor(() => expect(result.current.notifications).toHaveLength(1));

    await act(async () => {
      await result.current.markAsRead('n1');
    });

    // Optimistic state is kept (is_read: true) and the row is NOT removed.
    await waitFor(() => {
      expect(result.current.notifications).toHaveLength(1);
      expect(result.current.notifications[0].is_read).toBe(true);
    });
  });

  it('reverts to is_read false when the update fails', async () => {
    mockTables([{ ...NOTIFICATION, id: 'n2' }], { message: 'network' });

    const { result } = renderHook(() => useWallet(USER_ID));
    await waitFor(() => expect(result.current.notifications).toHaveLength(1));

    await act(async () => {
      await result.current.markAsRead('n2');
    });

    await waitFor(() => {
      expect(result.current.notifications).toHaveLength(1);
      expect(result.current.notifications[0].is_read).toBe(false);
    });
  });
});
