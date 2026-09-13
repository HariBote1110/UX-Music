import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    showContextMenu: vi.fn(),
    buildShufflePreferenceMenuItems: vi.fn(() => [{ label: '既定のシャッフル項目' }]),
}));

const state: any = {
    albums: new Map(),
    artists: new Map(),
    playlists: [] as any[],
};

vi.mock('../core/state.js', () => ({ state }));
vi.mock('../core/navigation.js', () => ({
    showAlbum: vi.fn(),
    showArtist: vi.fn(),
    showPlaylist: vi.fn(),
    showSituationPlaylistDetail: vi.fn(),
}));
vi.mock('./element-factory.js', () => ({
    createAlbumGridItem: vi.fn(() => document.createElement('div')),
    createArtistGridItem: vi.fn(() => document.createElement('div')),
    createPlaylistGridItem: vi.fn(() => document.createElement('div')),
}));
vi.mock('./playlist-artwork.js', () => ({ createPlaylistArtwork: vi.fn() }));
vi.mock('./utils.js', () => ({
    showContextMenu: mocks.showContextMenu,
    resolveArtworkPath: vi.fn(() => ''),
    escapeHtml: (s: string) => s,
}));
vi.mock('./modal.js', () => ({ showModal: vi.fn() }));
vi.mock('./notification.js', () => ({ showNotification: vi.fn(), hideNotification: vi.fn() }));
vi.mock('./view-renderer.js', () => ({ clearMainContent: vi.fn() }));
vi.mock('../core/bridge.js', () => ({ musicApi: { addSongsToPlaylist: vi.fn() } }));
vi.mock('../core/library-model.js', () => ({
    getAlbumSongs: vi.fn(() => []),
    setCurrentViewSongs: vi.fn(),
}));
vi.mock('./album-order-editor.js', () => ({ openAlbumOrderEditor: vi.fn() }));
vi.mock('./grid-density.js', () => ({ createGridDensityControl: vi.fn(() => document.createElement('div')) }));
vi.mock('./collection-shuffle-control.js', () => ({
    buildShufflePreferenceMenuItems: mocks.buildShufflePreferenceMenuItems,
}));

describe('grid-renderer の既定シャッフルメニュー', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        state.albums = new Map([['album-key-1', { title: 'Album A' }]]);
        state.playlists = [{ name: '朝の曲' }];
        document.body.innerHTML = '<div id="main-content"></div>';
        (globalThis as any).window.observeNewArtworks = vi.fn();
    });

    it('アルバムグリッドの右クリックメニューに「既定のシャッフル」submenu を album key 付きで追加する', async () => {
        const { renderAlbumView } = await import('./grid-renderer.js');
        renderAlbumView();

        const albumItem = document.querySelector('#album-grid > div') as HTMLElement;
        albumItem.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));

        const menuItems = mocks.showContextMenu.mock.calls[0][2];
        const shuffleItem = menuItems.find((i: any) => i.label === '既定のシャッフル');
        expect(shuffleItem).toBeTruthy();
        expect(mocks.buildShufflePreferenceMenuItems).toHaveBeenCalledWith({ kind: 'album', key: 'album-key-1' });
    });

    it('プレイリストグリッドの右クリックメニューに「既定のシャッフル」submenu をプレイリスト名付きで追加する', async () => {
        const { renderPlaylistView } = await import('./grid-renderer.js');
        renderPlaylistView();

        const playlistItem = document.querySelector('#playlist-grid > div') as HTMLElement;
        playlistItem.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));

        const menuItems = mocks.showContextMenu.mock.calls[0][2];
        const shuffleItem = menuItems.find((i: any) => i.label === '既定のシャッフル');
        expect(shuffleItem).toBeTruthy();
        expect(mocks.buildShufflePreferenceMenuItems).toHaveBeenCalledWith({ kind: 'playlist', key: '朝の曲' });
    });
});
