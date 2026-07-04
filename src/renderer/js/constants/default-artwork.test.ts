import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DEFAULT_ARTWORK_URL } from './default-artwork.js';
import { resolveArtworkPath } from '../ui/utils.js';

describe('DEFAULT_ARTWORK_URL fallback behaviour', () => {
    const originalWindow = globalThis.window;

    beforeEach(() => {
        globalThis.window = { go: undefined } as unknown as Window & typeof globalThis;
    });

    afterEach(() => {
        globalThis.window = originalWindow;
    });

    it('resolves to the default artwork URL when no artwork is provided', () => {
        expect(resolveArtworkPath(null)).toBe(DEFAULT_ARTWORK_URL);
        expect(resolveArtworkPath(undefined)).toBe(DEFAULT_ARTWORK_URL);
        expect(resolveArtworkPath('')).toBe(DEFAULT_ARTWORK_URL);
    });

    it('resolves to the default artwork URL for an unrecognised artwork shape', () => {
        expect(resolveArtworkPath(12345 as unknown)).toBe(DEFAULT_ARTWORK_URL);
        expect(resolveArtworkPath({ unexpected: true } as unknown)).toBe(DEFAULT_ARTWORK_URL);
    });

    it('does not fall back to the default artwork URL when a real artwork path is provided', () => {
        expect(resolveArtworkPath('http://example.com/cover.jpg')).toBe('http://example.com/cover.jpg');
        expect(resolveArtworkPath({ full: 'a.png', thumbnail: 'a_thumb.png' })).not.toBe(DEFAULT_ARTWORK_URL);
    });
});
