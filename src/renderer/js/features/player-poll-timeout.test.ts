import { beforeAll, afterEach, describe, expect, it, vi } from 'vitest';

beforeAll(() => {
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: () => Promise.resolve(null),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
});

afterEach(() => {
    vi.useRealTimers();
});

// Bug D: startGoStatePolling() の Wails 呼び出しにタイムアウトがなく、
// WebView 破棄中などでプロミスが永久に確定しないと goPollInFlight が
// true のまま固まりポーリングが停止する問題。
describe('withPollTimeout', () => {
    it('resolves with the underlying value when it settles before the timeout', async () => {
        const { withPollTimeout } = await import('./player.js');
        await expect(withPollTimeout(Promise.resolve('ok'), 50)).resolves.toBe('ok');
    });

    it('rejects once the timeout elapses if the underlying promise never settles', async () => {
        const { withPollTimeout } = await import('./player.js');
        vi.useFakeTimers();
        const never = new Promise(() => {});
        const p = withPollTimeout(never, 3000);
        const assertion = expect(p).rejects.toThrow();
        await vi.advanceTimersByTimeAsync(3000);
        await assertion;
    });
});
