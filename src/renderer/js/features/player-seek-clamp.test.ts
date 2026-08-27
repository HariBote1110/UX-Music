import { beforeAll, describe, expect, it } from 'vitest';

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

// park からの復帰直後は goState.duration がまだ 0（未取得）のことがある。
// このとき seek() が duration=0 に向けて時刻をクランプしてしまうと、
// ドラッグ操作が常に位置 0 へシークし直すことになる
// （park-resume-cold-state.md 参照）。duration が未確定（0 や非有限値）の
// 間は 0 へクランプせず、要求された時刻をそのまま通す。
describe('clampSeekTarget', () => {
    it('clamps to [0, duration] when duration is known', async () => {
        const { clampSeekTarget } = await import('./player.js');
        expect(clampSeekTarget(250, 200)).toBe(200);
        expect(clampSeekTarget(-10, 200)).toBe(0);
        expect(clampSeekTarget(100, 200)).toBe(100);
    });

    it('does not clamp to 0 when duration is unknown (0)', async () => {
        const { clampSeekTarget } = await import('./player.js');
        expect(clampSeekTarget(45, 0)).toBe(45);
    });

    it('does not clamp to 0 when duration is non-finite', async () => {
        const { clampSeekTarget } = await import('./player.js');
        expect(clampSeekTarget(45, NaN)).toBe(45);
    });

    it('still floors the requested time at 0 when duration is unknown', async () => {
        const { clampSeekTarget } = await import('./player.js');
        expect(clampSeekTarget(-5, 0)).toBe(0);
    });
});
