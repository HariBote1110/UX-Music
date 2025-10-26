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
    stores.analysedQueue = new DataStore('analysed-queue.json');
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
        const uniqueNewSongs = newSongs.filter(s => s && s.path && !existingPaths.has(s.path));
        if (uniqueNewSongs.length > 0) {
            const updatedLibrary = library.concat(uniqueNewSongs);
            stores.library.save(updatedLibrary);
        }
        return uniqueNewSongs;
    };

    // --- New Handler for Dropped Files ---
    ipcMain.on('files-dropped', (event, filePaths) => {
        console.log('[Import Debug Main] Received files-dropped event with paths:', filePaths);
        if (!Array.isArray(filePaths) || filePaths.length === 0) {
            console.warn('[Import Debug Main] Received empty or invalid file paths.');
            return;
        }

        const lyricsExtensions = ['.lrc', '.txt'];
        const musicPaths = [];
        const lyricsPaths = [];

        for (const filePath of filePaths) {
             // Basic validation
             if (typeof filePath !== 'string' || filePath.length === 0) {
                 console.warn(`[Import Debug Main] Skipping invalid path entry: ${filePath}`);
                 continue;
             }

            const ext = path.extname(filePath).toLowerCase();
            if (lyricsExtensions.includes(ext)) {
                lyricsPaths.push(filePath);
            } else {
                // Assume anything else might be music for now
                // More robust check could involve mime types if needed
                musicPaths.push(filePath);
            }
        }

        console.log('[Import Debug Main] Classified paths - Music:', musicPaths, 'Lyrics:', lyricsPaths);

        // Trigger the existing handlers
        if (musicPaths.length > 0) {
            console.log('[Import Debug Main] Triggering start-scan-paths for music files.');
            // Send to the specific window that initiated the drop
            event.sender.send('start-scan-paths-triggered-from-drop', musicPaths);
            // We need library-handler to listen for this specific event or refactor
            // For now, let's call the library handler's function directly if possible,
            // or emit the event globally if needed. Re-emitting locally for simplicity:
             ipcMain.emit('start-scan-paths', event, musicPaths); // Re-emit internally
        }
        if (lyricsPaths.length > 0) {
            console.log('[Import Debug Main] Triggering handle-lyrics-drop for lyrics files.');
             ipcMain.emit('handle-lyrics-drop', event, lyricsPaths); // Re-emit internally
        }
    });


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
                 if (event.sender && !event.sender.isDestroyed()) {
                     event.sender.send('normalize-worker-result', message);
                 }
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

        // Define the listener function separately to remove it correctly
        const listenerForWorkerFinished = () => processNextFile();
        ipcMain.on('normalize-worker-finished-file', listenerForWorkerFinished);


        for (let i = 0; i < concurrency && i < files.length; i++) {
            processNextFile();
        }

        // Ensure listener is removed when job stops or finishes
         ipcMain.on('stop-normalize-job', () => {
             normalizeWorkerPool.forEach(worker => worker.terminate());
             normalizeWorkerPool = [];
             ipcMain.removeListener('normalize-worker-finished-file', listenerForWorkerFinished);
         });
         // TODO: Also remove listener when the job naturally completes (all files processed)
         // Need a way to track completion. Maybe resolve a promise?

    });

    // Simplified stop handler
     ipcMain.on('stop-normalize-job', () => {
         // The actual termination logic might be within the 'start-normalize-job' scope
         // This is more of a signal
         console.log('[Normalize] Received stop-normalize-job signal.');
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
            try {
                 const items = await fs.promises.readdir(dir, { withFileTypes: true });
                 for (const item of items) {
                     const fullPath = path.join(dir, item.name);
                     if (item.isDirectory()) {
                         // Consider adding try/catch around recursive call for permission errors
                         await scanDirectory(fullPath);
                     } else if (supportedExtensions.includes(path.extname(item.name).toLowerCase())) {
                         files.push(fullPath);
                     }
                 }
            } catch (scanError) {
                 console.error(`[Normalize] Error scanning directory ${dir}:`, scanError);
                 // Optionally notify the user
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
        const settings = stores.settings.load() || {};

        const moodPlaylists = createSituationPlaylists(library, settings);
        const historyPlaylists = createHistoryPlaylists(playCounts, library);

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