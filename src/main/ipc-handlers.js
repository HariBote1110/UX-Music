const { BrowserWindow, ipcMain } = require('electron');
const DataStore = require('./data-store');
const playlistManager = require('./playlist-manager');
const { performance } = require('perf_hooks');
const fs = require('fs');

const logPerf = (message) => {
    console.log(`[PERF][IPC-Handlers] ${message}`);
};

let stores = {};

function registerIpcHandlers() {
    logPerf("Registering handlers starts...");
    
    stores.playCounts = new DataStore('playcounts.json');
    stores.settings = new DataStore('settings.json');
    stores.library = new DataStore('library.json');
    stores.loudness = new DataStore('loudness.json');
    stores.albums = new DataStore('albums.json');
    logPerf("DataStores initialized.");

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

    ipcMain.on('save-migrated-data', (event, { songs, albums }) => {
        console.log('Main: Saving migrated library and albums data...');
        try {
            const libraryPath = stores.library.path;
            const albumsPath = stores.albums.path;

            if (fs.existsSync(libraryPath)) {
                fs.copyFileSync(libraryPath, libraryPath + '.bak');
                console.log(`[Backup] library.json backed up to ${libraryPath}.bak`);
            }
            if (fs.existsSync(albumsPath)) {
                fs.copyFileSync(albumsPath, albumsPath + '.bak');
                console.log(`[Backup] albums.json backed up to ${albumsPath}.bak`);
            }

            stores.library.save(songs);
            stores.albums.save(albums);
            console.log('Main: Migration data saved successfully.');
        } catch (error) {
            console.error('Main: Failed to save migration data', error);
        }
    });

    ipcMain.on('debug-rollback-migration', (event) => {
        try {
            console.log('[DEBUG] Rolling back migration...');
            const libraryPath = stores.library.path;
            const albumsPath = stores.albums.path;
            const libraryBackupPath = libraryPath + '.bak';
            const albumsBackupPath = albumsPath + '.bak';

            if (fs.existsSync(libraryBackupPath)) {
                fs.renameSync(libraryBackupPath, libraryPath);
                console.log('[DEBUG] Rolled back library.json');
            } else {
                 console.log('[DEBUG] No library.json backup found.');
            }

            if (fs.existsSync(albumsBackupPath)) {
                fs.renameSync(albumsBackupPath, albumsPath);
                 console.log('[DEBUG] Rolled back albums.json');
            } else {
                 console.log('[DEBUG] No albums.json backup found.');
            }
            
            if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('force-reload-library');
            }
        } catch (error) {
            console.error('[DEBUG] Failed to rollback migration:', error);
        }
    });
    
    logPerf("Migration handler registered.");
    
    // ▼▼▼ このハンドラをまるごと置き換えてください ▼▼▼
    ipcMain.handle('get-situation-playlists', (event) => {
        const { createSituationPlaylists } = require('./mood-analyzer');
        const { createHistoryPlaylists } = require('./history-analyzer'); // 新しくインポート
        
        const library = stores.library.load() || [];
        const playCounts = stores.playCounts.load() || {};

        // 1. ムードに基づくプレイリストを生成
        const moodPlaylists = createSituationPlaylists(library);
        
        // 2. 再生履歴に基づくプレイリストを生成
        const historyPlaylists = createHistoryPlaylists(playCounts, library);

        // 3. 両者を結合して返す
        return { ...historyPlaylists, ...moodPlaylists };
    });
    // ▲▲▲ 置き換えはここまで ▲▲▲

    logPerf("Requiring library-handler...");
    const { registerLibraryHandlers } = require('./handlers/library-handler');
    registerLibraryHandlers(stores, sendToAllWindows);
    logPerf("Library handlers registered.");

    logPerf("Requiring youtube-handler...");
    const { registerYouTubeHandlers } = require('./handlers/youtube-handler');
    registerYouTubeHandlers(stores, { playlist: playlistManager, addSongsFunc: addSongsToLibraryAndSave });
    logPerf("YouTube handlers registered.");

    logPerf("Requiring playlist-handler...");
    const { registerPlaylistHandlers } = require('./handlers/playlist-handler');
    registerPlaylistHandlers(stores, sendToAllWindows);
    logPerf("Playlist handlers registered.");

    logPerf("Requiring system-handler...");
    const { registerSystemHandlers } = require('./handlers/system-handler');
    registerSystemHandlers(stores);
    logPerf("System handlers registered.");

    logPerf("Requiring context-menu-handler...");
    const { registerContextMenuHandlers } = require('./handlers/context-menu-handler');
    registerContextMenuHandlers(stores, sendToAllWindows);
    logPerf("Context menu handlers registered.");
}

module.exports = { registerIpcHandlers };