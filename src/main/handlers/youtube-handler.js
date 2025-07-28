const { ipcMain } = require('electron');
const ytdl = require('@distube/ytdl-core');
const ytpl = require('ytpl');
const path = require('path');
const fs = require('fs');
const { sanitize } = require('../utils');
const { analyzeLoudness } = require('../file-scanner');

let libraryStore;
let settingsStore;
let playlistManager;
let addSongsToLibraryAndSave;
let loudnessStore;

function findHubUrl(description) {
    if (typeof description !== 'string') return null;
    const hubUrlRegex = /(https?:\/\/(?:www\.)?(?:linkco\.re|fanlink\.to|fanlink\.tv|lnk\.to)\/[\w\-\/.\?=&#]+)/;
    const match = description.match(hubUrlRegex);
    return match ? match[0] : null;
}

function registerYouTubeHandlers(stores, managers) {
    libraryStore = stores.library;
    settingsStore = stores.settings;
    loudnessStore = stores.loudness;
    playlistManager = managers.playlist;
    addSongsToLibraryAndSave = managers.addSongsFunc;

    ipcMain.on('import-youtube-playlist', async (event, playlistUrl) => {
        const window = event.sender;
        let playlist;
        try {
            if (!ytpl.validateID(playlistUrl)) {
                window.send('show-error', '無効なYouTubeプレイリストのURLです。');
                return;
            }
            playlist = await ytpl(playlistUrl, { limit: Infinity });
        } catch(error) {
            console.error('Playlist import error (ytpl failed):', error);
            window.send('show-error', 'プレイリスト情報の取得に失敗しました。非公開または削除された動画が含まれている可能性があります。');
            return;
        }

        const total = playlist.items.length;
        const playlistTitle = sanitize(playlist.title);
        playlistManager.createPlaylist(playlistTitle);
        
        for (let i = 0; i < total; i++) {
            const item = playlist.items[i];
            try {
                window.send('playlist-import-progress', { current: i + 1, total: total, title: item.title });
                const videoInfo = await ytdl.getInfo(item.url);
                const newSong = await processYouTubeVideo(videoInfo, item.url);
                
                const addedSongs = addSongsToLibraryAndSave([newSong]);
                if (addedSongs.length > 0) {
                    window.send('youtube-link-processed', addedSongs[0]);
                }
                playlistManager.addSongToPlaylist(playlistTitle, newSong);
            } catch (error) {
                console.error(`Skipping video "${item.title}" due to error:`, error.message);
                continue;
            }
        }
        window.send('playlist-import-finished');
    });

    ipcMain.on('add-youtube-link', async (event, url) => {
        const window = event.sender;
        try {
            if (!ytdl.validateURL(url)) return;
            
            const settings = settingsStore.load();
            if ((settings.youtubePlaybackMode || 'download') === 'download') {
                window.send('show-loading', 'YouTube動画をダウンロード中...');
            }

            const info = await ytdl.getInfo(url);
            const newSong = await processYouTubeVideo(info, url);

            const addedSongs = addSongsToLibraryAndSave([newSong]);
            if (addedSongs.length > 0) {
                window.send('youtube-link-processed', addedSongs[0]);
            }
        } catch (error) {
            console.error('YouTube処理エラー:', error.message);
            window.send('show-error', `YouTube楽曲の処理に失敗しました: ${error.message}`);
        } finally {
            window.send('hide-loading');
        }
    });
}

async function processYouTubeVideo(info, sourceUrl) {
    const details = info.videoDetails;
    const hubUrl = findHubUrl(details.description);
    const settings = settingsStore.load();
    const mode = settings.youtubePlaybackMode || 'download';

    if (mode === 'stream') {
        return {
            path: sourceUrl,
            title: details.title,
            artist: details.author.name,
            album: 'YouTube',
            artwork: details.thumbnails[0].url,
            duration: Number(details.lengthSeconds),
            type: 'youtube', // ストリーミングの場合は'youtube'
            hasVideo: true,
            hubUrl: hubUrl
        };
    }

    const qualitySetting = settings.youtubeDownloadQuality || 'full';
    let format;
    let fileExtension;
    let hasVideo = false;

    if (qualitySetting === 'audio_only') {
        format = ytdl.chooseFormat(info.formats, { quality: 'highestaudio', filter: 'audioonly' });
        fileExtension = '.m4a';
        hasVideo = false;
    } else {
        format = ytdl.chooseFormat(info.formats, { quality: 'highest', filter: f => f.hasVideo && f.hasAudio });
        fileExtension = '.mp4';
        hasVideo = true;
    }

    if (!format) {
        throw new Error('No suitable download format found.');
    }

    const libraryPath = settings.libraryPath;
    const artistDir = sanitize(details.author.name || 'YouTube');
    const destDir = path.join(libraryPath, artistDir);
    if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
    
    const safeFileName = sanitize(details.title) + fileExtension;
    const destPath = path.join(destDir, safeFileName);

    const videoStream = ytdl(sourceUrl, { format: format });
    await new Promise((resolve, reject) => {
        videoStream.pipe(fs.createWriteStream(destPath)).on('finish', resolve).on('error', reject);
    });

    console.log(`[YouTube Handler] Starting loudness analysis for ${safeFileName}`);
    const loudnessResult = await analyzeLoudness(destPath);
    if (loudnessResult.success) {
        const loudnessData = loudnessStore.load();
        loudnessData[destPath] = loudnessResult.loudness;
        loudnessStore.save(loudnessData);
        console.log(`[YouTube Handler] Loudness analysis successful: ${loudnessResult.loudness} LUFS`);
    } else {
        console.error(`[YouTube Handler] Loudness analysis failed for ${safeFileName}:`, loudnessResult.error);
    }

    const stats = fs.statSync(destPath);
    return {
        path: destPath,
        title: details.title,
        artist: details.author.name,
        album: details.author.name, // ★★★ 修正: アルバム名をアーティスト(チャンネル)名に
        artwork: details.thumbnails[0].url,
        duration: Number(details.lengthSeconds),
        fileSize: stats.size,
        type: 'local', // ★★★ 修正: ダウンロードしたファイルは'local'として扱う
        sourceURL: sourceUrl,
        hasVideo: hasVideo,
        hubUrl: hubUrl
    };
}

module.exports = { registerYouTubeHandlers };