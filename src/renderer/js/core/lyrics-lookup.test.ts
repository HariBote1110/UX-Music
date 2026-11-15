import { describe, expect, it, vi } from 'vitest';
import { findLyricsWithCandidates, lyricsLookupCandidates } from './lyrics-lookup.js';

describe('lyricsLookupCandidates', () => {
    it('lists the file base name first and the title second', () => {
        expect(lyricsLookupCandidates({ path: '/M/a/foo_bar.mp3', title: 'Foo Bar' })).toEqual([
            'foo_bar',
            'Foo Bar',
        ]);
    });

    it('uses the last path segment for Windows-style paths', () => {
        expect(lyricsLookupCandidates({ path: 'C:\\music\\track.flac' })).toEqual(['track']);
    });

    it('keeps a file name without extension as is', () => {
        expect(lyricsLookupCandidates({ path: '/m/song' })).toEqual(['song']);
    });

    it('trims values and drops empty ones', () => {
        expect(lyricsLookupCandidates({ path: '  /m/ x .mp3  ', title: '   ' })).toEqual(['x']);
        expect(lyricsLookupCandidates({ title: '  T  ' })).toEqual(['T']);
    });

    it('removes duplicates while keeping the order', () => {
        expect(lyricsLookupCandidates({ path: '/x/Same.mp3', title: 'Same' })).toEqual(['Same']);
    });

    it('ignores non-string fields and missing songs', () => {
        expect(lyricsLookupCandidates({ path: 42, title: null })).toEqual([]);
        expect(lyricsLookupCandidates(null)).toEqual([]);
        expect(lyricsLookupCandidates(undefined)).toEqual([]);
    });
});

describe('findLyricsWithCandidates', () => {
    it('returns the first lrc or txt result in candidate order', async () => {
        const getLyrics = vi.fn(async (name: string) => {
            if (name === 'file-base') {
                return { type: '', content: '' };
            }
            if (name === 'Title') {
                return { type: 'txt', content: 'hello' };
            }
            return null;
        });
        const result = await findLyricsWithCandidates(getLyrics, { path: '/m/file-base.mp3', title: 'Title' });
        expect(result).toEqual({ type: 'txt', content: 'hello' });
        expect(getLyrics.mock.calls.map(c => c[0])).toEqual(['file-base', 'Title']);
    });

    it('returns null when no candidate has lyrics', async () => {
        const getLyrics = vi.fn(async () => ({ type: 'none' }));
        expect(await findLyricsWithCandidates(getLyrics, { path: '/m/a.mp3', title: 'B' })).toBeNull();
        expect(getLyrics).toHaveBeenCalledTimes(2);
    });

    it('returns null without calling the lookup for an empty song', async () => {
        const getLyrics = vi.fn(async () => ({ type: 'lrc' }));
        expect(await findLyricsWithCandidates(getLyrics, null)).toBeNull();
        expect(getLyrics).not.toHaveBeenCalled();
    });
});
