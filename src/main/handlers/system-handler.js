const { app, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const discordRpcManager = require('../discord-rpc-manager');

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
    ipcMain.handle('get-settings', () => {
        return settingsStore.load();
    });

    ipcMain.on('save-settings', (event, settings) => {
        const currentSettings = settingsStore.load();
        const newSettings = { ...currentSettings, ...settings };
        settingsStore.save(newSettings);
    });

    ipcMain.on('request-initial-settings', (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('settings-loaded', settingsStore.load());
        }
    });

    ipcMain.on('set-library-path', async (event) => {
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
    
    ipcMain.on('save-audio-output-id', (event, deviceId) => {
        const settings = settingsStore.load();
        settings.audioOutputId = deviceId;
        settingsStore.save(settings);
    });

    // --- Analysed Queue ---
    ipcMain.on('song-skipped', (event, { song, currentTime }) => {
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

    ipcMain.on('song-finished', (event, song) => {
        if (!song || !song.id) return;
        const dislikeData = analysedQueueStore.load() || {};
        if (dislikeData[song.id]) {
            dislikeData[song.id].score = Math.max(0, dislikeData[song.id].score - 1);
            analysedQueueStore.save(dislikeData);
        }
    });

    // --- Playback State & Counts ---
    ipcMain.on('playback-started', (event, song) => {
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
            event.sender.send('play-counts-updated', counts);
        }
    });

    ipcMain.on('playback-stopped', () => {
        discordRpcManager.clearActivity();
    });

    // --- Lyrics ---
    ipcMain.on('handle-lyrics-drop', (event, filePaths) => {
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
            event.sender.send('lyrics-added-notification', count);
        }
    });
    
    ipcMain.handle('get-lyrics', (event, song) => {
        const lyricsDir = path.join(app.getPath('userData'), 'Lyrics');
        
        const findLyricsFile = (baseName) => {
            const sanitizedName = baseName.replace(/_/g, ' ');
            const lrcPath = path.join(lyricsDir, `${sanitizedName}.lrc`);
            if (fs.existsSync(lrcPath)) return { type: 'lrc', content: fs.readFileSync(lrcPath, 'utf-8') };
            
            const txtPath = path.join(lyricsDir, `${sanitizedName}.txt`);
            if (fs.existsSync(txtPath)) return { type: 'txt', content: fs.readFileSync(txtPath, 'utf-8') };
            
            return null;
        };
        
        const fileNameBase = path.basename(song.path, path.extname(song.path));
        let result = findLyricsFile(fileNameBase);
        if (result) return result;
        
        if (song.title && song.title !== fileNameBase) {
            result = findLyricsFile(song.title);
            if (result) return result;
        }
        
        return null;
    });

    // --- App Info & Misc ---
    ipcMain.on('request-app-info', (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('app-info-response', {
                version: app.getVersion(),
                platform: os.platform(),
                arch: os.arch(),
                release: os.release(),
            });
        }
    });

    ipcMain.on('open-external-link', (event, url) => {
        if (url && (url.startsWith('http://') || url.startsWith('https://'))) {
            shell.openExternal(url);
        }
    });
    
    ipcMain.handle('get-artworks-dir', () => {
        return path.join(app.getPath('userData'), 'Artworks');
    });

    ipcMain.handle('get-artwork-as-data-url', (event, artworkFileName) => {
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
    ipcMain.handle('save-quiz-score', (event, scoreData) => {
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
    
    ipcMain.handle('get-quiz-scores', () => {
        return quizScoresStore.load() || [];
    });
}

module.exports = { registerSystemHandlers };