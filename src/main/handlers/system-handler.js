const { app, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');

let settingsStore;
let playCountsStore;

function registerSystemHandlers(stores) {
    settingsStore = stores.settings;
    playCountsStore = stores.playCounts;

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

    // --- Play Counts ---
    ipcMain.on('request-initial-play-counts', (event) => {
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('play-counts-updated', playCountsStore.load());
        }
    });

    ipcMain.on('song-finished', (event, { songPath, duration }) => {
        const counts = playCountsStore.load() || {};
        const existingData = counts[songPath] || { count: 0, totalDuration: 0 };
        existingData.count += 1;
        existingData.totalDuration += duration || 0;
        counts[songPath] = existingData;
        playCountsStore.save(counts);
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('play-counts-updated', counts);
        }
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
    
    // ▼▼▼ 変更点 ▼▼▼
    ipcMain.handle('get-artworks-dir', () => {
        // Artworksフォルダのベースパスを返すように変更
        return path.join(app.getPath('userData'), 'Artworks');
    });
    // ▲▲▲ 変更点ここまで ▲▲▲

    ipcMain.handle('get-artwork-as-data-url', (event, artworkFileName) => {
        if (!artworkFileName) return null;
        try {
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            const artworkPath = path.join(artworksDir, artworkFileName);

            if (fs.existsSync(artworkPath)) {
                const imageBuffer = fs.readFileSync(artworkPath);
                // WebP形式に対応
                const mimeType = 'image/webp'; 
                return `data:${mimeType};base64,${imageBuffer.toString('base64')}`;
            }
        } catch (error) {
            console.error(`Failed to read artwork file for data URL: ${artworkFileName}`, error);
        }
        return null;
    });
}

module.exports = { registerSystemHandlers };