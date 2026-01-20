const { ipcMain } = require('electron');
const sidecarManager = require('../sidecar-manager'); // ★★★ Go Sidecar manager ★★★
const IPC_CHANNELS = require('../ipc-channels');

let libraryStore;
let albumsStore;

// Node.js 版の playlistManager はもう使わないが、アートワーク解決のために
// ライブラリデータは Electron 側で保持している必要がある。

async function getPlaylistsWithArtwork() {
    try {
        // Go からプレイリスト名のリストを取得
        const playlistNames = await sidecarManager.invoke('get-all-playlists');
        if (!Array.isArray(playlistNames)) {
            return [];
        }

        // ライブラリデータをロード (Electron側)
        const mainLibrary = libraryStore.load() || [];
        const albumsData = albumsStore.load() || {};
        const albumsMap = new Map(Object.entries(albumsData));
        const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));

        // 各プレイリストについて、先頭4曲のアートワークを取得
        // ※ ここでも曲リストを Go から取得する必要があるため、非同期処理が必要
        // Promise.all で並列処理
        const playlists = await Promise.all(playlistNames.map(async (name) => {
            try {
                const songPaths = await sidecarManager.invoke('get-playlist-songs', { name });

                const artworks = songPaths
                    .map(path => libraryMap.get(path))
                    .filter(Boolean)
                    .map(song => {
                        if (song.albumKey) {
                            const album = albumsMap.get(song.albumKey);
                            return album ? album.artwork : null;
                        }
                        return song.artwork;
                    })
                    .filter(Boolean)
                    .slice(0, 4);

                return { name, artworks };
            } catch (e) {
                console.error(`Failed to get details for playlist ${name}:`, e);
                return { name, artworks: [] };
            }
        }));

        return playlists;
    } catch (error) {
        console.error('Failed to get playlists with artwork:', error);
        return [];
    }
}

function registerPlaylistHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;
    albumsStore = stores.albums;

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_ALL_PLAYLISTS, async () => {
        try {
            return await sidecarManager.invoke('get-all-playlists');
        } catch (error) {
            console.error('Failed to get all playlists:', error);
            return [];
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_PLAYLIST_SONGS, async (event, playlistName) => {
        try {
            const songPaths = await sidecarManager.invoke('get-playlist-songs', { name: playlistName });
            if (!songPaths || songPaths.length === 0) return [];

            const mainLibrary = libraryStore.load() || [];
            const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));
            const songs = songPaths.map(path => libraryMap.get(path)).filter(Boolean);
            return songs;
        } catch (error) {
            console.error(`Failed to get songs for playlist ${playlistName}:`, error);
            return [];
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_PLAYLIST_DETAILS, async (event, playlistName) => {
        try {
            const songPaths = await sidecarManager.invoke('get-playlist-songs', { name: playlistName });
            const mainLibrary = libraryStore.load() || [];
            const albumsData = albumsStore.load() || {};
            const albumsMap = new Map(Object.entries(albumsData));
            const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));

            const songs = songPaths.map(path => libraryMap.get(path)).filter(Boolean);
            const artworks = songs
                .map(song => {
                    if (song.albumKey) {
                        const album = albumsMap.get(song.albumKey);
                        return album ? album.artwork : null;
                    }
                    return song.artwork;
                })
                .filter(Boolean)
                .slice(0, 4);

            return { name: playlistName, songs, artworks };
        } catch (error) {
            console.error(`Failed to get playlist details ${playlistName}:`, error);
            return { name: playlistName, songs: [], artworks: [] };
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.CREATE_PLAYLIST, async (event, name) => {
        try {
            await sidecarManager.invoke('create-playlist', { name });
            const playlists = await getPlaylistsWithArtwork();
            sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, playlists);
            return { success: true, name };
        } catch (error) {
            return { success: false, message: error.message };
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.DELETE_PLAYLIST, async (event, name) => {
        try {
            await sidecarManager.invoke('delete-playlist', { name });
            const playlists = await getPlaylistsWithArtwork();
            sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, playlists);
            return { success: true };
        } catch (error) {
            return { success: false, message: error.message };
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.UPDATE_PLAYLIST_SONG_ORDER, async (event, { playlistName, newOrder }) => {
        try {
            await sidecarManager.invoke('update-playlist-order', { name: playlistName, paths: newOrder });
            return { success: true };
        } catch (error) {
            return { success: false, message: error.message };
        }
    });

    ipcMain.on(IPC_CHANNELS.SEND.REQUEST_PLAYLISTS_WITH_ARTWORK, async (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            const playlists = await getPlaylistsWithArtwork();
            event.sender.send(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, playlists);
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.RENAME_PLAYLIST, async (event, { oldName, newName }) => {
        try {
            await sidecarManager.invoke('rename-playlist', { oldName, newName });
            const playlists = await getPlaylistsWithArtwork();
            sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, playlists);
            return { success: true };
        } catch (error) {
            return { success: false, message: error.message };
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.ADD_ALBUM_TO_PLAYLIST, async (event, { songPaths, playlistName }) => {
        return await addSongsToPlaylistCommon(songPaths, playlistName, sendToAllWindows);
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.ADD_SONGS_TO_PLAYLIST, async (event, { songIds, playlistName }) => {
        // IDからパスへの変換が必要
        const library = libraryStore.load() || [];
        const libraryMap = new Map(library.map(song => [song.id, song]));
        const songsToAdd = songIds.map(id => libraryMap.get(id)).filter(Boolean);
        const paths = songsToAdd.map(s => s.path);

        return await addSongsToPlaylistCommon(paths, playlistName, sendToAllWindows);
    });
}

// 共通処理 Helper
async function addSongsToPlaylistCommon(songPaths, playlistName, sendToAllWindows) {
    if (!songPaths || songPaths.length === 0) return { success: true, addedCount: 0 };

    const library = libraryStore.load() || [];
    const libraryMap = new Map(library.map(song => [song.path, song]));

    // Go 側に送るための SongToAdd 構造体を作成
    const songsToSend = songPaths.map(p => {
        const s = libraryMap.get(p);
        if (!s) return null;
        return {
            path: s.path,
            duration: s.duration,
            artist: s.artist,
            title: s.title
        };
    }).filter(Boolean);

    try {
        const result = await sidecarManager.invoke('add-songs-to-playlist', {
            name: playlistName,
            songs: songsToSend
        });

        // result.count で追加数を確認可能
        // 成功したらUI更新
        const playlists = await getPlaylistsWithArtwork();
        sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, playlists);

        return { success: true, addedCount: result.count };
    } catch (error) {
        return { success: false, message: error.message };
    }
}

module.exports = { registerPlaylistHandlers, getPlaylistsWithArtwork };