// src/main/ipc-handlers.js
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

// --- ▼▼▼ MTP機能のために追記 (ステップ8) ▼▼▼ ---
const mtpManager = require('./mtp/mtp-manager');
// --- ▲▲▲ MTP機能のために追記 (ステップ8) ▲▲▲ ---

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

    // ▼▼▼ 追加: 名前不一致（settings vs settingsStore）を防ぐためのエイリアス ▼▼▼
    stores.settingsStore = stores.settings;
    stores.libraryStore = stores.library;
    // ▲▲▲ 追加 ▲▲▲

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
        ipcMain.removeListener('normalize-worker-finished-file', () => { });
    });

    ipcMain.handle('select-files-for-normalize', async () => {
        const result = await dialog.showOpenDialog({
            properties: ['openFile', 'multiSelections'],
            filters: [{ name: 'Audio Files', extensions: ['mp3', 'flac', 'wav', 'm4a', 'ogg'] }]
        });
        return result.filePaths;
    });

    // ▼▼▼ 修正: システムフォルダを除外してアクセス権エラーを防ぐ ▼▼▼
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
                    // 隠しファイル・フォルダ（.で始まるもの）をスキップ
                    // これにより .Spotlight-V100 や .Trashes などのシステムフォルダを回避
                    if (item.name.startsWith('.')) continue;

                    const fullPath = path.join(dir, item.name);
                    if (item.isDirectory()) {
                        await scanDirectory(fullPath);
                    } else if (supportedExtensions.includes(path.extname(item.name).toLowerCase())) {
                        files.push(fullPath);
                    }
                }
            } catch (error) {
                // アクセス権限エラー等が発生した場合はログを出力してそのフォルダをスキップ
                console.warn(`[Folder Scan] Skipping directory ${dir}: ${error.message}`);
            }
        }

        await scanDirectory(dirPath);
        return files;
    });
    // ▲▲▲ 修正ここまで ▲▲▲

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

    // --- ▼▼▼ MTP機能のために修正 (ステップ8) ▼▼▼ ---
    /**
     * MTPデバイスへのファイル転送（アップロード）を実行
     */
    ipcMain.handle('mtp-upload-files', async (event, { storageId, sources, destination }) => {
        console.log(`[MTP Transfer] 要求受信: ${sources.length}件を StorageID ${storageId} の ${destination} へ`);

        const mtpDevice = mtpManager.getDevice();
        if (!mtpDevice) {
            console.error('[MTP Transfer] エラー: デバイスが見つかりません');
            return { error: 'MTP device not connected.' };
        }

        // メインウィンドウを取得して、プログレスバーを表示する
        const mainWindow = BrowserWindow.getAllWindows()[0];

        try {
            const result = await mtpDevice.transferFiles({
                direction: 'upload',
                storageId: storageId, // 例: 65537
                sources: sources,     // 例: ['/Users/yuki/Music/test.mp3']
                destination: destination, // 例: '/Music/' (末尾のスラッシュが重要)
                preprocessFiles: true,

                // --- コールバック関数 ---
                onError: (err) => {
                    console.error('[MTP Transfer] 転送エラー:', err);
                    // TODO: UIにエラー通知
                },
                onPreprocess: (data) => {
                    console.log(`[MTP Transfer] 前処理中: ${data.name}`);
                    // TODO: UIに進捗表示 (例: 'ファイル 1/10: test.mp3 を準備中...')
                },
                onProgress: (data) => {
                    const percent = Math.round(data.bytesTransferred * 100 / data.totalBytes);
                    console.log(`[MTP Transfer] 転送中: ${data.fullPath} (${percent}%)`);
                    // メインウィンドウのプログレスバーを更新
                    if (mainWindow) {
                        // プログレスバーの値を 0 から 1 の範囲で設定
                        mainWindow.setProgressBar(data.bytesTransferred / data.totalBytes);
                    }
                },
                onCompleted: () => {
                    console.log('[MTP Transfer] 転送完了');
                    if (mainWindow) {
                        mainWindow.setProgressBar(-1); // プログレスバーを非表示（-1で解除）
                    }
                    // TODO: UIに完了通知
                },
            });

            if (mainWindow) {
                mainWindow.setProgressBar(-1); // 完了またはエラー時にプログレスバーを非表示
            }

            if (result.error) {
                console.error('[MTP Transfer] 最終結果エラー:', result.error);
            }

            return result; // UI側に最終結果を返す

        } catch (err) {
            console.error('[MTP Transfer] ハンドラ全体のエラー:', err);
            if (mainWindow) {
                mainWindow.setProgressBar(-1);
            }
            return { error: err.message };
        }
    });

    // --- ▼▼▼ MTPブラウザ機能 ▼▼▼ ---

    /**
     * MTPデバイスのディレクトリ内容を取得
     */
    ipcMain.handle('mtp-browse-directory', async (event, { storageId, fullPath }) => {
        console.log(`[MTP Browse] ディレクトリ閲覧要求: StorageID ${storageId}, Path: ${fullPath}`);

        const mtpDevice = mtpManager.getDevice();
        if (!mtpDevice) {
            console.error('[MTP Browse] エラー: デバイスが見つかりません');
            return { error: 'MTP device not connected.' };
        }

        try {
            const result = await mtpDevice.walk({
                storageId: storageId,
                fullPath: fullPath,
                skipHiddenFiles: true
            });

            if (result.error) {
                console.error('[MTP Browse] walk エラー:', result.error);
                return { error: result.error };
            }

            console.log(`[MTP Browse] ${fullPath} の内容: ${result.data?.length || 0} 件`);
            return result;

        } catch (err) {
            console.error('[MTP Browse] ハンドラ全体のエラー:', err);
            return { error: err.message };
        }
    });

    /**
     * MTPデバイスからファイルをダウンロード
     */
    ipcMain.handle('mtp-download-files', async (event, { storageId, sources, destination }) => {
        console.log(`[MTP Download] ダウンロード要求: ${sources.length}件を ${destination} へ`);

        const mtpDevice = mtpManager.getDevice();
        if (!mtpDevice) {
            console.error('[MTP Download] エラー: デバイスが見つかりません');
            return { error: 'MTP device not connected.' };
        }

        const mainWindow = BrowserWindow.getAllWindows()[0];

        try {
            const result = await mtpDevice.transferFiles({
                direction: 'download',
                storageId: storageId,
                sources: sources,       // 端末上のファイルパス
                destination: destination, // PC上の保存先パス
                preprocessFiles: true,

                onError: (err) => {
                    console.error('[MTP Download] 転送エラー:', err);
                },
                onPreprocess: (data) => {
                    console.log(`[MTP Download] 前処理中: ${data.name}`);
                },
                onProgress: (data) => {
                    const percent = Math.round(data.bytesTransferred * 100 / data.totalBytes);
                    console.log(`[MTP Download] 転送中: ${data.fullPath} (${percent}%)`);
                    if (mainWindow) {
                        mainWindow.setProgressBar(data.bytesTransferred / data.totalBytes);
                    }
                },
                onCompleted: () => {
                    console.log('[MTP Download] ダウンロード完了');
                    if (mainWindow) {
                        mainWindow.setProgressBar(-1);
                    }
                },
            });

            if (mainWindow) {
                mainWindow.setProgressBar(-1);
            }

            if (result.error) {
                console.error('[MTP Download] 最終結果エラー:', result.error);
            }

            return result;

        } catch (err) {
            console.error('[MTP Download] ハンドラ全体のエラー:', err);
            if (mainWindow) {
                mainWindow.setProgressBar(-1);
            }
            return { error: err.message };
        }
    });

    /**
     * MTPデバイス上のファイル/フォルダを削除
     */
    ipcMain.handle('mtp-delete-files', async (event, { storageId, files }) => {
        console.log(`[MTP Delete] 削除要求: ${files.length}件`);

        const mtpDevice = mtpManager.getDevice();
        if (!mtpDevice) {
            console.error('[MTP Delete] エラー: デバイスが見つかりません');
            return { error: 'MTP device not connected.' };
        }

        try {
            const result = await mtpDevice.deleteFile({
                storageId: storageId,
                files: files
            });

            if (result.error) {
                console.error('[MTP Delete] エラー:', result.error);
                return { error: result.error };
            }

            console.log('[MTP Delete] 削除完了:', result.data);
            return result;

        } catch (err) {
            console.error('[MTP Delete] ハンドラ全体のエラー:', err);
            return { error: err.message };
        }
    });

    /**
     * ダウンロード先フォルダを選択
     */
    ipcMain.handle('mtp-select-download-folder', async () => {
        const result = await dialog.showOpenDialog({
            properties: ['openDirectory', 'createDirectory'],
            title: 'ダウンロード先を選択'
        });

        if (result.canceled || result.filePaths.length === 0) {
            return null;
        }

        return result.filePaths[0];
    });

    /**
     * 未転送曲を検出する
     * ライブラリ内の楽曲とWalkman内の楽曲をファイル名で比較
     */
    ipcMain.handle('mtp-get-untransferred-songs', async (event, { storageId, librarySongs }) => {
        console.log(`[MTP Sync] 未転送曲の検出を開始: StorageID ${storageId}, ライブラリ ${librarySongs?.length || 0}曲`);

        const mtpDevice = mtpManager.getDevice();
        if (!mtpDevice) {
            console.error('[MTP Sync] エラー: デバイスが見つかりません');
            return [];
        }

        try {
            // Walkmanの/Music/フォルダ内のファイルを再帰的に取得
            const deviceFiles = new Set();

            async function scanDirectory(dirPath) {
                try {
                    const result = await mtpDevice.walk({
                        storageId: storageId,
                        fullPath: dirPath,
                        skipHiddenFiles: true
                    });

                    if (result.error || !result.data) {
                        console.warn(`[MTP Sync] ディレクトリ ${dirPath} の取得に失敗:`, result.error);
                        return;
                    }

                    for (const item of result.data) {
                        if (item.isFolder) {
                            await scanDirectory(item.fullPath);
                        } else {
                            // ファイル名のみを取得して比較用セットに追加
                            const fileName = item.name.toLowerCase();
                            deviceFiles.add(fileName);
                        }
                    }
                } catch (err) {
                    console.warn(`[MTP Sync] スキャンエラー (${dirPath}):`, err.message);
                }
            }

            await scanDirectory('/MUSIC/');
            console.log(`[MTP Sync] Walkman内のファイル数: ${deviceFiles.size}`);

            // ライブラリ楽曲と比較して未転送曲を抽出
            const untransferredSongs = librarySongs.filter(song => {
                if (!song.path) return false;
                // ファイル名のみを抽出して比較
                const fileName = path.basename(song.path).toLowerCase();
                return !deviceFiles.has(fileName);
            });

            console.log(`[MTP Sync] 未転送曲: ${untransferredSongs.length}曲`);
            return untransferredSongs;

        } catch (err) {
            console.error('[MTP Sync] 未転送曲検出エラー:', err);
            return [];
        }
    });

    // --- ▲▲▲ MTPブラウザ機能 ▲▲▲ ---

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

// ▼▼▼ 修正: stores をエクスポートに追加 ▼▼▼
module.exports = { registerIpcHandlers, stores };
// ▲▲▲ 修正 ▲▲▲