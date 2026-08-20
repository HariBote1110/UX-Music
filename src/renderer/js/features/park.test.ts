import { describe, expect, it } from 'vitest';
import {
    PARK_DELAY_MS,
    classifyPendingIntent,
    deserializeParkedUIState,
    serializeParkedUIState,
    shouldPark,
} from './park.js';

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

describe('serializeParkedUIState / deserializeParkedUIState', () => {
    it('round-trips a valid state', () => {
        const raw = serializeParkedUIState({ viewId: 'album-view', scrollTop: 240 });
        expect(deserializeParkedUIState(raw)).toEqual({ viewId: 'album-view', scrollTop: 240 });
    });

    it('returns null for missing/empty input', () => {
        expect(deserializeParkedUIState(null)).toBeNull();
        expect(deserializeParkedUIState(undefined)).toBeNull();
        expect(deserializeParkedUIState('')).toBeNull();
    });

    it('returns null for malformed JSON instead of throwing', () => {
        expect(deserializeParkedUIState('{not json')).toBeNull();
    });

    it('returns null when the shape does not match (defensive against a future format change)', () => {
        expect(deserializeParkedUIState('{"viewId":123}')).toBeNull();
        expect(deserializeParkedUIState('"just a string"')).toBeNull();
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
