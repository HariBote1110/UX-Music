import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    playSong: vi.fn(),
    setupSongListScroller: vi.fn(() => ({ destroy: vi.fn() })),
    registerViewCleanup: vi.fn(),
    createCollectionShuffleControl: vi.fn(() => ({ element: document.createElement('button'), destroy: vi.fn() })),
}));

const albumsMap = new Map<string, any>();

vi.mock('../core/state.js', () => ({
    state: { albums: albumsMap },
    get elements() {
        return { mainContent: document.getElementById('main-content') };
    },
}));

vi.mock('../core/navigation.js', () => ({ showAlbum: vi.fn() }));
vi.mock('./detail-back-button.js', () => ({ prependDetailBackButton: vi.fn() }));
vi.mock('../features/playback-manager.js', () => ({ playSong: mocks.playSong }));
vi.mock('./element-factory.js', () => ({ createAlbumGridItem: vi.fn(() => document.createElement('div')) }));
vi.mock('./playlist-artwork.js', () => ({ createPlaylistArtwork: vi.fn() }));
vi.mock('./utils.js', () => ({
    formatTime: () => '0:00',
    resolveArtworkPath: () => '',
}));
vi.mock('./list-renderer.js', () => ({
    createListHeader: () => '',
    setupSongListScroller: mocks.setupSongListScroller,
    initListHeaderResizing: vi.fn(),
}));
vi.mock('./view-renderer.js', () => ({
    clearMainContent: vi.fn(),
    registerViewCleanup: mocks.registerViewCleanup,
}));
vi.mock('./ui.js', () => ({ updateListSpacer: vi.fn() }));
vi.mock('../core/library-model.js', () => ({
    getAlbumSongs: vi.fn(() => []),
    getArtistSongs: vi.fn(() => []),
    getArtistAlbums: vi.fn(() => []),
    setCurrentViewSongs: vi.fn(),
}));
vi.mock('./collection-shuffle-control.js', () => ({
    createCollectionShuffleControl: mocks.createCollectionShuffleControl,
}));

describe('detail-renderer のコレクション連携', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        albumsMap.clear();
        document.body.innerHTML = '<div id="main-content"></div>';
        (globalThis as any).window.observeNewArtworks = vi.fn();
    });

    it('アルバム詳細の「すべて再生」がアルバムキー付きの collection を渡す', async () => {
        const album = { title: 'Album A', artist: 'Artist A' };
        albumsMap.set('album-key-1', album);
        const { renderAlbumDetailView } = await import('./detail-renderer.js');

        renderAlbumDetailView(album);

        const btn = document.querySelector('.play-all-btn') as HTMLButtonElement;
        btn.click();

        expect(mocks.playSong).toHaveBeenCalledWith(0, [], false, { collection: { kind: 'album', key: 'album-key-1' } });
    });

    it('アルバム詳細ヘッダーに既定シャッフルコントロールを設置し、離脱時に破棄登録する', async () => {
        const album = { title: 'Album A', artist: 'Artist A' };
        albumsMap.set('album-key-1', album);
        const { renderAlbumDetailView } = await import('./detail-renderer.js');

        renderAlbumDetailView(album);

        expect(mocks.createCollectionShuffleControl).toHaveBeenCalledWith({ kind: 'album', key: 'album-key-1' });
        expect(mocks.registerViewCleanup).toHaveBeenCalledTimes(1);
        expect(document.querySelector('.detail-actions button:not(.play-all-btn)')).toBeTruthy();
    });

    it('プレイリスト詳細の「すべて再生」がプレイリスト名付きの collection を渡す', async () => {
        const { renderPlaylistDetailView } = await import('./detail-renderer.js');

        renderPlaylistDetailView({ name: '朝の曲', songs: [], artworks: [] });

        const btn = document.querySelector('.play-all-btn') as HTMLButtonElement;
        btn.click();

        expect(mocks.playSong).toHaveBeenCalledWith(0, [], false, { collection: { kind: 'playlist', key: '朝の曲' } });
        expect(mocks.createCollectionShuffleControl).toHaveBeenCalledWith({ kind: 'playlist', key: '朝の曲' });
    });
});
