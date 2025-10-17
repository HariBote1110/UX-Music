const { BrowserWindow, ipcMain, dialog } = require('electron');
const DataStore = require('./data-store');
const playlistManager = require('./playlist-manager');
const { performance } = require('perf_hooks');
const fs = require('fs');
const crypto = require('crypto');
const discordRpcManager = require('./discord-rpc-manager');
const { Worker } = require('worker_threads');
const path = require('path');
const os = require('os');

const logPerf = (message) => {
    console.log(`[PERF][IPC-Handlers] ${message}`);
};

let stores = {};

function runMigrations(stores) {
    const library = stores.library.load() || [];
    let migrationNeeded = false;
    
    if (library.length > 0 && !library[0].id) {
        console.log('[Migration] Assigning unique IDs to existing songs...');
        migrationNeeded = true;
        library.forEach(song => {
            if (!song.id) {
                song.id = crypto.randomUUID();
            }
        });
    }

    if (migrationNeeded) {
        stores.library.save(library);
        console.log('[Migration] Unique IDs assigned and library saved.');
    }
}

function registerIpcHandlers() {
    logPerf("Registering handlers starts...");
    
    stores.playCounts = new DataStore('playcounts.json');
    stores.settings = new DataStore('settings.json');
    stores.library = new DataStore('library.json');
    stores.loudness = new DataStore('loudness.json');
    stores.albums = new DataStore('albums.json');
    stores.quizScores = new DataStore('quiz-scores.json');
    stores.analysedQueue = new DataStore('analysed-queue.json'); // Analysed Queue用のストアを追加
    logPerf("DataStores initialized.");
    
    runMigrations(stores);

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

    // --- Normalize Feature Handlers ---
    let normalizeWorkerPool = [];

    ipcMain.on('start-normalize-job', (event, { jobType, files, options }) => {
        const numCpuCores = os.cpus().length;
        const concurrency = Math.max(1, numCpuCores - 1);

        normalizeWorkerPool.forEach(worker => worker.terminate());
        normalizeWorkerPool = [];

        for (let i = 0; i < concurrency; i++) {
            const worker = new Worker(path.join(__dirname, 'normalize-worker.js'));
            worker.postMessage({
                type: 'init',
                ffmpegPath: require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked'),
                ffprobePath: require('ffprobe-static').path.replace('app.asar', 'app.asar.unpacked')
            });
            worker.on('message', (message) => {
                event.sender.send('normalize-worker-result', message);
            });
            normalizeWorkerPool.push(worker);
        }

        let fileIndex = 0;
        let workerIndex = 0;
        
        const processNextFile = () => {
            if (fileIndex >= files.length) return;
            
            const file = files[fileIndex++];
            const worker = normalizeWorkerPool[workerIndex++ % concurrency];
            
            if (jobType === 'analyze') {
                worker.postMessage({ type: 'analyze', id: file.id, filePath: file.path });
            } else if (jobType === 'normalize') {
                worker.postMessage({ 
                    type: 'normalize', 
                    id: file.id, 
                    filePath: file.path, 
                    gain: file.gain, 
                    backup: options.backup, 
                    output: options.output,
                    basePath: options.basePath
                });
            }
        };

        for (let i = 0; i < concurrency && i < files.length; i++) {
            processNextFile();
        }

        ipcMain.on('normalize-worker-finished-file', processNextFile);
    });

    ipcMain.on('stop-normalize-job', () => {
        normalizeWorkerPool.forEach(worker => worker.terminate());
        normalizeWorkerPool = [];
        ipcMain.removeListener('normalize-worker-finished-file', () => {});
    });

    ipcMain.handle('select-files-for-normalize', async () => {
        const result = await dialog.showOpenDialog({
            properties: ['openFile', 'multiSelections'],
            filters: [{ name: 'Audio Files', extensions: ['mp3', 'flac', 'wav', 'm4a', 'ogg'] }]
        });
        return result.filePaths;
    });

    ipcMain.handle('select-folder-for-normalize', async () => {
        const result = await dialog.showOpenDialog({ properties: ['openDirectory'] });
        if (result.canceled || result.filePaths.length === 0) return [];
        
        const dirPath = result.filePaths[0];
        const supportedExtensions = ['.mp3', '.flac', '.wav', '.m4a', '.ogg'];
        let files = [];
        
        async function scanDirectory(dir) {
            const items = await fs.promises.readdir(dir, { withFileTypes: true });
            for (const item of items) {
                const fullPath = path.join(dir, item.name);
                if (item.isDirectory()) {
                    await scanDirectory(fullPath);
                } else if (supportedExtensions.includes(path.extname(item.name).toLowerCase())) {
                    files.push(fullPath);
                }
            }
        }
        
        await scanDirectory(dirPath);
        return files;
    });

    ipcMain.handle('get-library-for-normalize', () => {
        return stores.library.load() || [];
    });
    
    ipcMain.handle('get-all-loudness-data', () => {
        return stores.loudness.load() || {};
    });

    ipcMain.handle('select-normalize-output-folder', async () => {
        const result = await dialog.showOpenDialog({ properties: ['openDirectory'] });
        return result.canceled ? null : result.filePaths[0];
    });

    // --- End of Normalize Feature Handlers ---


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
    
    ipcMain.handle('get-situation-playlists', (event) => {
        const { createSituationPlaylists } = require('./mood-analyzer');
        const { createHistoryPlaylists } = require('./history-analyzer');
        
        const library = stores.library.load() || [];
        const playCounts = stores.playCounts.load() || {};
        const settings = stores.settings.load() || {}; // 設定を読み込む

        // 1. ムードに基づくプレイリストを生成 (設定を渡す)
        const moodPlaylists = createSituationPlaylists(library, settings);
        
        // 2. 再生履歴に基づくプレイリストを生成
        const historyPlaylists = createHistoryPlaylists(playCounts, library);

        // 3. 両者を結合して返す
        return { ...historyPlaylists, ...moodPlaylists };
    });

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