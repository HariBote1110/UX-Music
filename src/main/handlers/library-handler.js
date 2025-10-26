const { ipcMain, app, dialog } = require('electron'); // dialog を追加
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
// analyzeLoudness は worker に移動したので削除
const { scanPaths, parseFiles } = require('../file-scanner'); // analyzeLoudness への参照を削除
const os = require('os');
const { sanitize } = require('../utils');
const sharp = require('sharp');
const { Worker } = require('worker_threads');

let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;
let albumsStore;

async function saveArtworkToFile(picture, albumArtist, albumTitle) {
    if (!picture || !picture.data) {
        // console.log('[Import Debug] No picture data provided for artwork save.');
        return null;
    }
    const artworksDir = path.join(app.getPath('userData'), 'Artworks');
    const thumbnailsDir = path.join(artworksDir, 'thumbnails');
    // Ensure directories exist synchronously as this runs during setup phase often
    try {
        if (!fs.existsSync(artworksDir)) fs.mkdirSync(artworksDir, { recursive: true });
        if (!fs.existsSync(thumbnailsDir)) fs.mkdirSync(thumbnailsDir, { recursive: true });
    } catch (dirError) {
        console.error('[Import Debug] Failed to create artwork directories:', dirError);
        return null;
    }


    const uniqueKey = `${albumArtist || 'Unknown Artist'}-${albumTitle || 'Unknown Album'}`;
    const hash = crypto.createHash('sha256').update(uniqueKey).digest('hex');

    const fullFileName = `${hash}.webp`;
    const thumbFileName = `${hash}_thumb.webp`;
    const fullPath = path.join(artworksDir, fullFileName);
    const thumbPath = path.join(thumbnailsDir, thumbFileName);
    try {
        const image = sharp(picture.data);
        const writeFull = !fs.existsSync(fullPath);
        const writeThumb = !fs.existsSync(thumbPath);
        
        const promises = [];
        if (writeFull) {
            console.log(`[Import Debug] Writing full artwork: ${fullPath}`);
            promises.push(image.clone().webp({ quality: 80 }).toFile(fullPath));
        }
        if (writeThumb) {
            console.log(`[Import Debug] Writing thumbnail artwork: ${thumbPath}`);
            promises.push(image.clone().resize(100, 100).webp({ quality: 75 }).toFile(thumbPath));
        }
        
        await Promise.all(promises);

        return { full: fullFileName, thumbnail: thumbFileName };
    } catch (error) {
        console.error(`[Import Debug] Failed to save artwork for album "${albumTitle}" by "${albumArtist}":`, error);
        return null; // Return null if artwork saving fails
    }
}


