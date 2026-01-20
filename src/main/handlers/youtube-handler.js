const { ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const { sanitize } = require('../utils');
const { analyzeLoudness } = require('../file-scanner');
const { saveArtworkToFile } = require('./import-handler');
const IPC_CHANNELS = require('../ipc-channels');
const miniget = require('miniget');
const crypto = require('crypto');

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

async function processYouTubeVideo(info, sourceUrl) {
    const sidecarManager = require('../sidecar-manager');
    const settings = settingsStore.load();
    const mode = settings.youtubePlaybackMode || 'download';

    // Go 側から情報を取得 (既に info がある場合はスキップ可能だが、統一のため Go から取得)
    let videoInfo;
    try {
        videoInfo = await sidecarManager.invoke('youtube-info', { url: sourceUrl });
    } catch (err) {
        console.error('[YouTube Handler] Go sidecar youtube-info failed:', err);
        throw err;
    }

    if (mode === 'stream') {
        // ストリーミングモード: 直接 URL を返す
        let streamUrl;
        try {
            const result = await sidecarManager.invoke('youtube-stream-url', { url: sourceUrl });
            streamUrl = result.url;
        } catch (err) {
            console.warn('[YouTube Handler] Stream URL fetch failed, using source URL:', err);
            streamUrl = sourceUrl;
        }

        return {
            id: crypto.randomUUID(),
            path: streamUrl,
            title: videoInfo.title,
            artist: videoInfo.author,
            album: 'YouTube',
            artwork: videoInfo.thumbnail,
            duration: videoInfo.duration,
            type: 'youtube',
            hasVideo: true,
            hubUrl: videoInfo.hubUrl
        };
    }

    // ダウンロードモード
    const libraryPath = settings.libraryPath;
    const audioOnly = (settings.youtubeDownloadQuality || 'full') === 'audio_only';

    let downloadResult;
    try {
        downloadResult = await sidecarManager.invoke('youtube-download', {
            url: sourceUrl,
            destDir: libraryPath,
            audioOnly: audioOnly
        }, 600000); // 10分タイムアウト
    } catch (err) {
        console.error('[YouTube Handler] Go sidecar youtube-download failed:', err);
        throw err;
    }

    // ラウドネス解析 (Go 側で実装済み)
    try {
        const analysisResult = await sidecarManager.invoke('analyze-song', { path: downloadResult.path });
        if (analysisResult && analysisResult.loudness !== null) {
            const loudnessData = loudnessStore.load() || {};
            loudnessData[downloadResult.path] = analysisResult.loudness;
            loudnessStore.save(loudnessData);
            console.log(`[YouTube Handler] Loudness analysis: ${analysisResult.loudness} dB`);
        }
    } catch (err) {
        console.warn('[YouTube Handler] Loudness analysis failed:', err);
    }

    // アートワーク保存
    let savedArtwork = null;
    if (downloadResult.thumbnail) {
        try {
            const artworkData = await downloadThumbnail(downloadResult.thumbnail);
            savedArtwork = await saveArtworkToFile({ data: artworkData }, downloadResult.path);
        } catch (err) {
            console.warn('[YouTube Handler] Artwork save failed:', err);
            savedArtwork = downloadResult.thumbnail;
        }
    }

    return {
        id: crypto.randomUUID(),
        path: downloadResult.path,
        title: downloadResult.title,
        artist: downloadResult.artist,
        album: downloadResult.artist,
        artwork: savedArtwork,
        duration: downloadResult.duration,
        fileSize: downloadResult.fileSize,
        type: 'local',
        sourceURL: sourceUrl,
        hasVideo: !audioOnly,
        hubUrl: downloadResult.hubUrl
    };
}

// サムネイルダウンロード用ヘルパー
async function downloadThumbnail(url) {
    return new Promise((resolve, reject) => {
        const stream = miniget(url);
        const chunks = [];
        stream.on('data', chunk => chunks.push(chunk));
        stream.on('end', () => resolve(Buffer.concat(chunks)));
        stream.on('error', reject);
    });
}


function registerYouTubeHandlers(stores, managers) {
    libraryStore = stores.library;
    settingsStore = stores.settings;
    loudnessStore = stores.loudness;
    playlistManager = managers.playlist;
    addSongsToLibraryAndSave = managers.addSongsFunc;

    ipcMain.on(IPC_CHANNELS.SEND.IMPORT_YOUTUBE_PLAYLIST, async (event, playlistUrl) => {
        const ytpl = require('ytpl');

        const window = event.sender;
        let playlist;
        try {
            if (!ytpl.validateID(playlistUrl)) {
                window.send(IPC_CHANNELS.ON.SHOW_ERROR, '無効なYouTubeプレイリストのURLです。');
                return;
            }
            playlist = await ytpl(playlistUrl, { limit: Infinity });
        } catch (error) {
            console.error('Playlist import error (ytpl failed):', error);
            window.send(IPC_CHANNELS.ON.SHOW_ERROR, 'プレイリスト情報の取得に失敗しました。非公開または削除された動画が含まれている可能性があります。');
            return;
        }

        const total = playlist.items.length;
        const playlistTitle = sanitize(playlist.title);
        playlistManager.createPlaylist(playlistTitle);

        for (let i = 0; i < total; i++) {
            const item = playlist.items[i];
            try {
                window.send(IPC_CHANNELS.ON.PLAYLIST_IMPORT_PROGRESS, { current: i + 1, total: total, title: item.title });
                // Go 側で情報取得も行うので URL のみを渡す
                const newSong = await processYouTubeVideo(null, item.url);

                const addedSongs = addSongsToLibraryAndSave([newSong]);
                if (addedSongs.length > 0) {
                    window.send(IPC_CHANNELS.ON.YOUTUBE_LINK_PROCESSED, addedSongs[0]);
                }
                playlistManager.addSongToPlaylist(playlistTitle, newSong);
            } catch (error) {
                console.error(`Skipping video "${item.title}" due to error:`, error.message);
                continue;
            }
        }
        window.send(IPC_CHANNELS.ON.PLAYLIST_IMPORT_FINISHED);
    });


    ipcMain.on(IPC_CHANNELS.SEND.ADD_YOUTUBE_LINK, async (event, url) => {
        const window = event.sender;
        try {
            // 簡易的な URL バリデーション
            if (!url || (!url.includes('youtube.com') && !url.includes('youtu.be'))) return;

            const settings = settingsStore.load();
            if ((settings.youtubePlaybackMode || 'download') === 'download') {
                window.send(IPC_CHANNELS.ON.SHOW_LOADING, 'YouTube動画をダウンロード中...');
            }

            // Go 側で全て処理
            const newSong = await processYouTubeVideo(null, url);

            const addedSongs = addSongsToLibraryAndSave([newSong]);
            if (addedSongs.length > 0) {
                window.send(IPC_CHANNELS.ON.YOUTUBE_LINK_PROCESSED, addedSongs[0]);
            }
        } catch (error) {
            console.error('YouTube処理エラー:', error.message);
            window.send(IPC_CHANNELS.ON.SHOW_ERROR, `YouTube楽曲の処理に失敗しました: ${error.message}`);
        } finally {
            window.send(IPC_CHANNELS.ON.HIDE_LOADING);
        }
    });

}


module.exports = { registerYouTubeHandlers };