import { describe, expect, it } from 'vitest';

// jsdom の本物の window を使い、Electron ブリッジだけを差し込む
// (playback-manager.test.ts と同じパターン)。park.ts はモジュール読み込み時に
// core/bridge.js 経由で window.electronAPI を参照するため、import より前に
// 同期的に用意しておく必要がある（beforeAll では遅すぎる — トップレベル
// import はどの beforeAll フックよりも先に評価されるため）。
(window as unknown as { electronAPI: unknown }).electronAPI = {
    CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
    send: () => {},
    invoke: () => Promise.resolve(null),
    on: () => {},
    removeListener: () => {},
    removeAllListeners: () => {},
};

const {
    PARK_DELAY_MS,
    classifyPendingIntent,
    parseParkedUIState,
    shouldPark,
} = await import('./park.js');

describe('PARK_DELAY_MS', () => {
    it('is 15 seconds, per markdown/background-native-queue-plan.md Phase 2', () => {
        expect(PARK_DELAY_MS).toBe(15000);
    });
});

describe('shouldPark', () => {
    it('parks only when still hidden, no embed session, and running under Wails', () => {
        expect(shouldPark({ stillHidden: true, embedActive: false, isWails: true })).toBe(true);
    });

    it('does not park if the window became visible again before the debounce fired', () => {
        expect(shouldPark({ stillHidden: false, embedActive: false, isWails: true })).toBe(false);
    });

    it('does not park while a YouTube embed session is active', () => {
        expect(shouldPark({ stillHidden: true, embedActive: true, isWails: true })).toBe(false);
    });

    it('does not park outside Wails (browser fallback)', () => {
        expect(shouldPark({ stillHidden: true, embedActive: false, isWails: false })).toBe(false);
    });
});

describe('parseParkedUIState', () => {
    it('accepts a valid object as returned by ConsumeParkedUIState (Go binding)', () => {
        expect(parseParkedUIState({ viewId: 'album-view', scrollTop: 240 })).toEqual({ viewId: 'album-view', scrollTop: 240 });
    });

    it('returns null for missing/empty input', () => {
        expect(parseParkedUIState(null)).toBeNull();
        expect(parseParkedUIState(undefined)).toBeNull();
    });

    it('returns null when the shape does not match (defensive against a future format change)', () => {
        expect(parseParkedUIState({ viewId: 123, scrollTop: 0 })).toBeNull();
        expect(parseParkedUIState('just a string')).toBeNull();
        expect(parseParkedUIState(42)).toBeNull();
        expect(parseParkedUIState({})).toBeNull();
    });
});

describe('classifyPendingIntent', () => {
    it('recognises queue-play-embed', () => {
        expect(classifyPendingIntent({ event: 'queue-play-embed', payload: {} })).toBe('queue-play-embed');
    });

    it('recognises remote-play-song', () => {
        expect(classifyPendingIntent({ event: 'remote-play-song', payload: 'song-1' })).toBe('remote-play-song');
    });

    it('returns null for an empty/missing intent (nothing pending)', () => {
        expect(classifyPendingIntent(null)).toBeNull();
        expect(classifyPendingIntent(undefined)).toBeNull();
    });

    it('returns null for an unrecognised event name', () => {
        expect(classifyPendingIntent({ event: 'something-else' })).toBeNull();
    });
});
