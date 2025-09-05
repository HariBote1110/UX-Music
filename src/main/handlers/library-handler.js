const { ipcMain, app } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { scanPaths, parseFiles } = require('../file-scanner');
const os = require('os');
const { sanitize } = require('../utils');
const sharp = require('sharp');
const { Worker } = require('worker_threads');

let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;
let albumsStore;

async function saveArtworkToFile(picture, songPath) {
    if (!picture || !picture.data) return null;
    const artworksDir = path.join(app.getPath('userData'), 'Artworks');
    const thumbnailsDir = path.join(artworksDir, 'thumbnails');
    if (!fs.existsSync(artworksDir)) fs.mkdirSync(artworksDir, { recursive: true });
    if (!fs.existsSync(thumbnailsDir)) fs.mkdirSync(thumbnailsDir, { recursive: true });
    const hash = crypto.createHash('sha256').update(songPath).digest('hex');
    const fullFileName = `${hash}.webp`;
    const thumbFileName = `${hash}_thumb.webp`;
    const fullPath = path.join(artworksDir, fullFileName);
    const thumbPath = path.join(thumbnailsDir, thumbFileName);
    try {
        const image = sharp(picture.data);
        if (!fs.existsSync(fullPath)) await image.webp({ quality: 80 }).toFile(fullPath);
        if (!fs.existsSync(thumbPath)) await image.resize(100, 100).webp({ quality: 75 }).toFile(thumbPath);
        return { full: fullFileName, thumbnail: thumbFileName };
    } catch (error) {
        console.error(`Failed to save artwork for ${songPath}:`, error);
        return null;
    }
}

function addSongsToLibraryAndSave(newSongs) {
    const library = libraryStore.load() || [];
    const existingPaths = new Set(library.map(s => s.path));
    const uniqueNewSongs = newSongs.filter(s => !existingPaths.has(s.path));
    if (uniqueNewSongs.length > 0) {
        libraryStore.save([...library, ...uniqueNewSongs]);
    }
    return uniqueNewSongs;
}

function registerLibraryHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;
    loudnessStore = stores.loudness;
    settingsStore = stores.settings;
    playCountsStore = stores.playCounts;
    albumsStore = stores.albums;

    ipcMain.on('request-bpm-analysis', async (event, song) => {
        const { analyzeBPM } = require('../file-scanner');
        const bpm = await analyzeBPM(song.path);
        if (bpm !== null) {
            const library = libraryStore.load() || [];
            const songIndex = library.findIndex(s => s.path === song.path);
            if (songIndex > -1) {
                library[songIndex].bpm = bpm;
                libraryStore.save(library);
                sendToAllWindows('bpm-analysis-complete', library[songIndex]);
            }
        }
    });
    
    ipcMain.on('start-scan-paths', async (event, paths) => {
        console.time('Main: Total Import Process');
        const settings = settingsStore.load();
        const libraryPath = settings.libraryPath;
        if (!libraryPath) return event.sender.send('scan-complete', []);

        const sourceFiles = await scanPaths(paths);
        if (sourceFiles.length === 0) return event.sender.send('scan-complete', []);

        const songsWithMetadata = await parseFiles(sourceFiles);
        const existingLibraryPaths = new Set((libraryStore.load() || []).map(s => s.path));
        
        const songsToProcess = songsWithMetadata.filter(song => {
            const artistDir = sanitize(song.albumartist || song.artist || 'Unknown Artist');
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destPath = path.join(libraryPath, artistDir, albumDir, sanitize(path.basename(song.path)));
            return !existingLibraryPaths.has(destPath);
        });

        if (songsToProcess.length === 0) return event.sender.send('scan-complete', []);
        
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

                saveArtworkToFile(songToProcess.artwork, songToProcess.path).then(artwork => {
                    songToProcess.artwork = artwork;
                    const artistDir = sanitize(songToProcess.albumartist || songToProcess.artist || 'Unknown Artist');
                    const albumDir = sanitize(songToProcess.album || 'Unknown Album');
                    const destDir = path.join(libraryPath, artistDir, albumDir);
                    if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
                    
                    const destPath = path.join(destDir, sanitize(path.basename(songToProcess.path)));
                    if (!fs.existsSync(destPath)) {
                        fs.copyFileSync(songToProcess.path, destPath);
                    }
                    songToProcess.path = destPath;
                    
                    worker.postMessage({ type: 'analyze', song: songToProcess });
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

                worker.on('exit', (code) => {
                    runningWorkers--;
                    if (queue.length > 0) {
                        startWorker();
                    } else if (runningWorkers === 0) {
                        resolve();
                    }
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
        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        event.sender.send('scan-complete', addedSongs);
        console.timeEnd('Main: Total Import Process');
    });

    ipcMain.handle('get-loudness-value', (event, songPath) => (loudnessStore.load() || {})[songPath] || null);

    ipcMain.on('request-initial-library', (event) => {
        const songs = libraryStore.load() || [];
        const albums = albumsStore.load() || {};
        event.sender?.send('load-library', { songs, albums });
    });

    ipcMain.on('debug-reset-library', (event) => {
        try {
            libraryStore.save([]);
            loudnessStore.save({});
            playCountsStore.save({});
            albumsStore.save({});
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            if (fs.existsSync(artworksDir)) fs.rmSync(artworksDir, { recursive: true, force: true });
            const libraryPath = settingsStore.load().libraryPath;
            if (libraryPath && fs.existsSync(libraryPath)) {
                fs.rmSync(libraryPath, { recursive: true, force: true });
                fs.mkdirSync(libraryPath, { recursive: true });
            }
            console.log('[DEBUG] Library has been reset completely.');
            event.sender?.send('force-reload-library');
        } catch (error) {
            console.error('[DEBUG] Failed to reset library:', error);
        }
    });
}

module.exports = { 
    registerLibraryHandlers,
    saveArtworkToFile
};