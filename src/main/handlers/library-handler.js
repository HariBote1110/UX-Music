const { ipcMain, app } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { scanPaths, parseFiles, analyzeLoudness } = require('../file-scanner');
const os = require('os');
const { sanitize } = require('../utils');
const sharp = require('sharp');
const MusicTempo = require('music-tempo');
const ffmpeg = require('fluent-ffmpeg');
const tmp = require('tmp');
const wavDecoder = require('wav-decoder'); // ★★★ この行を追加 ★★★

let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;
let albumsStore;

// src/main/handlers/library-handler.js 内の analyzeBPM 関数


/**
 * 音声データを解析してBPMを算出する（BPM補正ロジック追加版）
 * @param {string} songPath - 解析対象の曲のパス
 * @returns {Promise<number|null>} - 解析されたBPM値 or null
 */
async function analyzeBPM(songPath) {
    console.log('[BPM Analysis] Executing FINAL version with octave correction...');

    const tempFile = tmp.fileSync({ postfix: '.wav' });

    try {
        await new Promise((resolve, reject) => {
            ffmpeg(songPath)
                .toFormat('wav')
                .audioChannels(1)
                .audioFrequency(22050)
                .on('error', (err) => {
                    console.error(`[BPM Analysis] FFmpeg error for ${path.basename(songPath)}:`, err.message);
                    reject(err);
                })
                .on('end', () => resolve())
                .save(tempFile.name);
        });
        
        const buffer = fs.readFileSync(tempFile.name);
        const audioData = await wavDecoder.decode(buffer);
        const calcTempo = new MusicTempo(audioData.channelData[0]);

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        let rawBPM = calcTempo.tempo;
        
        // 一般的な楽曲のBPM上限を180と仮定し、それを超える場合は半分にする
        // これにより「倍テン」で検出されたBPMを補正する
        if (rawBPM > 180) {
            console.log(`[BPM Analysis] Octave error detected. Correcting ${rawBPM} -> ${rawBPM / 2}`);
            rawBPM = rawBPM / 2;
        }
        
        const roundedBPM = Math.round(rawBPM);
        // ▲▲▲ ここまでが修正箇所です ▲▲▲

        console.log(`[BPM Analysis] Analysis successful for ${path.basename(songPath)}: ${roundedBPM} BPM`);
        return roundedBPM;

    } catch (error) {
        console.error(`[BPM Analysis] A critical error occurred during analysis for ${path.basename(songPath)}:`, error);
        return null;
    } finally {
        tempFile.removeCallback();
    }
}

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
        if (!fs.existsSync(fullPath)) {
            await image.webp({ quality: 80 }).toFile(fullPath);
        }
        if (!fs.existsSync(thumbPath)) {
            await image.resize(100, 100).webp({ quality: 75 }).toFile(thumbPath);
        }
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
        const updatedLibrary = library.concat(uniqueNewSongs);
        libraryStore.save(updatedLibrary);
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

    ipcMain.on('start-scan-paths', async (event, paths) => {
        console.time('Main: Total Import Process');

        const pLimit = (await import('p-limit')).default;
        const libraryPath = settingsStore.load().libraryPath;
        if (!libraryPath) {
            event.sender.send('scan-complete', []);
            return;
        }
    
        console.time('Main: scanPaths');
        const sourceFiles = await scanPaths(paths);
        console.timeEnd('Main: scanPaths');
        
        if (sourceFiles.length === 0) {
            event.sender.send('scan-complete', []);
            return;
        }

        console.time('Main: parseFiles');
        const songsWithMetadata = await parseFiles(sourceFiles);
        console.timeEnd('Main: parseFiles');
        
        const loudnessData = loudnessStore.load();
        const existingLibraryPaths = new Set(libraryStore.load().map(s => s.path));
        
        const songsToProcess = songsWithMetadata.filter(song => {
            const primaryArtist = song.albumartist || song.artist || 'Unknown Artist';
            const artistDir = sanitize(primaryArtist);
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destDir = path.join(libraryPath, artistDir, albumDir);
            const originalFileName = path.basename(song.path);
            const safeFileName = sanitize(originalFileName);
            const destPath = path.join(destDir, safeFileName);
            return !existingLibraryPaths.has(destPath);
        });

        if (songsToProcess.length === 0) {
            event.sender.send('scan-complete', []);
            console.timeEnd('Main: Total Import Process');
            return;
        }

        const totalSteps = songsToProcess.length * 2;
        let completedSteps = 0;
    
        const sendProgress = () => {
            if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('scan-progress', { current: completedSteps, total: totalSteps });
            }
        };
        sendProgress();
    
        completedSteps += songsToProcess.length;
        sendProgress();
    
        let concurrency = os.cpus().length;
        if (os.platform() === 'win32') {
            concurrency = Math.max(1, os.cpus().length - 1);
        }

        const limit = pLimit(concurrency);
        console.log(`[Loudness] Starting analysis with concurrency: ${concurrency}`);

        console.time('Main: Artwork, Copying, and Loudness Analysis');
        const analysisPromises = songsToProcess.map(song => {
            return limit(async () => {
                if (song.artwork) {
                    song.artwork = await saveArtworkToFile(song.artwork, song.path);
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
                
                completedSteps++;
                sendProgress();

                return song;
            });
        });

        const newSongObjects = await Promise.all(analysisPromises);
        console.timeEnd('Main: Artwork, Copying, and Loudness Analysis');
        
        if (newSongObjects.length > 0) {
            loudnessStore.save(loudnessData);
        }
        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        
        event.sender.send('scan-complete', addedSongs);
        console.timeEnd('Main: Total Import Process');
    });

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
        console.time('Main: Load library & albums JSON');
        const songs = libraryStore.load() || [];
        const albums = albumsStore.load() || {};
        console.timeEnd('Main: Load library & albums JSON');
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('load-library', { songs, albums });
        }
    });

    ipcMain.on('debug-reset-library', (event) => {
        try {
            libraryStore.save([]);
            loudnessStore.save({});
            playCountsStore.save({});
            albumsStore.save({});
            
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            if (fs.existsSync(artworksDir)) {
                fs.rmSync(artworksDir, { recursive: true, force: true });
            }
            
            const settings = settingsStore.load();
            const libraryPath = settings.libraryPath;

            if (libraryPath && fs.existsSync(libraryPath)) {
                console.log(`[DEBUG] Deleting music library folder contents at: ${libraryPath}`);
                fs.rmSync(libraryPath, { recursive: true, force: true });
                fs.mkdirSync(libraryPath, { recursive: true });
            }

            console.log('[DEBUG] Library has been reset completely.');
            if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('force-reload-library');
            }
        } catch (error) {
            console.error('[DEBUG] Failed to reset library:', error);
        }
    });
}


module.exports = { registerLibraryHandlers };