// uxmusic/src/main/handlers/playlist-handler.js

const { ipcMain } = require('electron');
const playlistManager = require('../playlist-manager');

let libraryStore;

function getPlaylistsWithArtwork() {
    const playlistNames = playlistManager.getAllPlaylists();
    const mainLibrary = libraryStore.load() || [];
    const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));

    return playlistNames.map(name => {
        const songPaths = playlistManager.getPlaylistSongs(name);
        const artworks = songPaths
            .map(path => libraryMap.get(path))
            .filter(song => song && song.artwork)
            .slice(0, 4)
            .map(song => song.artwork);
        return { name, artworks };
    });
}

function registerPlaylistHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;

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

    // ▼▼▼ ここからが修正箇所です ▼▼▼
    ipcMain.handle('add-album-to-playlist', (event, { albumKey, playlistName }) => {
        const library = libraryStore.load() || [];
        const songsToAdd = library.filter(song => song.albumKey === albumKey);
        
        if (songsToAdd.length > 0) {
            const result = playlistManager.addSongsToPlaylist(playlistName, songsToAdd);
            // 曲を追加した後、UIのプレイリストアートワークを更新するために通知
            if (result.success && result.addedCount > 0) {
                sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
            }
            return result;
        }
        return { success: true, addedCount: 0 };
    });
    // ▲▲▲ ここまでが修正箇所です ▲▲▲
}

module.exports = { registerPlaylistHandlers, getPlaylistsWithArtwork };