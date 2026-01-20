const { ipcMain } = require('electron');
const playlistManager = require('../playlist-manager');
const IPC_CHANNELS = require('../ipc-channels');

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

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_ALL_PLAYLISTS, () => {
        return playlistManager.getAllPlaylists();
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_PLAYLIST_SONGS, async (event, playlistName) => {
        const songPaths = playlistManager.getPlaylistSongs(playlistName);
        if (!songPaths || songPaths.length === 0) return [];

        const mainLibrary = libraryStore.load() || [];
        const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));
        const songs = songPaths.map(path => libraryMap.get(path)).filter(Boolean);
        return songs;
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_PLAYLIST_DETAILS, (event, playlistName) => {
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

    ipcMain.handle(IPC_CHANNELS.INVOKE.CREATE_PLAYLIST, (event, name) => {
        const result = playlistManager.createPlaylist(name);
        if (result.success) {
            sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
        }
        return result;
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.DELETE_PLAYLIST, (event, name) => {
        const result = playlistManager.deletePlaylist(name);
        if (result.success) {
            sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
        }
        return result;
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.UPDATE_PLAYLIST_SONG_ORDER, (event, { playlistName, newOrder }) => {
        return playlistManager.updateSongOrderInPlaylist(playlistName, newOrder);
    });

    ipcMain.on(IPC_CHANNELS.SEND.REQUEST_PLAYLISTS_WITH_ARTWORK, (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.RENAME_PLAYLIST, (event, { oldName, newName }) => {
        const result = playlistManager.renamePlaylist(oldName, newName);
        if (result.success) {
            sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
        }
        return result;
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.ADD_ALBUM_TO_PLAYLIST, (event, { songPaths, playlistName }) => {
        const library = libraryStore.load() || [];
        const libraryMap = new Map(library.map(song => [song.path, song]));

        const songsToAdd = songPaths.map(p => libraryMap.get(p)).filter(Boolean);

        if (songsToAdd.length > 0) {
            const result = playlistManager.addSongsToPlaylist(playlistName, songsToAdd);
            if (result.success && result.addedCount > 0) {
                sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
            }
            return result;
        }
        return { success: true, addedCount: 0 };
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.ADD_SONGS_TO_PLAYLIST, (event, { songIds, playlistName }) => {
        const library = libraryStore.load() || [];
        const libraryMap = new Map(library.map(song => [song.id, song]));

        const songsToAdd = songIds.map(id => libraryMap.get(id)).filter(Boolean);

        if (songsToAdd.length > 0) {
            const result = playlistManager.addSongsToPlaylist(playlistName, songsToAdd);
            if (result.success && result.addedCount > 0) {
                sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
            }
            return result;
        }
        return { success: true, addedCount: 0 };
    });
}

module.exports = { registerPlaylistHandlers, getPlaylistsWithArtwork };