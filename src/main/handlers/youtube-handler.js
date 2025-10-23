const { ipcMain, app } = require('electron');
const path = require('path');
const fs = require('fs');
const { sanitize } = require('../utils');
const { analyzeLoudness } = require('../file-scanner');
const { saveArtworkToFile } = require('./library-handler');
const crypto = require('crypto');
const YTDlpWrap = require('yt-dlp-wrap').default; // Use default import

let libraryStore;
let settingsStore;
let playlistManager;
let addSongsToLibraryAndSave;
let loudnessStore;
let ytDlpWrap; // yt-dlp instance

async function initializeYTDlp() {
    if (ytDlpWrap) return;
    try {
        const ytDlpBinaryName = process.platform === 'win32' ? 'yt-dlp.exe' : 'yt-dlp';
        let ytDlpPath;
        const isPackaged = app.isPackaged;

        if (isPackaged) {
            const resourcesPath = process.resourcesPath;
            // First try the standard asar unpacked location
            ytDlpPath = path.join(resourcesPath, 'app.asar.unpacked', 'node_modules', 'yt-dlp-wrap', 'bin', ytDlpBinaryName);
            console.log(`[yt-dlp] Packaged mode detected. Trying path: ${ytDlpPath}`);
            if (!fs.existsSync(ytDlpPath)) {
                // Fallback for potentially different build structures
                 ytDlpPath = path.join(resourcesPath, '..', 'node_modules', 'yt-dlp-wrap', 'bin', ytDlpBinaryName);
                 console.log(`[yt-dlp] Trying alternative packaged path: ${ytDlpPath}`);
            }
             if (!fs.existsSync(ytDlpPath)) {
                 // Try finding it adjacent to the binary if it was copied differently
                ytDlpPath = path.join(path.dirname(app.getPath('exe')), ytDlpBinaryName);
                 console.log(`[yt-dlp] Trying path adjacent to executable: ${ytDlpPath}`);
            }
        } else {
             // Development environment
             ytDlpPath = path.join(app.getAppPath(), 'node_modules', 'yt-dlp-wrap', 'bin', ytDlpBinaryName);
             console.log(`[yt-dlp] Development mode detected. Using path: ${ytDlpPath}`);
        }

        if (!fs.existsSync(ytDlpPath)) {
             console.log(`[yt-dlp] yt-dlp executable not found at ${ytDlpPath}. Downloading...`);
             const downloadDir = path.dirname(ytDlpPath);
             if (!fs.existsSync(downloadDir)) {
                 fs.mkdirSync(downloadDir, { recursive: true });
             }
             // Ensure YTDlpWrap downloads to the expected *file* path, not just directory
             await YTDlpWrap.downloadFromGithub(ytDlpPath);
             console.log('[yt-dlp] Download complete.');
        } else {
             console.log(`[yt-dlp] Found yt-dlp executable at: ${ytDlpPath}`);
        }
        ytDlpWrap = new YTDlpWrap(ytDlpPath);
        console.log('[yt-dlp] Wrapper initialized.');
    } catch (error) {
        console.error('[yt-dlp] Failed to initialize yt-dlp:', error);
        ytDlpWrap = null;
    }
}


