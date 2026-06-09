import { describe, expect, it } from 'vitest';
import { applyAlignedTimestamps, validateAutoSyncPrereqs } from './lrc-auto-sync.js';

describe('validateAutoSyncPrereqs', () => {
    it('rejects when no current song path is set', () => {
        const result = validateAutoSyncPrereqs({
            currentEditorSong: null,
            lyricsLines: [{ text: 'hi', timestamp: null }],
        });
        expect(result.ok).toBe(false);
        expect(result.message).toMatch(/曲情報/);
    });

    it('rejects when current song has empty path', () => {
        const result = validateAutoSyncPrereqs({
            currentEditorSong: { path: '' },
            lyricsLines: [{ text: 'hi', timestamp: null }],
        });
        expect(result.ok).toBe(false);
    });

    it('rejects when lyricsLines is empty', () => {
        const result = validateAutoSyncPrereqs({
            currentEditorSong: { path: '/a.mp3' },
            lyricsLines: [],
        });
        expect(result.ok).toBe(false);
        expect(result.message).toMatch(/歌詞テキスト/);
    });

    it('rejects when every lyrics line is blank', () => {
        const result = validateAutoSyncPrereqs({
            currentEditorSong: { path: '/a.mp3' },
            lyricsLines: [
                { text: '', timestamp: null },
                { text: '   ', timestamp: null },
            ],
        });
        expect(result.ok).toBe(false);
        expect(result.message).toMatch(/同期対象/);
    });

    it('accepts when at least one line has non-whitespace text', () => {
        const result = validateAutoSyncPrereqs({
            currentEditorSong: { path: '/a.mp3' },
            lyricsLines: [
                { text: '', timestamp: null },
                { text: 'hello', timestamp: null },
            ],
        });
        expect(result.ok).toBe(true);
        expect(result.message).toBeUndefined();
    });
});

describe('applyAlignedTimestamps', () => {
    it('writes timestamp into the matching index', () => {
        const lines = [
            { text: 'a', timestamp: null },
            { text: 'b', timestamp: null },
        ];
        const count = applyAlignedTimestamps(lines, [
            { index: 1, timestamp: 12.345 },
        ]);
        expect(count).toBe(1);
        expect(lines[1].timestamp).toBeCloseTo(12.345, 3);
        expect(lines[0].timestamp).toBeNull();
    });

    it('clamps negative timestamps to zero (via normaliseTimestamp)', () => {
        const lines = [{ text: 'a', timestamp: null }];
        applyAlignedTimestamps(lines, [{ index: 0, timestamp: -5 }]);
        expect(lines[0].timestamp).toBe(0);
    });

    it('skips entries with non-integer index', () => {
        const lines = [{ text: 'a', timestamp: null }];
        const count = applyAlignedTimestamps(lines, [
            { index: 1.5, timestamp: 3 } as unknown as { index: number; timestamp: number },
            { index: 0, timestamp: 7 },
        ]);
        expect(count).toBe(1);
        expect(lines[0].timestamp).toBe(7);
    });

    it('skips out-of-range indices', () => {
        const lines = [{ text: 'a', timestamp: null }];
        const count = applyAlignedTimestamps(lines, [
            { index: 5, timestamp: 1 },
            { index: -1, timestamp: 2 },
        ]);
        expect(count).toBe(0);
        expect(lines[0].timestamp).toBeNull();
    });

    it('skips entries with non-numeric or NaN timestamp', () => {
        const lines = [
            { text: 'a', timestamp: null },
            { text: 'b', timestamp: null },
        ];
        applyAlignedTimestamps(lines, [
            { index: 0, timestamp: Number.NaN },
            { index: 1, timestamp: 'oops' as unknown as number },
        ]);
        expect(lines[0].timestamp).toBeNull();
        expect(lines[1].timestamp).toBeNull();
    });

    it('returns zero when given an empty list', () => {
        const lines = [{ text: 'a', timestamp: null }];
        expect(applyAlignedTimestamps(lines, [])).toBe(0);
    });
});
