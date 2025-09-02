// uxmusic/src/main/handlers/playlist-handler.js

const { ipcMain } = require('electron');
const playlistManager = require('../playlist-manager');

let libraryStore;
let albumsStore;

function getPlaylistsWithArtwork() {
    const playlistNames = playlistManager.getAllPlaylists();
    const mainLibrary = libraryStore.load() || [];
    const albumsData = albumsStore.load() || {};
    const albumsMap = new Map(Object.entries(albumsData));
    const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));

    return playlistNames.map(name => {
        const songPaths = playlistManager.getPlaylistSongs(name);
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
    });
}

function registerPlaylistHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;
    albumsStore = stores.albums;

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
    
    ipcMain.handle('get-playlist-details', (event, playlistName) => {
        const songPaths = playlistManager.getPlaylistSongs(playlistName);
        if (!songPaths || songPaths.length === 0) {
            return { name: playlistName, songs: [], artworks: [] };
        }

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
    ipcMain.handle('add-album-to-playlist', (event, { songPaths, playlistName }) => {
        const library = libraryStore.load() || [];
        const libraryMap = new Map(library.map(song => [song.path, song]));
        
        const songsToAdd = songPaths.map(p => libraryMap.get(p)).filter(Boolean);

        if (songsToAdd.length > 0) {
            const result = playlistManager.addSongsToPlaylist(playlistName, songsToAdd);
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