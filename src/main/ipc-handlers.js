const { ipcMain, dialog, Menu, shell, BrowserWindow } = require('electron');
const DataStore = require('./data-store');
const { scanPaths, parseFiles, sanitize, analyzeLoudness } = require('./file-scanner');
const ytdl = require('@distube/ytdl-core');
const streamManager = require('./stream-manager');
const path = require('path');
const fs = require('fs');
const playlistManager = require('./playlist-manager');
const ytpl = require('ytpl');

const playCountsStore = new DataStore('playcounts.json');
const settingsStore = new DataStore('settings.json');
const libraryStore = new DataStore('library.json');
const loudnessStore = new DataStore('loudness.json');

function findHubUrl(description) {
    if (typeof description !== 'string') return null;
    const hubUrlRegex = /(https?:\/\/(?:www\.)?(?:linkco\.re|fanlink\.to|fanlink\.tv|lnk\.to)\/[\w\-\/.\?=&#]+)/;
    const match = description.match(hubUrlRegex);
    return match ? match[0] : null;
}

function registerIpcHandlers() {

    const sendToAllWindows = (channel, ...args) => {
        BrowserWindow.getAllWindows().forEach(win => {
            if (win && !win.isDestroyed()) {
                win.webContents.send(channel, ...args);
            }
        });
    };

    ipcMain.on('request-initial-library', (event) => {
        const songs = libraryStore.load() || [];
        if (event.sender && !event.sender.isDestroyed()) {
            event.sender.send('load-library', songs);
        }
    });

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
    
    const upgradeAndCleanup = (sourceURL) => {
        const library = libraryStore.load() || [];
        const existingSong = library.find(s => s.sourceURL === sourceURL);
        if (existingSong && existingSong.path.toLowerCase().endsWith('.m4a')) {
            if (fs.existsSync(existingSong.path)) {
                fs.unlinkSync(existingSong.path);
            }
            const updatedLibrary = library.filter(s => s.path !== existingSong.path);
            libraryStore.save(updatedLibrary);
            const allPlaylists = playlistManager.getAllPlaylists();
            allPlaylists.forEach(playlistName => {
                playlistManager.removeSongFromPlaylist(playlistName, existingSong.path);
            });
        }
    };

    ipcMain.handle('scan-paths', async (event, paths) => {
        const libraryPath = settingsStore.load().libraryPath;
        if (!libraryPath) {
            console.error('Library path is not set.');
            return [];
        }
        const sourceFiles = await scanPaths(paths);
        const songsWithMetadata = await parseFiles(sourceFiles);
        const newSongObjects = [];
        const loudnessData = loudnessStore.load();

        for (const song of songsWithMetadata) {
            const primaryArtist = song.albumartist || song.artist || 'Unknown Artist';
            const artistDir = sanitize(primaryArtist);
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destDir = path.join(libraryPath, artistDir, albumDir);
            if (!fs.existsSync(destDir)) {
                fs.mkdirSync(destDir, { recursive: true });
            }
            const originalFileName = path.basename(song.path);
            const safeFileName = sanitize(originalFileName);
            const destPath = path.join(destDir, safeFileName);

            if (!fs.existsSync(destPath)) {
                try {
                    fs.copyFileSync(song.path, destPath);
                    const result = await analyzeLoudness(destPath);
                    sendToAllWindows('loudness-analysis-result', result);
                    if (result.success) {
                        loudnessData[destPath] = result.loudness;
                    }
                } catch (error) {
                    console.error(`Failed to copy ${originalFileName}:`, error);
                    continue;
                }
            }
            song.path = destPath;
            newSongObjects.push(song);
        }
        
        loudnessStore.save(loudnessData);
        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        return addedSongs;
    });

    ipcMain.on('request-loudness-analysis', async (event, songPath) => {
        const loudnessData = loudnessStore.load();
        if (loudnessData[songPath]) {
            return;
        }
        const result = await analyzeLoudness(songPath);
        sendToAllWindows('loudness-analysis-result', result);
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

    ipcMain.on('show-playlist-song-context-menu', (event, { playlistName, song }) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window) return;
        const menu = Menu.buildFromTemplate([
            {
                label: 'このプレイリストから削除',
                click: async () => {
                    const result = playlistManager.removeSongFromPlaylist(playlistName, song.path);
                    if (result.success && !window.isDestroyed()) {
                        event.sender.send('force-reload-playlist', playlistName);
                    }
                }
            },
        ]);
        menu.popup({ window });
    });

    // ★★★ ここからが修正箇所です (import-youtube-playlist ハンドラ全体を修正) ★★★
    ipcMain.on('import-youtube-playlist', async (event, playlistUrl) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        try {
            if (!ytpl.validateID(playlistUrl)) {
                if (window && !window.isDestroyed()) event.sender.send('show-error', '無効なYouTubeプレイリストのURLです。');
                return;
            }
            const playlist = await ytpl(playlistUrl, { limit: Infinity });
            const total = playlist.items.length;
            const playlistTitle = sanitize(playlist.title);
            
            // プレイリストを作成し、UIを即時更新
            const createResult = playlistManager.createPlaylist(playlistTitle);
            if (createResult.success) {
                const playlistsWithArtwork = getPlaylistsWithArtwork();
                sendToAllWindows('playlists-updated', playlistsWithArtwork);
            }

            for (let i = 0; i < total; i++) {
                const item = playlist.items[i];
                if (window && !window.isDestroyed()) {
                    event.sender.send('playlist-import-progress', {
                        current: i + 1,
                        total: total,
                        title: item.title
                    });
                }
                const videoInfo = await ytdl.getInfo(item.url);
                const hubUrl = findHubUrl(videoInfo.videoDetails.description);
                const settings = settingsStore.load();
                const mode = settings.youtubePlaybackMode || 'download';
                
                if (mode === 'download' && (settings.youtubeDownloadQuality || 'full') === 'full') {
                     upgradeAndCleanup(item.url);
                }
                
                let newSong;
                if (mode === 'download') {
                    const qualitySetting = settings.youtubeDownloadQuality || 'full';
                    let format;
                    let fileExtension;
                    if (qualitySetting === 'audio_only') {
                        format = ytdl.chooseFormat(videoInfo.formats, { quality: 'highestaudio', filter: 'audioonly' });
                        fileExtension = '.m4a';
                    } else {
                        format = ytdl.chooseFormat(videoInfo.formats, { quality: 'highest', filter: f => f.hasVideo && f.hasAudio });
                        fileExtension = '.mp4';
                    }
                    const libraryPath = settings.libraryPath;
                    const artistDir = sanitize(item.author.name || 'YouTube');
                    const destDir = path.join(libraryPath, artistDir);
                    if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
                    const safeFileName = sanitize(item.title) + fileExtension;
                    const destPath = path.join(destDir, safeFileName);
                    const videoStream = ytdl(item.url, { format: format });
                    await new Promise((resolve, reject) => {
                        videoStream.pipe(fs.createWriteStream(destPath)).on('finish', resolve).on('error', reject);
                    });
                    const stats = fs.statSync(destPath);
                    newSong = {
                        path: destPath,
                        title: item.title,
                        artist: item.author.name,
                        album: item.author.name,
                        artwork: item.bestThumbnail.url,
                        duration: item.durationSec,
                        fileSize: stats.size,
                        type: 'local',
                        sourceURL: item.url,
                        hubUrl: hubUrl
                    };
                } else {
                    newSong = {
                        path: item.url,
                        title: item.title,
                        artist: item.author.name,
                        album: 'YouTube',
                        artwork: item.bestThumbnail.url,
                        duration: item.durationSec,
                        type: 'youtube',
                        hubUrl: hubUrl
                    };
                }
                
                // ライブラリへの追加処理
                const addedSongs = addSongsToLibraryAndSave([newSong]);
                
                // ライブラリに新規追加された曲はUIに通知
                if (addedSongs.length > 0) {
                    if (window && !window.isDestroyed()) event.sender.send('youtube-link-processed', addedSongs[0]);
                }
                
                // ★バグ修正: 新規・既存問わず、必ずプレイリストに追加する
                playlistManager.addSongToPlaylist(playlistTitle, newSong);
            }
        } catch (error) {
            console.error('Playlist import error:', error);
            if (window && !window.isDestroyed()) event.sender.send('show-error', 'プレイリストのインポートに失敗しました。');
        } finally {
            if (window && !window.isDestroyed()) event.sender.send('playlist-import-finished');
            // ★バグ修正: インポート完了後にもう一度プレイリスト一覧を更新してアートワークを反映
            const playlistsWithArtwork = getPlaylistsWithArtwork();
            sendToAllWindows('playlists-updated', playlistsWithArtwork);
        }
    });
    // ★★★ ここまでが修正箇所です ★★★

    ipcMain.on('add-youtube-link', async (event, url) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        const settings = settingsStore.load();
        const mode = settings.youtubePlaybackMode || 'download';
        try {
            if (!ytdl.validateURL(url)) return;
            const info = await ytdl.getInfo(url);
            const details = info.videoDetails;
            const hubUrl = findHubUrl(details.description);
            if (mode === 'download' && (settings.youtubeDownloadQuality || 'full') === 'full') {
                upgradeAndCleanup(url);
            }
            let newSong;
            if (mode === 'download') {
                if (window && !window.isDestroyed()) event.sender.send('show-loading', 'YouTube動画をダウンロード中...');
                const qualitySetting = settings.youtubeDownloadQuality || 'full';
                let format;
                let fileExtension;
                if (qualitySetting === 'audio_only') {
                    format = ytdl.chooseFormat(info.formats, { quality: 'highestaudio', filter: 'audioonly' });
                    fileExtension = '.m4a';
                } else {
                    format = ytdl.chooseFormat(info.formats, { quality: 'highest', filter: f => f.hasVideo && f.hasAudio });
                    fileExtension = '.mp4';
                }
                const libraryPath = settingsStore.load().libraryPath;
                const artistDir = sanitize(details.author.name || 'YouTube');
                const destDir = path.join(libraryPath, artistDir);
                if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
                const safeFileName = sanitize(details.title) + fileExtension;
                const destPath = path.join(destDir, safeFileName);
                const videoStream = ytdl(url, { format: format });
                await new Promise((resolve, reject) => {
                    const fileStream = fs.createWriteStream(destPath);
                    videoStream.pipe(fileStream);
                    fileStream.on('finish', resolve);
                    fileStream.on('error', reject);
                });
                const stats = fs.statSync(destPath);
                newSong = {
                    path: destPath,
                    title: details.title,
                    artist: details.author.name,
                    album: details.author.name,
                    artwork: details.thumbnails[0].url,
                    duration: Number(details.lengthSeconds),
                    fileSize: stats.size,
                    type: 'local',
                    sourceURL: url,
                    hubUrl: hubUrl
                };
                if (window && !window.isDestroyed()) event.sender.send('hide-loading');
            } else {
                newSong = {
                    path: url,
                    title: details.title,
                    artist: details.author.name,
                    album: 'YouTube',
                    artwork: details.thumbnails[0].url,
                    duration: Number(details.lengthSeconds),
                    type: 'youtube',
                    hubUrl: hubUrl
                };
            }
            const addedSongs = addSongsToLibraryAndSave([newSong]);
            if (addedSongs.length > 0 && window && !window.isDestroyed()) {
                event.sender.send('youtube-link-processed', addedSongs[0]);
            }
        } catch (error) {
            console.error('YouTube処理エラー:', error);
            if (window && !window.isDestroyed()) {
                event.sender.send('hide-loading');
                event.sender.send('show-error', 'YouTube楽曲の処理に失敗しました。');
            }
        }
    });

    ipcMain.on('open-external-link', (event, url) => {
        if (url && (url.startsWith('http://') || url.startsWith('https://'))) {
            shell.openExternal(url);
        }
    });

    ipcMain.on('request-initial-play-counts', (event) => {
        if (event.sender && !event.sender.isDestroyed()) event.sender.send('play-counts-updated', playCountsStore.load());
    });
    ipcMain.on('song-finished', (event, songPath) => {
        const counts = playCountsStore.load();
        counts[songPath] = (counts[songPath] || 0) + 1;
        playCountsStore.save(counts);
        if (event.sender && !event.sender.isDestroyed()) event.sender.send('play-counts-updated', counts);
    });
    ipcMain.on('request-initial-settings', (event) => {
        if (event.sender && !event.sender.isDestroyed()) event.sender.send('settings-loaded', settingsStore.load());
    });
    ipcMain.on('save-audio-output-id', (event, deviceId) => {
        const settings = settingsStore.load();
        settings.audioOutputId = deviceId;
        settingsStore.save(settings);
    });
    ipcMain.on('set-library-path', async (event) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        const result = await dialog.showOpenDialog(window, {
            properties: ['openDirectory']
        });
        if (!result.canceled && result.filePaths.length > 0) {
            const newPath = result.filePaths[0];
            const settings = settingsStore.load();
            settings.libraryPath = newPath;
            settingsStore.save(settings);
        }
    });
    ipcMain.handle('get-all-playlists', () => {
        return playlistManager.getAllPlaylists();
    });
    
    function getPlaylistsWithArtwork() {
        const playlistNames = playlistManager.getAllPlaylists();
        const mainLibrary = libraryStore.load() || [];
        const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));
        return playlistNames.map(name => {
            const songPaths = playlistManager.getPlaylistSongs(name);
            const artworks = songPaths
                .map(path => libraryMap.get(path))
                .filter(song => song && song.artwork)
                .slice(0, 4)
                .map(song => song.artwork);
            return { name, artworks };
        });
    }

    ipcMain.handle('create-playlist', (event, name) => {
        const result = playlistManager.createPlaylist(name);
        if (result.success) {
            const playlistsWithArtwork = getPlaylistsWithArtwork();
            sendToAllWindows('playlists-updated', playlistsWithArtwork);
        }
        return result;
    });

    ipcMain.handle('delete-playlist', (event, name) => {
        const result = playlistManager.deletePlaylist(name);
        if (result.success) {
            const playlistsWithArtwork = getPlaylistsWithArtwork();
            sendToAllWindows('playlists-updated', playlistsWithArtwork);
        }
        return result;
    });

    ipcMain.handle('update-playlist-song-order', (event, { playlistName, newOrder }) => {
        return playlistManager.updateSongOrderInPlaylist(playlistName, newOrder);
    });

    ipcMain.on('show-song-context-menu-in-library', (event, song) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window) return;
        const playlists = playlistManager.getAllPlaylists();
        const addToPlaylistSubmenu = playlists.map(name => ({
            label: name,
            click: () => playlistManager.addSongToPlaylist(name, song)
        }));

        const template = [
            {
                label: 'プレイリストに追加',
                submenu: addToPlaylistSubmenu.length > 0 ? addToPlaylistSubmenu : [{ label: '（追加可能なプレイリスト無し）', enabled: false }]
            },
            { type: 'separator' },
            {
                label: 'ライブラリから削除...',
                click: async () => {
                    const dialogResult = await dialog.showMessageBox(window, {
                        type: 'warning',
                        buttons: ['キャンセル', '削除'],
                        defaultId: 0,
                        title: '曲の削除の確認',
                        message: `「${song.title}」をライブラリから完全に削除しますか？`,
                        detail: 'この操作は元に戻せません。ファイルもディスクから削除されます。'
                    });

                    if (dialogResult.response !== 1) {
                        return;
                    }

                    try {
                        if (fs.existsSync(song.path)) {
                            fs.unlinkSync(song.path);
                        }
                        const library = libraryStore.load() || [];
                        const updatedLibrary = library.filter(s => s.path !== song.path);
                        libraryStore.save(updatedLibrary);
                        const allPlaylists = playlistManager.getAllPlaylists();
                        allPlaylists.forEach(playlistName => {
                            playlistManager.removeSongFromPlaylist(playlistName, song.path);
                        });
                        sendToAllWindows('force-reload-library');
                    } catch (error) {
                        console.error('楽曲の削除中にエラーが発生しました:', error);
                        dialog.showErrorBox('削除エラー', '曲の削除中にエラーが発生しました。');
                    }
                }
            }
        ];

        const menu = Menu.buildFromTemplate(template);
        menu.popup({ window });
    });

    ipcMain.on('save-settings', (event, settings) => {
        const currentSettings = settingsStore.load();
        const newSettings = { ...currentSettings, ...settings };
        settingsStore.save(newSettings);
    });
    ipcMain.handle('get-playlist-songs', async (event, playlistName) => {
        const songPaths = playlistManager.getPlaylistSongs(playlistName);
        if (!songPaths || songPaths.length === 0) {
            return [];
        }
        const mainLibrary = libraryStore.load() || [];
        const libraryMap = new Map(mainLibrary.map(song => [song.path, song]));
        const songs = songPaths
            .map(path => libraryMap.get(path))
            .filter(song => song);
        return songs;
    });
    ipcMain.on('request-playlists-with-artwork', (event) => {
        const playlistsWithArtwork = getPlaylistsWithArtwork();
        if (event.sender && !event.sender.isDestroyed()) {
             event.sender.send('playlists-updated', playlistsWithArtwork);
        }
    });
    ipcMain.handle('get-settings', () => {
        return settingsStore.load();
    });
}

module.exports = { registerIpcHandlers };