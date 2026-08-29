import { beforeEach, describe, expect, it, vi } from 'vitest';

// 5つのタブ（曲/アルバム/アーティスト/For You/プレイリスト）がすべて同じ
// .view-header ラッパーを描画することを確認する回帰テスト。
// grid-renderer.ts / view-renderer.ts が依存する重い周辺モジュール
// （element-factory・playlist-artwork・bridge 等）はここではモックし、
// 「ヘッダー要素が存在するか」だけに焦点を当てる。

const mocks = vi.hoisted(() => ({
    getSituationPlaylists: vi.fn(async () => ({})),
    saveSettings: vi.fn(),
}));

vi.mock('../core/state.js', () => ({
    state: {
        albums: new Map(),
        artists: new Map(),
        playlists: [] as unknown[],
        library: [] as unknown[],
        selectedSongIds: new Set(),
        currentlyViewedSongIds: [] as unknown[],
    },
    get elements() {
        return { mainContent: document.getElementById('main-content') };
    },
}));

vi.mock('../features/player.js', () => ({
    setVisualizerTarget: vi.fn(),
    disconnectVisualizerObserver: vi.fn(),
}));

vi.mock('./list-renderer.js', () => ({
    createListHeader: vi.fn(() => ''),
    setupSongListScroller: vi.fn(),
    initListHeaderResizing: vi.fn(),
}));

vi.mock('./detail-renderer.js', () => ({
    renderAlbumDetailView: vi.fn(),
    renderArtistDetailView: vi.fn(),
    renderPlaylistDetailView: vi.fn(),
}));

vi.mock('./element-factory.js', () => ({
    createAlbumGridItem: vi.fn(() => document.createElement('div')),
    createArtistGridItem: vi.fn(() => document.createElement('div')),
    createPlaylistGridItem: vi.fn(() => document.createElement('div')),
}));

vi.mock('./playlist-artwork.js', () => ({
    createPlaylistArtwork: vi.fn(),
}));

vi.mock('./utils.js', () => ({
    showContextMenu: vi.fn(),
    resolveArtworkPath: vi.fn(() => ''),
    escapeHtml: (s: string) => s,
}));

vi.mock('./modal.js', () => ({ showModal: vi.fn() }));
vi.mock('./notification.js', () => ({ showNotification: vi.fn(), hideNotification: vi.fn() }));

vi.mock('../core/bridge.js', () => ({
    musicApi: {
        getSituationPlaylists: mocks.getSituationPlaylists,
        saveSettings: mocks.saveSettings,
    },
    getWailsApp: vi.fn(),
}));

vi.mock('../core/library-model.js', () => ({
    getAlbumSongs: vi.fn(() => []),
    setCurrentViewSongs: vi.fn(),
}));

vi.mock('./album-order-editor.js', () => ({ openAlbumOrderEditor: vi.fn() }));

vi.mock('../core/navigation.js', () => ({
    showAlbum: vi.fn(),
    showArtist: vi.fn(),
    showPlaylist: vi.fn(),
    showSituationPlaylistDetail: vi.fn(),
}));

beforeEach(() => {
    vi.clearAllMocks();
    document.body.innerHTML = '<div id="main-content"></div>';
    (window as unknown as { observeNewArtworks: unknown }).observeNewArtworks = vi.fn();
});

describe('全タブ共通の .view-header ラッパー', () => {
    it('曲タブ (renderTrackView)', async () => {
        const { renderTrackView } = await import('./view-renderer.js');
        renderTrackView();
        expect(document.querySelector('#main-content .view-header')).not.toBeNull();
    });

    it('アルバムタブ (renderAlbumView)', async () => {
        const { renderAlbumView } = await import('./grid-renderer.js');
        renderAlbumView();
        expect(document.querySelector('#main-content .view-header')).not.toBeNull();
    });

    it('アーティストタブ (renderArtistView)', async () => {
        const { renderArtistView } = await import('./grid-renderer.js');
        renderArtistView();
        expect(document.querySelector('#main-content .view-header')).not.toBeNull();
    });

    it('For You タブ (renderSituationView)', async () => {
        const { renderSituationView } = await import('./grid-renderer.js');
        await renderSituationView();
        expect(document.querySelector('#main-content .view-header')).not.toBeNull();
    });

    it('プレイリストタブ (renderPlaylistView)', async () => {
        const { renderPlaylistView } = await import('./grid-renderer.js');
        renderPlaylistView();
        expect(document.querySelector('#main-content .view-header')).not.toBeNull();
    });
});