function findHubUrl(description) {
    if (typeof description !== 'string') return null;
    const hubUrlRegex = /(https?:\/\/(?:www\.)?(?:linkco\.re|fanlink\.to|fanlink\.tv|lnk\.to)\/[\w\-\/.\?=&#]+)/;
    const match = description.match(hubUrlRegex);
    return match ? match[0] : null;
}

async function fetchThumbnail(thumbnailUrl) {
    try {
        const response = await fetch(thumbnailUrl, {
             agent: new (require('https').Agent)({ rejectUnauthorized: false })
        });
        if (!response.ok) {
            throw new Error(`Failed to fetch thumbnail: ${response.statusText}`);
        }
        const buffer = Buffer.from(await response.arrayBuffer());
        return { data: buffer };
    } catch (error) {
        console.error(`Failed to download thumbnail from ${thumbnailUrl}:`, error);
        return null;
    }
}


async function processYouTubeVideo(videoInfo, sourceUrl) {
    await initializeYTDlp();
    if (!ytDlpWrap) {
        throw new Error('yt-dlp is not initialized.');
    }

    const details = videoInfo;
    const hubUrl = findHubUrl(details.description);
    const settings = settingsStore.load();
    const mode = settings.youtubePlaybackMode || 'download';
    
    let artworkData = null;
    const thumbnailUrl = details.thumbnail;
    if (thumbnailUrl) {
        artworkData = await fetchThumbnail(thumbnailUrl);
    }

    if (mode === 'stream') {
        // ... (stream mode logic remains the same) ...
        return {
            id: crypto.randomUUID(),
            path: sourceUrl,
            title: details.title,
            artist: details.uploader || 'YouTube',
            album: 'YouTube',
            artwork: thumbnailUrl,
            duration: details.duration,
            type: 'youtube',
            hasVideo: true,
            hubUrl: hubUrl
        };
    }

    // --- ▼▼▼ Download Logic Changes Start ▼▼▼ ---
    const qualitySetting = settings.youtubeDownloadQuality || 'full';
    let formatCode;
    let fileExtension;
    let hasVideo = false;

    if (qualitySetting === 'audio_only') {
        formatCode = 'bestaudio[ext=m4a]/bestaudio';
        fileExtension = '.m4a';
        hasVideo = false;
    } else {
        formatCode = 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best';
        fileExtension = '.mp4';
        hasVideo = true;
    }

    const libraryPath = settings.libraryPath;
    const artistName = details.uploader || details.channel || 'YouTube';
    const artistDir = sanitize(artistName);
    const destDir = path.join(libraryPath, artistDir);
    if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
    
    const safeFileNameBase = sanitize(details.title);
    const finalPath = path.join(destDir, safeFileNameBase + fileExtension); // Final destination path

    console.log(`[YouTube Handler] Starting download for "${details.title}" to ${finalPath}`);

    // Download using yt-dlp, outputting directly to the final path
    await new Promise((resolve, reject) => {
        ytDlpWrap.exec([
            sourceUrl,
            '--no-check-certificate',
            '-f', formatCode,
            '-o', finalPath, // Output directly to the final path
            '--no-playlist',
             // '--no-continue', // yt-dlp handles resuming better, might remove this
             '--force-overwrites', // Ensure it overwrites if file exists (e.g., from failed attempt)
             '--concurrent-fragments', '4', // Example: Use multiple fragments for potentially faster download
        ])
        .on('ytDlpEvent', (eventType, eventData) => console.log(`[yt-dlp Event: ${eventType}] ${eventData}`))
        .on('error', (error) => {
            console.error(`[yt-dlp Download Error] ${error}`);
             // Clean up the potentially incomplete final file on error
             if (fs.existsSync(finalPath)) {
                 try {
                     fs.unlinkSync(finalPath);
                     console.log(`[YouTube Handler] Cleaned up incomplete file: ${finalPath}`);
                 } catch (unlinkError) {
                     console.error(`[YouTube Handler] Failed to clean up incomplete file: ${finalPath}`, unlinkError);
                 }
             }
            reject(error);
        })
        .on('close', (code) => {
             // Check the exit code. 0 usually means success.
             if (code === 0) {
                 if (fs.existsSync(finalPath)) {
                     console.log(`[YouTube Handler] Download finished successfully for ${safeFileNameBase}`);
                     resolve();
                 } else {
                     reject(new Error(`yt-dlp finished but output file not found at ${finalPath}`));
                 }
             } else {
                 reject(new Error(`yt-dlp process exited with code ${code}`));
             }
        });
    });
    // --- ▲▲▲ Download Logic Changes End ▲▲▲ ---


    console.log(`[YouTube Handler] Starting loudness analysis for ${safeFileNameBase}`);
    const loudnessResult = await analyzeLoudness(finalPath);
    if (loudnessResult.success) {
        const loudnessData = loudnessStore.load();
        loudnessData[finalPath] = loudnessResult.loudness;
        loudnessStore.save(loudnessData);
        console.log(`[YouTube Handler] Loudness analysis successful: ${loudnessResult.loudness} LUFS`);
    } else {
        console.error(`[YouTube Handler] Loudness analysis failed for ${safeFileNameBase}:`, loudnessResult.error);
    }

    const stats = fs.statSync(finalPath);
    const savedArtwork = await saveArtworkToFile(artworkData, artistName, details.title);

    return {
        id: crypto.randomUUID(),
        path: finalPath,
        title: details.title,
        artist: artistName,
        album: artistName,
        artwork: savedArtwork,
        duration: details.duration,
        fileSize: stats.size,
        type: 'local',
        sourceURL: sourceUrl,
        hasVideo: hasVideo,
        hubUrl: hubUrl
    };
}

async function getYoutubeVideoInfo(url) {
    await initializeYTDlp();
    if (!ytDlpWrap) {
        throw new Error('yt-dlp is not initialized.');
    }
    console.log(`[YouTube Handler] Fetching video info for ${url}`);
    const videoInfo = await ytDlpWrap.getVideoInfo([
        url,
        '--no-check-certificate',
        '--dump-json'
    ]);
    console.log(`[YouTube Handler] Info fetched for ${videoInfo.title}`);
    return videoInfo;
}

function registerYouTubeHandlers(stores, managers) {
    libraryStore = stores.library;
    settingsStore = stores.settings;
    loudnessStore = stores.loudness;
    playlistManager = managers.playlist;
    addSongsToLibraryAndSave = managers.addSongsFunc;

    initializeYTDlp(); // Initialize on handler registration

    ipcMain.on('import-youtube-playlist', async (event, playlistUrl) => {
        await initializeYTDlp();
        if (!ytDlpWrap) {
            event.sender.send('show-error', 'yt-dlpの初期化に失敗しました。');
            return;
        }

        const window = event.sender;
        let playlistInfo;
        try {
             console.log(`[YouTube Handler] Fetching playlist info for ${playlistUrl}`);
             playlistInfo = await ytDlpWrap.getVideoInfo([
                 playlistUrl,
                 '--no-check-certificate',
                 '--flat-playlist',
                 '-J' // Output JSON
             ]);

             if (!playlistInfo || !playlistInfo.entries || playlistInfo.entries.length === 0) {
                 throw new Error('Playlist is empty or invalid.');
             }
             console.log(`[YouTube Handler] Found ${playlistInfo.entries.length} items in playlist.`);

        } catch(error) {
            console.error('Playlist import error (yt-dlp failed):', error);
            window.send('show-error', 'プレイリスト情報の取得に失敗しました。URLを確認するか、プレイリストが公開されているか確認してください。');
            return;
        }

        const total = playlistInfo.entries.length;
        const playlistTitle = sanitize(playlistInfo.title || `Youtubelist ${Date.now()}`);
        playlistManager.createPlaylist(playlistTitle);
        
        for (let i = 0; i < total; i++) {
            const item = playlistInfo.entries[i];
            const itemUrl = item.url;
            const itemTitle = item.title || 'Unknown Title';
            try {
                window.send('playlist-import-progress', { current: i + 1, total: total, title: itemTitle });
                
                const videoInfo = await getYoutubeVideoInfo(itemUrl); // Use helper
                
                const newSong = await processYouTubeVideo(videoInfo, itemUrl);
                
                addSongsToLibraryAndSave([newSong]); // Add to library first
                playlistManager.addSongToPlaylist(playlistTitle, newSong); // Then add to playlist
            } catch (error) {
                console.error(`Skipping video "${itemTitle}" due to error:`, error.message);
                continue; // Continue with the next item in the playlist
            }
        }
        window.send('playlist-import-finished');
    });

    ipcMain.on('add-youtube-link', async (event, url) => {
        await initializeYTDlp();
         if (!ytDlpWrap) {
             event.sender.send('show-error', 'yt-dlpの初期化に失敗しました。');
             return;
         }

        const window = event.sender;
        try {
            if (!url || !url.startsWith('http')) {
                window.send('show-error', '無効なURLです。');
                return;
            }
            
            const settings = settingsStore.load();
            if ((settings.youtubePlaybackMode || 'download') === 'download') {
                window.send('show-loading', 'YouTube動画をダウンロード中...');
            }

            const videoInfo = await getYoutubeVideoInfo(url); // Use helper

            const newSong = await processYouTubeVideo(videoInfo, url);

            addSongsToLibraryAndSave([newSong]);
             window.send('youtube-link-processed', newSong);

        } catch (error) {
            console.error('YouTube処理エラー:', error.message);
            window.send('show-error', `YouTube楽曲の処理に失敗しました: ${error.message}`);
        } finally {
            window.send('hide-loading');
        }
    });
}


module.exports = { registerYouTubeHandlers };