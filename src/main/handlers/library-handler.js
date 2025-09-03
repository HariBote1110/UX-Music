const { ipcMain, app } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { scanPaths, parseFiles, analyzeLoudness, analyzeBPM, analyzeEnergy } = require('../file-scanner'); // analyzeEnergyを追加
const os = require('os');
const { sanitize } = require('../utils');
const sharp = require('sharp');

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
    const extension = 'webp';
    const fullFileName = `${hash}.${extension}`;
    const thumbFileName = `${hash}_thumb.${extension}`;
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

    // ▼▼▼ `start-scan-paths` の中身を修正 ▼▼▼
    ipcMain.on('start-scan-paths', async (event, paths) => {
        console.time('Main: Total Import Process');
        const pLimit = (await import('p-limit')).default;
        const libraryPath = settingsStore.load().libraryPath;
        if (!libraryPath) return event.sender.send('scan-complete', []);
    
        const sourceFiles = await scanPaths(paths);
        if (sourceFiles.length === 0) return event.sender.send('scan-complete', []);

        const songsWithMetadata = await parseFiles(sourceFiles);
        const loudnessData = loudnessStore.load();
        const existingLibraryPaths = new Set((libraryStore.load() || []).map(s => s.path));
        
        const songsToProcess = songsWithMetadata.filter(song => {
            const artistDir = sanitize(song.albumartist || song.artist || 'Unknown Artist');
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destPath = path.join(libraryPath, artistDir, albumDir, sanitize(path.basename(song.path)));
            return !existingLibraryPaths.has(destPath);
        });

        if (songsToProcess.length === 0) return event.sender.send('scan-complete', []);

        const totalSteps = songsToProcess.length;
        let completedSteps = 0;
        const sendProgress = () => event.sender?.send('scan-progress', { current: completedSteps, total: totalSteps });
        sendProgress();
    
        const concurrency = os.platform() === 'win32' ? Math.max(1, os.cpus().length - 1) : os.cpus().length;
        const limit = pLimit(concurrency);
        console.log(`[Import] Starting analysis with concurrency: ${concurrency}`);

        const analysisPromises = songsToProcess.map(song => limit(async () => {
            if (song.artwork) song.artwork = await saveArtworkToFile(song.artwork, song.path);
            
            const artistDir = sanitize(song.albumartist || song.artist || 'Unknown Artist');
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destDir = path.join(libraryPath, artistDir, albumDir);
            if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
            
            const destPath = path.join(destDir, sanitize(path.basename(song.path)));
            if (!fs.existsSync(destPath)) {
                fs.copyFileSync(song.path, destPath);
                const result = await analyzeLoudness(destPath);
                if (result.success) loudnessData[destPath] = result.loudness;
            }
            
            // ★ BPMとEnergyの解析を追加
            if (typeof song.bpm !== 'number') {
                song.bpm = await analyzeBPM(destPath);
            }
            song.energy = await analyzeEnergy(destPath);
            
            completedSteps++;
            sendProgress();

            // ★ pathを更新し、解析結果を含んだ新しいオブジェクトを返す
            return { ...song, path: destPath }; 
        }));

        const newSongObjects = await Promise.all(analysisPromises);
        
        if (newSongObjects.length > 0) {
            loudnessStore.save(loudnessData);
        }
        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        
        event.sender.send('scan-complete', addedSongs);
        console.timeEnd('Main: Total Import Process');
    });
    // ▲▲▲ `start-scan-paths` の修正はここまで ▲▲▲

    ipcMain.on('request-loudness-analysis', async (event, songPath) => {
        const loudnessData = loudnessStore.load();
        if (loudnessData[songPath]) return;
        const result = await analyzeLoudness(songPath);
        if (result.success) {
            const currentLoudnessData = loudnessStore.load();
            currentLoudnessData[songPath] = result.loudness;
            loudnessStore.save(currentLoudnessData);
        }
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

module.exports = { registerLibraryHandlers };