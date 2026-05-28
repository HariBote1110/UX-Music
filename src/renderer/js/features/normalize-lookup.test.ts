import { describe, expect, it } from 'vitest';
import { escapeHtmlText, findNormalizeFileForResult, toJobFilePayload } from './normalize-lookup.js';

describe('findNormalizeFileForResult', () => {
    const buildMap = () => {
        const m = new Map<string, { id: string; path: string; name: string }>();
        m.set('uuid-a', { id: 'uuid-a', path: '/Music/a.flac', name: 'a.flac' });
        m.set('uuid-b', { id: 'uuid-b', path: '/Music/b.flac', name: 'b.flac' });
        return m;
    };

    it('returns the entry whose id matches', () => {
        const files = buildMap();
        const got = findNormalizeFileForResult(files, { id: 'uuid-b', path: '' });
        expect(got).toBe(files.get('uuid-b'));
    });

    it('falls back to path when id is missing in the map', () => {
        const files = buildMap();
        const got = findNormalizeFileForResult(files, { id: 'mismatched', path: '/Music/a.flac' });
        expect(got).toBe(files.get('uuid-a'));
    });

    it('falls back to path when id is undefined / null', () => {
        const files = buildMap();
        const got = findNormalizeFileForResult(files, { id: undefined, path: '/Music/b.flac' });
        expect(got).toBe(files.get('uuid-b'));
    });

    it('returns undefined when neither id nor path matches', () => {
        const files = buildMap();
        expect(
            findNormalizeFileForResult(files, { id: 'nope', path: '/nowhere.flac' }),
        ).toBeUndefined();
    });

    it('returns undefined for an empty payload', () => {
        const files = buildMap();
        expect(findNormalizeFileForResult(files, {})).toBeUndefined();
    });
});

describe('toJobFilePayload', () => {
    it('narrows to id / path / gain only, ignoring renderer-only fields', () => {
        const got = toJobFilePayload({
            id: 'uuid-1',
            path: '/Music/a.flac',
            name: 'a.flac',
            currentLufs: -22,
            targetLufs: -18,
            truePeak: -1.2,
            selected: true,
            status: 'analysed',
            gain: 4,
        });
        expect(got).toEqual({ id: 'uuid-1', path: '/Music/a.flac', gain: 4 });
    });

    it('coerces a non-number gain to a number via Number()', () => {
        const got = toJobFilePayload({
            id: 'x',
            path: '/x.flac',
            gain: '3.5' as unknown as number,
        });
        expect(got.gain).toBe(3.5);
    });

    it('defaults gain to 0 when undefined', () => {
        const got = toJobFilePayload({ id: 'x', path: '/x.flac', gain: undefined as unknown as number });
        expect(got.gain).toBe(0);
    });
});

describe('escapeHtmlText', () => {
    it('escapes file names before they are inserted through innerHTML', () => {
        expect(escapeHtmlText('<img src=x onerror=alert(1)>&"')).toBe('&lt;img src=x onerror=alert(1)&gt;&amp;&quot;');
    });
});
