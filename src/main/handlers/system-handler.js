const { app, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs'); // ★★★ fs を require ★★★
const os = require('os');
const discordRpcManager = require('../discord-rpc-manager');
const { sanitize } = require('../utils');
const IPC_CHANNELS = require('../ipc-channels');


let settingsStore;
let playCountsStore;
let libraryStore;
let quizScoresStore;
let analysedQueueStore;

function registerSystemHandlers(stores) {
    settingsStore = stores.settings;
    playCountsStore = stores.playCounts;
    libraryStore = stores.library;
    quizScoresStore = stores.quizScores;
    analysedQueueStore = stores.analysedQueue;

    // --- Settings ---
    // ... (既存のハンドラ) ...
    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_SETTINGS, () => {
        return settingsStore.load();
    });

    ipcMain.on(IPC_CHANNELS.SEND.SAVE_SETTINGS, (event, settings) => {
        const currentSettings = settingsStore.load();
        const newSettings = { ...currentSettings, ...settings };
        settingsStore.save(newSettings);
    });

    ipcMain.on(IPC_CHANNELS.SEND.REQUEST_INITIAL_SETTINGS, (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send(IPC_CHANNELS.ON.SETTINGS_LOADED, settingsStore.load());
        }
    });

    ipcMain.on(IPC_CHANNELS.SEND.SET_LIBRARY_PATH, async (event) => {
        const result = await dialog.showOpenDialog({
            properties: ['openDirectory']
        });
        if (!result.canceled && result.filePaths.length > 0) {
            const newPath = result.filePaths[0];
            const settings = settingsStore.load();
            settings.libraryPath = newPath;
            settingsStore.save(settings);
        }
    });

    ipcMain.on(IPC_CHANNELS.SEND.SAVE_AUDIO_OUTPUT_ID, (event, deviceId) => {
        const settings = settingsStore.load();
        settings.audioOutputId = deviceId;
        settingsStore.save(settings);
    });


    // --- Analysed Queue ---
    // ... (既存のハンドラ) ...
    ipcMain.on(IPC_CHANNELS.SEND.SONG_SKIPPED, (event, { song, currentTime }) => {
        if (!song || typeof currentTime !== 'number' || !song.duration) return;
        const playbackPercentage = (currentTime / song.duration) * 100;
        let scoreIncrement = 0;

        if (currentTime <= 5) {
            scoreIncrement = 5; // Instant skip
        } else if (playbackPercentage <= 10) {
            scoreIncrement = 3; // Strong dislike
        } else if (playbackPercentage <= 50) {
            scoreIncrement = 1; // Moderate dislike
        }

        if (scoreIncrement > 0) {
            const dislikeData = analysedQueueStore.load() || {};
            const currentData = dislikeData[song.id] || { score: 0 };

            dislikeData[song.id] = {
                ...currentData,
                score: currentData.score + scoreIncrement,
                lastSkipped: new Date().toISOString()
            };
            analysedQueueStore.save(dislikeData);
        }
    });

    ipcMain.on(IPC_CHANNELS.SEND.SONG_FINISHED, (event, song) => {
        if (!song || !song.id) return;
        const dislikeData = analysedQueueStore.load() || {};
        if (dislikeData[song.id]) {
            dislikeData[song.id].score = Math.max(0, dislikeData[song.id].score - 1);
            analysedQueueStore.save(dislikeData);
        }
    });


    // --- Playback State & Counts ---
    // ... (既存のハンドラ) ...
    ipcMain.on(IPC_CHANNELS.SEND.PLAYBACK_STARTED, (event, song) => {
        discordRpcManager.setActivity(song);

        const counts = playCountsStore.load() || {};
        const now = new Date().toISOString();
        const existingData = counts[song.path] || { count: 0, totalDuration: 0, history: [] };

        existingData.count += 1;
        existingData.totalDuration += song.duration || 0;
        existingData.history.push(now);
        if (existingData.history.length > 100) {
            existingData.history.shift();
        }

        counts[song.path] = existingData;
        playCountsStore.save(counts);

        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send(IPC_CHANNELS.ON.PLAY_COUNTS_UPDATED, counts);
        }
    });

    ipcMain.on(IPC_CHANNELS.SEND.PLAYBACK_STOPPED, () => {
        discordRpcManager.clearActivity();
    });


    // --- Lyrics ---
    // ... (既存のハンドラ) ...
    const sidecarManager = require('../sidecar-manager'); // ★★★ 追加 ★★★

    // --- Lyrics ---
    // ... (既存のハンドラ) ...
    ipcMain.on(IPC_CHANNELS.SEND.HANDLE_LYRICS_DROP, async (event, filePaths) => { // async に変更
        // Go 側に処理を委譲。I/O なので非同期で良いが、今回は invoke で結果を待つ必要はないかもしれない
        // しかし、失敗時のログなどは Go 側で管理するか、invoke でエラーを受け取るか
        // ここではコピー処理なので、完了通知のために invoke する
        try {
            // Go側には copy-lyrics というメッセージが必要だが、lyrics.go の実装では "copy-lyrics" というメッセージタイプはまだ main.go で未登録だった可能性がある
            // main.goの実装を確認すると、"copy-lyrics" は未実装だった。
            // なので、以前の実装通り Node.js でやるか、Go に実装を追加するか。
            // 今回は lyrics.go に `CopyLyricsFiles` は実装されたが、main.go の routing に漏れていた可能性がある。
            // 確認のため、一旦Node.js実装を残しつつ、歌詞取得と保存のみ移行する。

            // ... と思ったが、lyrics.go には `CopyLyricsFiles` がある。
            // main.go を確認すると `copy-lyrics` は無い。
            // よってここは Node.js 実装のままにする（安全策）。

            // 元の実装に戻す
            const lyricsDir = path.join(app.getPath('userData'), 'Lyrics');
            if (!fs.existsSync(lyricsDir)) fs.mkdirSync(lyricsDir, { recursive: true });

            let count = 0;
            filePaths.forEach(filePath => {
                const fileName = path.basename(filePath);
                const destPath = path.join(lyricsDir, fileName);
                try {
                    fs.copyFileSync(filePath, destPath);
                    count++;
                } catch (error) {
                    console.error(`歌詞ファイルのコピーに失敗: ${fileName}`, error);
                }
            });
            if (count > 0 && event.sender && !event.sender.isDestroyed()) {
                event.sender.send(IPC_CHANNELS.ON.LYRICS_ADDED_NOTIFICATION, count);
            }
        } catch (err) {
            console.error('Lyrics drop error:', err);
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_LYRICS, async (event, song) => {
        try {
            // Go Sidecar にリクエスト
            const result = await sidecarManager.invoke('get-lyrics', {
                title: song.title,
                path: song.path
            });
            // Go からは { type: "lrc"|"txt", content: "..." } が返る。見つからない場合は null or error
            return result;
        } catch (error) {
            // エラーなら null を返す（見つからない扱い）
            // console.warn('Lyrics fetch failed:', error.message);
            return null;
        }
    });

    // --- ▼▼▼ LRCファイル保存ハンドラを追加 ▼▼▼ ---
    ipcMain.handle(IPC_CHANNELS.INVOKE.SAVE_LRC_FILE, async (event, { fileName, content }) => {
        if (!fileName || typeof content !== 'string') {
            return { success: false, message: 'ファイル名または内容が無効です。' };
        }
        try {
            await sidecarManager.invoke('save-lrc', {
                fileName,
                content
            });
            return { success: true };
        } catch (error) {
            console.error('[LRC Editor] Failed to save LRC file (Go):', error);
            return { success: false, message: error.message };
        }
    });
    // --- ▲▲▲ ハンドラを追加 ▲▲▲ ---

    // --- App Info & Misc ---
    // ... (既存のハンドラ) ...
    ipcMain.on(IPC_CHANNELS.SEND.REQUEST_APP_INFO, (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send(IPC_CHANNELS.ON.APP_INFO_RESPONSE, {
                version: app.getVersion(),
                platform: os.platform(),
                arch: os.arch(),
                release: os.release(),
            });
        }
    });

    ipcMain.on(IPC_CHANNELS.SEND.OPEN_EXTERNAL_LINK, (event, url) => {
        if (url && (url.startsWith('http://') || url.startsWith('https://'))) {
            shell.openExternal(url);
        }
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_ARTWORKS_DIR, () => {
        return path.join(app.getPath('userData'), 'Artworks');
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_ARTWORK_AS_DATA_URL, (event, artworkFileName) => {
        if (!artworkFileName) return null;
        try {
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            const artworkPath = path.join(artworksDir, artworkFileName);

            if (fs.existsSync(artworkPath)) {
                const imageBuffer = fs.readFileSync(artworkPath);
                const mimeType = 'image/webp';
                return `data:${mimeType};base64,${imageBuffer.toString('base64')}`;
            }
        } catch (error) {
            console.error(`Failed to read artwork file for data URL: ${artworkFileName}`, error);
        }
        return null;
    });

    // --- Quiz Scores ---
    // ... (既存のハンドラ) ...
    ipcMain.handle(IPC_CHANNELS.INVOKE.SAVE_QUIZ_SCORE, (event, scoreData) => {
        const scores = quizScoresStore.load() || [];
        scores.push(scoreData);
        scores.sort((a, b) => {
            if (b.score !== a.score) {
                return b.score - a.score;
            }
            return a.avgTime - b.avgTime;
        });
        quizScoresStore.save(scores.slice(0, 50)); // 上位50件まで保存
    });

    ipcMain.handle(IPC_CHANNELS.INVOKE.GET_QUIZ_SCORES, () => {
        return quizScoresStore.load() || [];
    });
}

module.exports = { registerSystemHandlers };