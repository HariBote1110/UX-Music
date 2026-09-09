import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    showView: vi.fn(),
    setAudioOutput: vi.fn(),
    setVisualizerTarget: vi.fn(),
    playSong: vi.fn(),
    createQueueItem: vi.fn(),
    showContextMenu: vi.fn(),
    formatBytes: vi.fn(),
    showNotification: vi.fn(),
    hideNotification: vi.fn(),
    loadNormalizedSettings: vi.fn(),
}));

vi.mock('../features/playback-manager.js', () => ({ playSong: mocks.playSong }));
vi.mock('../features/player.js', () => ({
    setAudioOutput: mocks.setAudioOutput,
    setVisualizerTarget: mocks.setVisualizerTarget,
}));
vi.mock('./element-factory.js', () => ({ createQueueItem: mocks.createQueueItem }));
vi.mock('../core/navigation.js', () => ({ showView: mocks.showView }));
vi.mock('../core/bridge.js', () => ({
    getWailsApp: vi.fn(),
    isWailsMode: vi.fn(),
}));
vi.mock('./utils.js', () => ({
    showContextMenu: mocks.showContextMenu,
    formatBytes: mocks.formatBytes,
}));
vi.mock('./notification.js', () => ({
    showNotification: mocks.showNotification,
    hideNotification: mocks.hideNotification,
}));
vi.mock('../core/settings-helpers.js', () => ({ loadNormalizedSettings: mocks.loadNormalizedSettings }));

describe('addSongsToLibrary', () => {
    let electronAPI: { send: ReturnType<typeof vi.fn> };

    beforeEach(() => {
        electronAPI = { send: vi.fn() };
        Object.defineProperty(window, 'electronAPI', {
            configurable: true,
            value: electronAPI,
        });
    });

    it('増分追加の YouTube 曲に URL の artwork があっても既存曲の artwork を削除しない', async () => {
        const { state } = await import('../core/state.js');
        const { addSongsToLibrary } = await import('./ui-manager.js');
        const existingArtwork = { full: 'existing.webp', thumbnail: 'existing_thumb.webp' };

        state.library = [{
            id: 'existing-song',
            path: '/Music/existing.flac',
            title: 'Existing',
            artist: 'Artist',
            album: 'Album',
            artwork: existingArtwork,
        }];
        state.libraryById = new Map();
        state.libraryByPath = new Map();
        state.albums = new Map();
        state.artists = new Map();

        addSongsToLibrary({
            songs: [{
                id: 'youtube-song',
                path: '/Music/youtube.m4a',
                title: 'YouTube',
                artist: 'YouTube Artist',
                album: 'YouTube',
                sourceURL: 'https://www.youtube.com/watch?v=example',
                artwork: 'https://i.ytimg.com/vi/example/hqdefault.jpg',
            }],
            albums: {},
            skipRender: true,
        });

        expect(state.library[0].artwork).toBe(existingArtwork);
        expect(state.library[1].artwork).toBe('https://i.ytimg.com/vi/example/hqdefault.jpg');
        expect(electronAPI.send).not.toHaveBeenCalled();
    });

    it('全ライブラリのロードでも YouTube の URL artwork を旧形式移行で削除しない', async () => {
        const { state } = await import('../core/state.js');
        const { addSongsToLibrary } = await import('./ui-manager.js');

        state.library = [];
        state.libraryById = new Map();
        state.libraryByPath = new Map();
        state.albums = new Map();
        state.artists = new Map();

        const artwork = 'https://i.ytimg.com/vi/example/hqdefault.jpg';
        addSongsToLibrary({
            songs: [{
                id: 'youtube-song',
                path: 'https://www.youtube.com/watch?v=example',
                title: 'YouTube',
                artist: 'YouTube Artist',
                album: 'YouTube',
                sourceURL: 'https://www.youtube.com/watch?v=example',
                artwork,
            }],
            albums: {},
            isFullLibraryLoad: true,
            skipRender: true,
        });

        expect(state.library[0].artwork).toBe(artwork);
    });

    it('旧形式のローカル artwork が混在する全ロードでも YouTube URL を保持する', async () => {
        const { state } = await import('../core/state.js');
        const { addSongsToLibrary } = await import('./ui-manager.js');

        state.library = [];
        state.libraryById = new Map();
        state.libraryByPath = new Map();
        state.albums = new Map();
        state.artists = new Map();

        const artwork = 'https://i.ytimg.com/vi/example/hqdefault.jpg';
        addSongsToLibrary({
            songs: [
                {
                    id: 'legacy-song',
                    path: '/Music/legacy.flac',
                    title: 'Legacy',
                    artist: 'Artist',
                    album: 'Album',
                    artwork: 'legacy.webp',
                },
                {
                    id: 'youtube-song',
                    path: '/Music/youtube.m4a',
                    title: 'YouTube',
                    artist: 'YouTube Artist',
                    album: 'YouTube',
                    sourceURL: 'https://www.youtube.com/watch?v=example',
                    artwork,
                },
            ],
            albums: {},
            isFullLibraryLoad: true,
            skipRender: true,
        });

        expect(state.library[0].artwork).toBeUndefined();
        expect(state.library[1].artwork).toBe(artwork);
    });
});
