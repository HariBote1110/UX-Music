import { beforeAll, describe, expect, it } from 'vitest';

beforeAll(() => {
    globalThis.window = {
        electronAPI: {
            CHANNELS: { SEND: {}, ON: {} },
            send: () => {},
            invoke: () => Promise.resolve(null),
            on: () => {},
        },
        addEventListener: () => {},
        removeEventListener: () => {},
    } as any;
    globalThis.requestAnimationFrame = (callback: FrameRequestCallback) => {
        callback(0);
        return 0;
    };
    globalThis.Audio = class {
        pause() {}
        play() { return Promise.resolve(); }
    } as any;
});

describe('remoteAvailabilityBadgeText', () => {
    it('shows the DL possible badge for remote songs', async () => {
        const { remoteAvailabilityBadgeText } = await import('./element-factory.js');
        expect(remoteAvailabilityBadgeText({ syncAvailability: 'remote' })).toBe('DL可能');
        expect(remoteAvailabilityBadgeText({ syncAvailability: 'local' })).toBe('');
    });
});

describe('songPlayCountValue', () => {
    it('uses remote syncPlayCount metadata when no local path count exists', async () => {
        const { songPlayCountValue } = await import('./element-factory.js');
        expect(songPlayCountValue({ syncAvailability: 'remote', syncPlayCount: { count: 42 } }, {})).toBe(42);
        expect(songPlayCountValue({ path: '/music/local.flac', syncPlayCount: { count: 42 } }, { '/music/local.flac': { count: 7 } })).toBe(7);
    });
});

describe('resolveSongArtworkForList', () => {
    it('uses placeholder artwork for remote songs', async () => {
        const { DEFAULT_ARTWORK_URL } = await import('../constants/default-artwork.js');
        const { resolveSongArtworkForList } = await import('./element-factory.js');
        expect(resolveSongArtworkForList({ syncAvailability: 'remote', artwork: { full: 'remote.webp', thumbnail: 'remote-thumb.webp' } })).toBe(DEFAULT_ARTWORK_URL);
    });
});

describe('canStartPlayback', () => {
    it('excludes remote catalog songs from playback', async () => {
        const { canStartPlayback } = await import('../features/playback-manager.js');
        expect(canStartPlayback({ syncAvailability: 'remote', title: 'Remote' })).toBe(false);
        expect(canStartPlayback({ syncAvailability: 'local', path: '/Music/local.flac' })).toBe(true);
    });
});
