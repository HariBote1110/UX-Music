// src/main/handlers/import-handler.js

const { ipcMain, app, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { scanPaths, parseFiles } = require('../file-scanner');
const os = require('os');
const { sanitize } = require('../utils');
const sharp = require('sharp');
const { Worker } = require('worker_threads');

let albumsStore;

/**
 * アートワークをファイル（webp/thumbnail）に保存する
 */
// ▼▼▼ 'export' を削除 ▼▼▼
async function saveArtworkToFile(picture, albumArtist, albumTitle) {
// ▲▲▲ 修正 ▲▲▲
    if (!picture || !picture.data) return null;
    const artworksDir = path.join(app.getPath('userData'), 'Artworks');
    const thumbnailsDir = path.join(artworksDir, 'thumbnails');
    if (!fs.existsSync(artworksDir)) fs.mkdirSync(artworksDir, { recursive: true });
    if (!fs.existsSync(thumbnailsDir)) fs.mkdirSync(thumbnailsDir, { recursive: true });

    const uniqueKey = `${albumArtist || 'Unknown Artist'}---${albumTitle || 'Unknown Album'}`;
    const hash = crypto.createHash('sha256').update(uniqueKey).digest('hex');

    const fullFileName = `${hash}.webp`;
    const thumbFileName = `${hash}_thumb.webp`;
    const fullPath = path.join(artworksDir, fullFileName);
    const thumbPath = path.join(thumbnailsDir, thumbFileName);
    try {
        const image = sharp(picture.data);
        await image.webp({ quality: 80 }).toFile(fullPath);
        await image.resize(100, 100).webp({ quality: 75 }).toFile(thumbPath);
        return { full: fullFileName, thumbnail: thumbFileName };
    } catch (error) {
        console.error(`Failed to save artwork for ${uniqueKey}:`, error);
        return null;
    }
}

/**
 * 新しい曲をライブラリに追加し、保存する
 */
function addSongsToLibraryAndSave(newSongs, libraryStore) {
    const library = libraryStore.load() || [];
    const existingPaths = new Set(library.map(s => s.path));
    const uniqueNewSongs = newSongs.filter(s => !existingPaths.has(s.path));
    if (uniqueNewSongs.length > 0) {
        libraryStore.save([...library, ...uniqueNewSongs]);
    }
    return uniqueNewSongs;
}

/**
 * ライブラリのインポート関連のIPCハンドラを登録する
 */
// ▼▼▼ 'export' を削除 ▼▼▼
function registerImportHandlers(stores) {
// ▲▲▲ 修正 ▲▲▲
    const { libraryStore, loudnessStore, settingsStore } = stores;
    albumsStore = stores.albumsStore; // saveArtworkToFile が参照 (このファイル内では不要)

    ipcMain.on('start-scan-paths', async (event, paths) => {
        console.time('Main: Total Import Process');

        const finishScan = (result) => {
            event.sender?.send('scan-complete', result);
            console.timeEnd('Main: Total Import Process');
        };

        const settings = settingsStore.load();
        let libraryPath = settings.libraryPath;

        if (!libraryPath) {
            const result = await dialog.showOpenDialog({
                properties: ['openDirectory'],
                title: 'ライブラリとして使用するフォルダを選択してください'
            });
            if (!result.canceled && result.filePaths.length > 0) {
                libraryPath = result.filePaths[0];
                settings.libraryPath = libraryPath;
                settingsStore.save(settings);
                console.log(`[Import] Library path set to: ${libraryPath}`);
            } else {
                console.error('[Import] Library path selection was canceled.');
                return finishScan([]);
            }
        }

        const sourceFiles = await scanPaths(paths);
        if (sourceFiles.length === 0) {
            console.log('[Import] No new source files found.');
            return finishScan([]);
        }

        const songsWithMetadata = await parseFiles(sourceFiles);
        const existingLibraryPaths = new Set((libraryStore.load() || []).map(s => s.path));

        const songsToProcess = songsWithMetadata.filter(song => {
            const artistDir = sanitize(song.albumartist || song.artist || 'Unknown Artist');
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destPath = path.join(libraryPath, artistDir, albumDir, sanitize(path.basename(song.path)));
            return !existingLibraryPaths.has(destPath);
        });

        if (songsToProcess.length === 0) {
            console.log('[Import] All files are already in the library.');
            return finishScan([]);
        }

        const albumsToProcess = new Map();
        songsToProcess.forEach(song => {
            const albumArtistKey = song.albumartist || song.artist || 'Unknown Artist';
            const albumKey = `${albumArtistKey}---${song.album || 'Unknown Album'}`;

            if (!albumsToProcess.has(albumKey)) {
                albumsToProcess.set(albumKey, {
                    songs: [],
                    artworkPicture: null,
                    albumArtist: albumArtistKey,
                    albumTitle: song.album || 'Unknown Album'
                });
            }
            const albumGroup = albumsToProcess.get(albumKey);
            albumGroup.songs.push(song);
            if (!albumGroup.artworkPicture && song.artwork) {
                albumGroup.artworkPicture = song.artwork;
            }
        });

        const albumsData = stores.albumsStore.load() || {};
        for (const [key, group] of albumsToProcess.entries()) {
            const savedArtwork = await saveArtworkToFile(group.artworkPicture, group.albumArtist, group.albumTitle);
            group.songs.forEach(song => {
                song.artwork = savedArtwork;
            });
            albumsData[key] = {
                title: group.albumTitle,
                artist: group.albumArtist,
                songs: group.songs.map(s => s.path),
                artwork: savedArtwork
            };
        }
        stores.albumsStore.save(albumsData);

        songsToProcess.forEach(song => {
            if (song.artwork && typeof song.artwork === 'object' && song.artwork.data) {
                delete song.artwork.data;
            }
        });

        songsToProcess.forEach(song => { song.originalPath = song.path; });

        const totalSteps = songsToProcess.length;
        let completedSteps = 0;
        const sendProgress = () => event.sender?.send('scan-progress', { current: completedSteps, total: totalSteps });
        sendProgress();

        const importMode = settings.importMode || 'balanced';
        const numCpuCores = os.cpus().length;
        const totalMemoryGB = os.totalmem() / (1024 ** 3);
        let concurrency;

        if (importMode === 'performance') {
            const memoryFactor = Math.floor(totalMemoryGB / 16);
            concurrency = Math.min(numCpuCores * 2, numCpuCores + memoryFactor);
        } else {
            concurrency = os.platform() === 'win32' ? Math.max(1, numCpuCores - 1) : numCpuCores;
        }
        concurrency = Math.max(1, concurrency);

        console.log(`[Import] Starting analysis in ${importMode} mode with ${totalMemoryGB.toFixed(1)}GB RAM. Concurrency set to: ${concurrency}`);

        const newSongObjects = [];
        const loudnessData = loudnessStore.load();

        await new Promise(resolve => {
            let runningWorkers = 0;
            const queue = [...songsToProcess];

            const onWorkerExit = () => {
                runningWorkers--;
                if (queue.length > 0) {
                    startWorker();
                } else if (runningWorkers === 0) {
                    resolve();
                }
            };

            function startWorker() {
                if (runningWorkers >= concurrency || queue.length === 0) return;

                runningWorkers++;
                const songToProcess = queue.shift();

                const worker = new Worker(path.join(__dirname, '..', 'analysis-worker.js'));

                worker.postMessage({
                    type: 'init',
                    ffmpegPath: require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked'),
                    ffprobePath: require('ffprobe-static').path.replace('app.asar', 'app.asar.unpacked')
                });

                Promise.resolve()
                    .then(() => {
                        const artistDir = sanitize(songToProcess.albumartist || songToProcess.artist || 'Unknown Artist');
                        const albumDir = sanitize(songToProcess.album || 'Unknown Album');
                        const destDir = path.join(libraryPath, artistDir, albumDir);
                        if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });

                        const destPath = path.join(destDir, sanitize(path.basename(songToProcess.path)));
                        if (songToProcess.path !== destPath && !fs.existsSync(destPath)) {
                             fs.copyFileSync(songToProcess.path, destPath);
                        }
                        songToProcess.path = destPath;

                        worker.postMessage({ type: 'analyze', song: songToProcess });
                    })
                    .catch(error => {
                        console.error(`[Import] Failed to process file ${songToProcess.originalPath}:`, error);
                        completedSteps++;
                        sendProgress();
                        worker.terminate();
                    });

                worker.on('message', (result) => {
                    const finalSong = result.song;
                    if (finalSong.loudness) loudnessData[finalSong.path] = finalSong.loudness;
                    delete finalSong.loudness;

                    console.log(`[Import] Finished analysis for: ${finalSong.artist} - ${finalSong.title}`);

                    newSongObjects.push(finalSong);
                    completedSteps++;
                    sendProgress();

                    worker.terminate();
                });

                worker.on('exit', onWorkerExit);
                worker.on('error', (err) => {
                    console.error(`[Import] Worker error for ${songToProcess.originalPath}:`, err);
                    completedSteps++;
                    sendProgress();
                    onWorkerExit();
                });
            }

            for (let i = 0; i < concurrency; i++) {
                startWorker();
            }
        });

        const sourceOrderMap = new Map(sourceFiles.map((path, index) => [path, index]));
        newSongObjects.sort((a, b) => {
            const orderA = sourceOrderMap.get(a.originalPath);
            const orderB = sourceOrderMap.get(b.originalPath);
            if (orderA === undefined) return 1;
            if (orderB === undefined) return -1;
            return orderA - orderB;
        });

        newSongObjects.forEach(song => delete song.originalPath);

        if (newSongObjects.length > 0) loudnessStore.save(loudnessData);

        const addedSongs = addSongsToLibraryAndSave(newSongObjects, libraryStore);
        finishScan(addedSongs);
    });
}

// ▼▼▼ `module.exports` を追加 ▼▼▼
module.exports = {
    saveArtworkToFile,
    registerImportHandlers
};
// ▲▲▲ 修正 ▲▲▲