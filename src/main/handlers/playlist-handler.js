// uxmusic/src/main/handlers/playlist-handler.js

const { ipcMain } = require('electron');
const playlistManager = require('../playlist-manager');

let libraryStore;
let albumsStore; // ★★★ 修正点: albumsStore変数を追加 ★★★

function getPlaylistsWithArtwork() {
    const playlistNames = playlistManager.getAllPlaylists();
    const mainLibrary = libraryStore.load() || [];
    // ▼▼▼ ここからが修正箇所です ▼▼▼
    const albumsData = albumsStore.load() || {};
    const albumsMap = new Map(Object.entries(albumsData));
    const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));

    return playlistNames.map(name => {
        const songPaths = playlistManager.getPlaylistSongs(name);
        const artworks = songPaths
            .map(path => libraryMap.get(path)) // 曲のパスから曲オブジェクトを取得
            .filter(Boolean) // ライブラリに見つからない曲を除外
            .map(song => {
                // 曲のalbumKeyを使ってアルバム情報を検索し、アートワークを取得
                if (song.albumKey) {
                    const album = albumsMap.get(song.albumKey);
                    return album ? album.artwork : null;
                }
                // 念の為、古い形式のデータにも対応
                return song.artwork;
            })
            .filter(Boolean) // アートワークがなかったものを除外
            .slice(0, 4); // 先頭4つだけ取得
        return { name, artworks };
    });
    // ▲▲▲ ここまでが修正箇所です ▲▲▲
}

function registerPlaylistHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;
    albumsStore = stores.albums; // ★★★ 修正点: albumsStoreを初期化 ★★★

    ipcMain.handle('get-all-playlists', () => {
        return playlistManager.getAllPlaylists();
    });

    ipcMain.handle('get-playlist-songs', async (event, playlistName) => {
        const songPaths = playlistManager.getPlaylistSongs(playlistName);
        if (!songPaths || songPaths.length === 0) return [];
        
        const mainLibrary = libraryStore.load() || [];
        const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));
        const songs = songPaths.map(path => libraryMap.get(path)).filter(Boolean);
        return songs;
    });

    ipcMain.handle('create-playlist', (event, name) => {
        const result = playlistManager.createPlaylist(name);
        if (result.success) {
            sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
        }
        return result;
    });

    ipcMain.handle('delete-playlist', (event, name) => {
        const result = playlistManager.deletePlaylist(name);
        if (result.success) {
            sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
        }
        return result;
    });

    ipcMain.handle('update-playlist-song-order', (event, { playlistName, newOrder }) => {
        return playlistManager.updateSongOrderInPlaylist(playlistName, newOrder);
    });
    
    ipcMain.on('request-playlists-with-artwork', (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
             event.sender.send('playlists-updated', getPlaylistsWithArtwork());
        }
    });

    ipcMain.handle('rename-playlist', (event, { oldName, newName }) => {
        const result = playlistManager.renamePlaylist(oldName, newName);
        if (result.success) {
            sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
        }
        return result;
    });

    ipcMain.handle('add-album-to-playlist', (event, { albumKey, playlistName }) => {
        const library = libraryStore.load() || [];
        const songsToAdd = library.filter(song => song.albumKey === albumKey);
        
        if (songsToAdd.length > 0) {
            const result = playlistManager.addSongsToPlaylist(playlistName, songsToAdd);
            if (result.success && result.addedCount > 0) {
                sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
            }
            return result;
        }
        return { success: true, addedCount: 0 };
    });
}

module.exports = { registerPlaylistHandlers, getPlaylistsWithArtwork };