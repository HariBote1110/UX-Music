import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    addSongsToPlaylist: vi.fn(),
    showNotification: vi.fn(),
}));

vi.mock('../core/state.js', () => ({
    state: {
        selectedSongIds: new Set<string>(),
        playbackQueue: [],
        currentSongIndex: -1,
        playlists: [],
        libraryById: new Map(),
    },
    elements: {},
}));

vi.mock('../features/playback-manager.js', () => ({ playSong: vi.fn() }));
vi.mock('../features/player.js', () => ({ setVisualizerTarget: vi.fn() }));
vi.mock('./virtual-scroller.js', () => ({ VirtualScroller: vi.fn() }));
vi.mock('./element-factory.js', () => ({ createSongItem: vi.fn(() => document.createElement('div')) }));
vi.mock('./column-resizer.js', () => ({ initColumnResizing: vi.fn(), updateGridStyle: vi.fn() }));
vi.mock('./utils.js', () => ({ showContextMenu: vi.fn() }));
vi.mock('./modal.js', () => ({ showModalAdvanced: vi.fn() }));
vi.mock('./column-config.js', () => ({
    getVisibleColumns: vi.fn(() => []),
    getGridTemplate: vi.fn(() => ''),
    showColumnContextMenu: vi.fn(),
}));
vi.mock('./notification.js', () => ({
    showNotification: mocks.showNotification,
    hideNotification: vi.fn(),
}));
vi.mock('../core/bridge.js', () => ({
    musicApi: {
        addSongsToPlaylist: mocks.addSongsToPlaylist,
    },
    getWailsApp: vi.fn(),
}));

describe('list-renderer playlist context actions', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        globalThis.window = {
            electronAPI: { send: vi.fn() },
        } as any;
    });

    it('Wails の AddSongsToPlaylist が要求する曲メタデータ payload を作る', async () => {
        const { playlistAddPayloadForSongs } = await import('./list-renderer.js');

        expect(playlistAddPayloadForSongs('朝の曲', [
            { path: '/music/a.flac', duration: 123, artist: 'artist a', title: 'title a' },
            { id: 'remote-only', title: 'remote' },
        ])).toEqual({
            playlistName: '朝の曲',
            songs: [
                { path: '/music/a.flac', duration: 123, artist: 'artist a', title: 'title a' },
            ],
        });
    });

    it('右クリックメニューからプレイリスト追加 API を呼び出す', async () => {
        mocks.addSongsToPlaylist.mockResolvedValueOnce(2);
        const { addSongsToPlaylistFromMenu } = await import('./list-renderer.js');

        await addSongsToPlaylistFromMenu('朝の曲', [
            { path: '/music/a.flac', duration: 123, artist: 'artist a', title: 'title a' },
            { path: '/music/b.flac', duration: 234, artist: 'artist b', title: 'title b' },
        ]);

        expect(mocks.addSongsToPlaylist).toHaveBeenCalledWith({
            playlistName: '朝の曲',
            songs: [
                { path: '/music/a.flac', duration: 123, artist: 'artist a', title: 'title a' },
                { path: '/music/b.flac', duration: 234, artist: 'artist b', title: 'title b' },
            ],
        });
        expect(mocks.showNotification).toHaveBeenCalledWith('2曲をプレイリスト「朝の曲」に追加しました。', 3000);
    });
});

describe('list-renderer のコレクション付き再生', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        globalThis.window = {
            electronAPI: { send: vi.fn() },
            observeNewArtworks: vi.fn(),
        } as any;
    });

    it('アルバム詳細のリスト行クリックは album collection を伴って再生する', async () => {
        const { createSongItem } = await import('./element-factory.js');
        (createSongItem as any).mockImplementation(() => document.createElement('div'));
        const { playSong } = await import('../features/playback-manager.js');
        const { setupSongListScroller } = await import('./list-renderer.js');
        const { VirtualScroller } = await import('./virtual-scroller.js');
        const songList = [{ id: 's1', title: 'A' }];

        setupSongListScroller(document.createElement('div'), songList, { contextView: 'album', albumKey: 'album-key-1' });
        const renderItem = (VirtualScroller as any).mock.calls[0][0].renderItem;
        const songItem = renderItem(songList[0], 0);
        songItem.dispatchEvent(new MouseEvent('click'));

        expect(playSong).toHaveBeenCalledWith(0, songList, false, { collection: { kind: 'album', key: 'album-key-1' } });
    });

    it('プレイリスト詳細のリスト行クリックは playlist collection を伴って再生する', async () => {
        const { createSongItem } = await import('./element-factory.js');
        (createSongItem as any).mockImplementation(() => document.createElement('div'));
        const { playSong } = await import('../features/playback-manager.js');
        const { setupSongListScroller } = await import('./list-renderer.js');
        const { VirtualScroller } = await import('./virtual-scroller.js');
        const songList = [{ id: 's1', title: 'A' }];

        setupSongListScroller(document.createElement('div'), songList, { contextView: 'playlist', playlistName: '朝の曲' });
        const renderItem = (VirtualScroller as any).mock.calls[0][0].renderItem;
        const songItem = renderItem(songList[0], 0);
        songItem.dispatchEvent(new MouseEvent('click'));

        expect(playSong).toHaveBeenCalledWith(0, songList, false, { collection: { kind: 'playlist', key: '朝の曲' } });
    });

    it('右クリックメニューの「再生」も album collection を伴って再生する', async () => {
        const { createSongItem } = await import('./element-factory.js');
        (createSongItem as any).mockImplementation(() => document.createElement('div'));
        const { playSong } = await import('../features/playback-manager.js');
        const { showContextMenu } = await import('./utils.js');
        const { setupSongListScroller } = await import('./list-renderer.js');
        const { VirtualScroller } = await import('./virtual-scroller.js');
        const songList = [{ id: 's1', title: 'A' }];

        setupSongListScroller(document.createElement('div'), songList, { contextView: 'album', albumKey: 'album-key-1' });
        const renderItem = (VirtualScroller as any).mock.calls[0][0].renderItem;
        const songItem = renderItem(songList[0], 0);
        songItem.dispatchEvent(new MouseEvent('contextmenu'));

        const menuItems = (showContextMenu as any).mock.calls[0][2];
        menuItems.find((i: any) => i.label === '再生').action();

        expect(playSong).toHaveBeenCalledWith(0, songList, false, { collection: { kind: 'album', key: 'album-key-1' } });
    });

    it('queue-view 由来（contextView 未指定）では collection を付けずに再生する', async () => {
        const { createSongItem } = await import('./element-factory.js');
        (createSongItem as any).mockImplementation(() => document.createElement('div'));
        const { playSong } = await import('../features/playback-manager.js');
        const { setupSongListScroller } = await import('./list-renderer.js');
        const { VirtualScroller } = await import('./virtual-scroller.js');
        const songList = [{ id: 's1', title: 'A' }];

        setupSongListScroller(document.createElement('div'), songList, {});
        const renderItem = (VirtualScroller as any).mock.calls[0][0].renderItem;
        const songItem = renderItem(songList[0], 0);
        songItem.dispatchEvent(new MouseEvent('click'));

        expect(playSong).toHaveBeenCalledWith(0, songList, false, {});
    });
});