function addSongsToLibraryAndSave(newSongs) {
    console.log('[Import Debug] Adding songs to library:', newSongs.map(s => s?.title || 'Invalid Song Object'));
    const library = libraryStore.load() || [];
    const existingPaths = new Set(library.map(s => s.path));
    // Add checks for s and s.path before accessing them
    const uniqueNewSongs = newSongs.filter(s => s && s.path && !existingPaths.has(s.path));
    console.log(`[Import Debug] ${uniqueNewSongs.length} unique new songs found.`);
    if (uniqueNewSongs.length > 0) {
        libraryStore.save([...library, ...uniqueNewSongs]);
        console.log('[Import Debug] Library saved.');
    } else {
        console.log('[Import Debug] No unique songs to add to library.');
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
        console.log(`[Import Debug] Received BPM analysis request for: ${song?.title}`);
        const { analyzeBPM } = require('../file-scanner');
        const bpm = await analyzeBPM(song.path);
        console.log(`[Import Debug] BPM analysis result for ${song?.title}: ${bpm}`);
        if (bpm !== null) {
            const library = libraryStore.load() || [];
            const songIndex = library.findIndex(s => s.id === song.id); // Find by ID
            if (songIndex > -1) {
                library[songIndex].bpm = bpm;
                libraryStore.save(library);
                sendToAllWindows('bpm-analysis-complete', library[songIndex]);
                console.log(`[Import Debug] Updated BPM for ${song?.title} in library.`);
            } else {
                 console.warn(`[Import Debug] Could not find song with ID ${song.id} in library to update BPM.`);
            }
        }
    });

    // Handler for loudness analysis request (e.g., when playing a song without loudness data)
    ipcMain.on('request-loudness-analysis', async (event, filePath) => {
        console.log(`[Import Debug] Received loudness analysis request for: ${filePath}`);
        // Use the function directly from file-scanner for single analysis
        const { analyzeLoudness } = require('../file-scanner');
        const result = await analyzeLoudness(filePath);
        console.log(`[Import Debug] Loudness analysis result for ${filePath}:`, result);
        if (result.success) {
            const loudnessData = loudnessStore.load();
            loudnessData[filePath] = result.loudness;
            loudnessStore.save(loudnessData);
             console.log(`[Import Debug] Saved loudness for ${filePath}.`);
        }
         // Always send result back to renderer
         if (event.sender && !event.sender.isDestroyed()) {
             event.sender.send('loudness-analysis-result', result);
         }
    });

    ipcMain.on('start-scan-paths', async (event, paths) => {
        console.log('[Import Debug] Received start-scan-paths event with paths:', paths);
        console.time('Main: Total Import Process');

        const finishScan = (resultSongs) => {
            const finalResult = Array.isArray(resultSongs) ? resultSongs : [];
            console.log(`[Import Debug] Scan complete. Sending ${finalResult.length} added songs to renderer.`);
             if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('scan-complete', finalResult);
             }
            console.timeEnd('Main: Total Import Process');
        };

        const settings = settingsStore.load();
        let libraryPath = settings.libraryPath;
        console.log(`[Import Debug] Current library path from settings: ${libraryPath}`);

        if (!libraryPath) {
             console.log('[Import Debug] Library path not set. Prompting user.');
            const result = await dialog.showOpenDialog({
                properties: ['openDirectory'],
                title: 'ライブラリとして使用するフォルダを選択してください'
            });
            if (!result.canceled && result.filePaths.length > 0) {
                libraryPath = result.filePaths[0];
                settings.libraryPath = libraryPath;
                settingsStore.save(settings);
                console.log(`[Import Debug] Library path set by user to: ${libraryPath}`);
            } else {
                console.error('[Import Debug] Library path selection was canceled by user.');
                return finishScan([]);
            }
        }

        // --- Start of Import Logic ---
        console.time('Main: Scan Source Paths');
        const sourceFiles = await scanPaths(paths);
        console.timeEnd('Main: Scan Source Paths');
        console.log(`[Import Debug] Found ${sourceFiles.length} potential source files:`, sourceFiles);
        if (sourceFiles.length === 0) {
            return finishScan([]);
        }

        console.time('Main: Parse Metadata');
        const songsWithMetadata = await parseFiles(sourceFiles);
        console.timeEnd('Main: Parse Metadata');
        console.log(`[Import Debug] Parsed metadata for ${songsWithMetadata.length} files.`);

        const existingLibrary = libraryStore.load() || [];
        const existingLibraryPaths = new Set(existingLibrary.map(s => s.path));
        console.log(`[Import Debug] Existing library has ${existingLibrary.length} songs.`);

        // Filter songs based on potential destination path *before* further processing
        const songsToProcess = songsWithMetadata.map(song => {
             const artistDir = sanitize(song.albumartist || song.artist || 'Unknown Artist');
             const albumDir = sanitize(song.album || 'Unknown Album');
             const destFileName = sanitize(path.basename(song.path));
             const destPath = path.join(libraryPath, artistDir, albumDir, destFileName);
             return { ...song, originalPath: song.path, potentialDestPath: destPath };
        }).filter(song => {
            const shouldProcess = !existingLibraryPaths.has(song.potentialDestPath);
            // if (!shouldProcess) {
            //     console.log(`[Import Debug] Skipping (already exists): ${song.potentialDestPath}`);
            // }
            return shouldProcess;
        });

        console.log(`[Import Debug] Found ${songsToProcess.length} songs to process after filtering existing.`);
        if (songsToProcess.length === 0) {
            return finishScan([]);
        }

        // --- Process artwork (album-based) ---
        console.time('Main: Process Artwork');
        const albumsToProcessMap = new Map();
        songsToProcess.forEach(song => {
            const albumKey = `${song.albumartist || song.artist || 'Unknown Artist'}-${song.album || 'Unknown Album'}`;
            if (!albumsToProcessMap.has(albumKey)) {
                albumsToProcessMap.set(albumKey, { songs: [], artworkPicture: null, albumArtist: song.albumartist || song.artist, albumTitle: song.album });
            }
            const albumGroup = albumsToProcessMap.get(albumKey);
            albumGroup.songs.push(song);
            if (!albumGroup.artworkPicture && song.artwork) {
                albumGroup.artworkPicture = song.artwork;
            }
        });

         console.log(`[Import Debug] Processing artwork for ${albumsToProcessMap.size} albums.`);
        for (const [key, group] of albumsToProcessMap.entries()) {
            const savedArtworkObject = await saveArtworkToFile(group.artworkPicture, group.albumArtist, group.albumTitle);
             // console.log(`[Import Debug] Saved artwork for album ${key}:`, savedArtworkObject);
            group.songs.forEach(song => {
                song.artwork = savedArtworkObject;
            });
        }
        console.timeEnd('Main: Process Artwork');


        // --- Start worker pool for analysis ---
        const totalSteps = songsToProcess.length;
        let completedSteps = 0;
        const sendProgress = () => {
             if (event.sender && !event.sender.isDestroyed()) {
                 event.sender.send('scan-progress', { current: completedSteps, total: totalSteps });
             }
        };
        sendProgress(); // Initial progress 0%

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

        console.log(`[Import Debug] Starting analysis in ${importMode} mode. Concurrency: ${concurrency} for ${songsToProcess.length} files`);

        const newSongObjects = []; // Store results here
        const loudnessData = loudnessStore.load() || {}; // Load existing loudness data
        
        await new Promise(resolve => {
            let runningWorkers = 0;
            const queue = [...songsToProcess]; // Use the filtered list

            const onWorkerExit = () => {
                runningWorkers--;
                // console.log(`[Import Debug] Worker exited. Running: ${runningWorkers}, Queue: ${queue.length}`);
                if (queue.length > 0) {
                    startWorker(); // Start next task if available
                } else if (runningWorkers === 0) {
                    console.log('[Import Debug] All workers finished.');
                    resolve(); // All tasks done
                }
            };

            function startWorker() {
                if (runningWorkers >= concurrency || queue.length === 0) return; // Limit concurrency or stop if queue empty
                
                runningWorkers++;
                const songToProcess = queue.shift(); // Get song from the queue
                 // console.log(`[Import Debug] Starting worker ${runningWorkers}/${concurrency} for: ${songToProcess.originalPath}`);
                
                const worker = new Worker(path.join(__dirname, '..', 'analysis-worker.js'));

                worker.postMessage({
                    type: 'init',
                    ffmpegPath: require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked'),
                    ffprobePath: require('ffprobe-static').path.replace('app.asar', 'app.asar.unpacked')
                });

                // --- Copy file *before* sending to worker ---
                try {
                     const destPath = songToProcess.potentialDestPath;
                     const destDir = path.dirname(destPath);
                     if (!fs.existsSync(destDir)) {
                         fs.mkdirSync(destDir, { recursive: true });
                     }
                     if (songToProcess.originalPath !== destPath && !fs.existsSync(destPath)) {
                         fs.copyFileSync(songToProcess.originalPath, destPath);
                         // console.log(`[Import Debug] Copied ${path.basename(songToProcess.originalPath)} to ${destPath}`);
                     } else {
                         // console.log(`[Import Debug] File already exists or source/dest are same, skipping copy: ${destPath}`);
                     }
                    songToProcess.path = destPath; // Update path to the copied/final location
                     console.log(`[Import Debug] Sending to worker: ${songToProcess.title} (Path: ${songToProcess.path})`);
                     worker.postMessage({ type: 'analyze', song: songToProcess });

                } catch (copyError) {
                     console.error(`[Import Debug] Failed to copy file ${songToProcess.originalPath} to ${songToProcess.potentialDestPath}:`, copyError);
                     if (event.sender && !event.sender.isDestroyed()) {
                         event.sender.send('scan-error', { file: path.basename(songToProcess.originalPath), error: copyError.message });
                     }
                     completedSteps++;
                     sendProgress();
                     worker.terminate(); // Terminate worker if copy fails
                     // onWorkerExit will be called automatically by 'exit' event
                     return; // Don't proceed further for this song
                }
                // --- End Copy file logic ---


                worker.on('message', (result) => {
                     // console.log(`[Import Debug] Worker result received for: ${songToProcess.title}`);
                     if (result && result.type === 'result' && result.song) {
                         const finalSong = result.song;
                         if (typeof finalSong.loudness === 'number') {
                             loudnessData[finalSong.path] = finalSong.loudness;
                             delete finalSong.loudness;
                         }
                         
                         // console.log(`[Import Debug] Finished analysis for: ${finalSong.artist} - ${finalSong.title}`);
                         newSongObjects.push(finalSong);
                     } else {
                         console.error(`[Import Debug] Worker returned unexpected result format for ${songToProcess.originalPath}:`, result);
                     }
                    completedSteps++;
                    sendProgress();
                    worker.terminate(); // Terminate after successful processing
                });

                worker.on('exit', onWorkerExit); // Handle worker exit (success or error)
                worker.on('error', (err) => {
                    console.error(`[Import Debug] Worker error for ${songToProcess.originalPath}:`, err);
                    completedSteps++; // Count as processed even on error
                    sendProgress();
                    // Don't call onWorkerExit here, 'exit' event will handle it
                });
            }

            // Start initial batch of workers
             console.log(`[Import Debug] Starting initial ${Math.min(concurrency, queue.length)} workers.`);
            for (let i = 0; i < concurrency && i < queue.length; i++) {
                startWorker();
            }
        });
        
         // Sort based on original order (using originalPath stored before copy)
         const originalPathMap = new Map(songsToProcess.map(s => [s.id, s.originalPath]));
         const sourceOrderMap = new Map(sourceFiles.map((p, index) => [p, index]));
         newSongObjects.sort((a, b) => {
             const pathA = originalPathMap.get(a.id) || a.path;
             const pathB = originalPathMap.get(b.id) || b.path;
             const orderA = sourceOrderMap.get(pathA);
             const orderB = sourceOrderMap.get(pathB);

             if (orderA === undefined) return 1;
             if (orderB === undefined) return -1;
             return orderA - orderB;
         });


        // Clean up temporary properties before saving
        newSongObjects.forEach(song => {
             delete song.originalPath;
             delete song.potentialDestPath;
        });

        // Save loudness data and add songs to library
        if (newSongObjects.length > 0) {
            console.log(`[Import Debug] Saving loudness data for ${Object.keys(loudnessData).length} entries.`);
            loudnessStore.save(loudnessData);
            console.log(`[Import Debug] Adding ${newSongObjects.length} new songs to library.`);
            const addedSongs = addSongsToLibraryAndSave(newSongObjects);
            finishScan(addedSongs);
        } else {
             console.log('[Import Debug] No new songs were successfully analyzed or added.');
             finishScan([]);
        }
    });

    ipcMain.handle('get-loudness-value', (event, songPath) => (loudnessStore.load() || {})[songPath] || null);

    ipcMain.on('request-initial-library', (event) => {
         console.log('[Import Debug] Received request-initial-library.');
        const songs = libraryStore.load() || [];
        const albums = albumsStore.load() || {};
        if (event.sender && !event.sender.isDestroyed()) {
             event.sender.send('load-library', { songs, albums });
             console.log(`[Import Debug] Sent initial library (${songs.length} songs, ${Object.keys(albums).length} albums)`);
        }
    });

    ipcMain.on('debug-reset-library', (event) => {
        try {
             console.log('[Import Debug] Received debug-reset-library.');
            libraryStore.save([]);
            loudnessStore.save({});
            playCountsStore.save({});
            albumsStore.save({});
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            if (fs.existsSync(artworksDir)) {
                 console.log('[Import Debug] Removing artworks directory.');
                 fs.rmSync(artworksDir, { recursive: true, force: true });
            }
            console.log('[DEBUG] Library data (json, loudness, counts, artworks) has been reset.');
             if (event.sender && !event.sender.isDestroyed()) {
                 event.sender.send('force-reload-library');
             }
        } catch (error) {
            console.error('[DEBUG] Failed to reset library:', error);
        }
    });
}

module.exports = { 
    registerLibraryHandlers,
    saveArtworkToFile
};