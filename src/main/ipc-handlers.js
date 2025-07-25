const { BrowserWindow } = require('electron');
const DataStore = require('./data-store');
const playlistManager = require('./playlist-manager');

const { registerLibraryHandlers } = require('./handlers/library-handler');
const { registerYouTubeHandlers } = require('./handlers/youtube-handler');
const { registerPlaylistHandlers } = require('./handlers/playlist-handler');
const { registerSystemHandlers } = require('./handlers/system-handler');
const { registerContextMenuHandlers } = require('./handlers/context-menu-handler');

let stores = {};

function registerIpcHandlers() {
    stores.playCounts = new DataStore('playcounts.json');
    stores.settings = new DataStore('settings.json');
    stores.library = new DataStore('library.json');
    stores.loudness = new DataStore('loudness.json');

    // ★★★ 不要になったfindHubUrlを削除 ★★★

    const sendToAllWindows = (channel, ...args) => {
        BrowserWindow.getAllWindows().forEach(win => {
            if (win && !win.isDestroyed()) {
                win.webContents.send(channel, ...args);
            }
        });
    };
    
    const addSongsToLibraryAndSave = (newSongs) => {
        const library = stores.library.load() || [];
        const existingPaths = new Set(library.map(s => s.path));
        const uniqueNewSongs = newSongs.filter(s => !existingPaths.has(s.path));
        if (uniqueNewSongs.length > 0) {
            const updatedLibrary = library.concat(uniqueNewSongs);
            stores.library.save(updatedLibrary);
        }
        return uniqueNewSongs;
    };

    registerLibraryHandlers(stores);
    registerYouTubeHandlers(stores, { playlist: playlistManager, addSongsFunc: addSongsToLibraryAndSave });
    registerPlaylistHandlers(stores, sendToAllWindows);
    registerSystemHandlers(stores);
    registerContextMenuHandlers(stores, sendToAllWindows);
}

module.exports = { registerIpcHandlers };