const { ipcMain, app } = require('electron');
const { scanPaths, parseFiles, analyzeLoudness } = require('../file-scanner');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { sanitize } = require('../utils');

let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;

function saveArtworkToFile(picture, songPath) {
    if (!picture || !picture.data) return null;
    const artworksDir = path.join(app.getPath('userData'), 'Artworks');
    if (!fs.existsSync(artworksDir)) {
        fs.mkdirSync(artworksDir, { recursive: true });
    }
    const hash = crypto.createHash('sha256').update(songPath).digest('hex');
    const extension = picture.format.split('/')[1] || 'jpg';
    const artworkFileName = `${hash}.${extension}`;
    const artworkPath = path.join(artworksDir, artworkFileName);
    try {
        if (!fs.existsSync(artworkPath)) {
            fs.writeFileSync(artworkPath, picture.data);
        }
        return artworkFileName;
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
        const updatedLibrary = library.concat(uniqueNewSongs);
        libraryStore.save(updatedLibrary);
    }
    return uniqueNewSongs;
}

function registerLibraryHandlers(stores) {
    libraryStore = stores.library;
    loudnessStore = stores.loudness;
    settingsStore = stores.settings;
    playCountsStore = stores.playCounts;

    // ★★★ ここからが修正箇所です ★★★
    ipcMain.on('start-scan-paths', async (event, paths) => {
        const libraryPath = settingsStore.load().libraryPath;
        if (!libraryPath) {
            console.error('Library path is not set.');
            event.sender.send('scan-complete', []);
            return;
        }
    
        const sourceFiles = await scanPaths(paths);
        if (sourceFiles.length === 0) {
            event.sender.send('scan-complete', []);
            return;
        }

        const songsWithMetadata = await parseFiles(sourceFiles);
        const loudnessData = loudnessStore.load();
        const existingLibraryPaths = new Set(libraryStore.load().map(s => s.path));
        
        // ラウドネス解析が必要な新しい曲だけをフィルタリング
        const songsToProcess = songsWithMetadata.filter(song => {
            // 曲の最終的な保存先パスを事前に計算
            const primaryArtist = song.albumartist || song.artist || 'Unknown Artist';
            const artistDir = sanitize(primaryArtist);
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destDir = path.join(libraryPath, artistDir, albumDir);
            const originalFileName = path.basename(song.path);
            const safeFileName = sanitize(originalFileName);
            const destPath = path.join(destDir, safeFileName);
            // ライブラリにまだ存在しない曲のみを対象とする
            return !existingLibraryPaths.has(destPath);
        });

        const totalSteps = songsToProcess.length * 2; // 解析が必要な曲数でステップを計算
        let completedSteps = 0;
    
        const sendProgress = () => {
            if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('scan-progress', { current: completedSteps, total: totalSteps });
            }
        };
        sendProgress();
    
        // メタデータ解析は完了したとみなし、ステップを進める
        completedSteps += songsToProcess.length;
        sendProgress();
    
        const newSongObjects = [];
    
        for (const song of songsToProcess) {
            if (song.artwork) {
                song.artwork = saveArtworkToFile(song.artwork, song.path);
            }
            const primaryArtist = song.albumartist || song.artist || 'Unknown Artist';
            const artistDir = sanitize(primaryArtist);
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destDir = path.join(libraryPath, artistDir, albumDir);
            if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
            
            const originalFileName = path.basename(song.path);
            const safeFileName = sanitize(originalFileName);
            const destPath = path.join(destDir, safeFileName);
    
            if (!fs.existsSync(destPath)) {
                try {
                    fs.copyFileSync(song.path, destPath);
                    const result = await analyzeLoudness(destPath);
                    event.sender.send('loudness-analysis-result', result);
                    if (result.success) {
                        loudnessData[destPath] = result.loudness;
                    }
                } catch (error) {
                    console.error(`Failed to copy or analyze ${originalFileName}:`, error);
                }
            }
            song.path = destPath;
            newSongObjects.push(song);
            
            completedSteps++;
            sendProgress();
        }
        
        if (newSongObjects.length > 0) {
            loudnessStore.save(loudnessData);
        }
        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        
        event.sender.send('scan-complete', addedSongs);
    });
    // ★★★ ここまでが修正箇所です ★★★

    ipcMain.on('request-loudness-analysis', async (event, songPath) => {
        const loudnessData = loudnessStore.load();
        if (loudnessData[songPath]) return;
        const result = await analyzeLoudness(songPath);
        event.sender.send('loudness-analysis-result', result);
        if (result.success) {
            const currentLoudnessData = loudnessStore.load();
            currentLoudnessData[songPath] = result.loudness;
            loudnessStore.save(currentLoudnessData);
        }
    });

    ipcMain.handle('get-loudness-value', (event, songPath) => {
        const loudnessData = loudnessStore.load();
        return loudnessData[songPath] || null;
    });

    ipcMain.on('request-initial-library', (event) => {
        const songs = libraryStore.load() || [];
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('load-library', songs);
        }
    });

    ipcMain.on('debug-reset-library', (event) => {
        try {
            libraryStore.save([]);
            loudnessStore.save({});
            playCountsStore.save({});
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            if (fs.existsSync(artworksDir)) {
                fs.rmSync(artworksDir, { recursive: true, force: true });
            }
            console.log('[DEBUG] Library has been reset.');
            if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('force-reload-library');
            }
        } catch (error) {
            console.error('[DEBUG] Failed to reset library:', error);
        }
    });
}

module.exports = { registerLibraryHandlers };