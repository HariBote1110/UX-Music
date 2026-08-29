import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { resolveArtworkPath } from './utils.js';

describe('resolveArtworkPath for playlist collage tiles', () => {
    const originalWindow = globalThis.window;

    beforeEach(() => {
        // window.go !== undefined mimics running inside the Wails app,
        // where /safe-artwork/... paths (not the safe-artwork:// scheme)
        // are used.
        globalThis.window = { go: {} } as unknown as Window & typeof globalThis;
    });

    afterEach(() => {
        globalThis.window = originalWindow;
    });

    it('resolves an object-shaped artwork to the thumbnails path when a thumbnail is requested', () => {
        const artwork = { full: 'a.webp', thumbnail: 'a_thumb.webp' };
        expect(resolveArtworkPath(artwork, true)).toBe('/safe-artwork/thumbnails/a_thumb.webp');
    });

    it('resolves an object-shaped artwork to the plain path when the full image is requested', () => {
        const artwork = { full: 'a.webp', thumbnail: 'a_thumb.webp' };
        expect(resolveArtworkPath(artwork, false)).toBe('/safe-artwork/a.webp');
    });
});
