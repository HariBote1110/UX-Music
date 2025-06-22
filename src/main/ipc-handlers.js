const { ipcMain, dialog, Menu } = require('electron'); // ★★★ Menuをインポート ★★★
const DataStore = require('./data-store');
const { scanPaths, parseFiles, sanitize } = require('./file-scanner');
const ytdl = require('@distube/ytdl-core');
const streamManager = require('./stream-manager');
const path = require('path');
const fs = require('fs');
const playlistManager = require('./playlist-manager');

const playCountsStore = new DataStore('playcounts.json');
const settingsStore = new DataStore('settings.json');
const libraryStore = new DataStore('library.json');

function initializeIpcHandlers(mainWindow) {
    // ★★★ 新規: 曲をライブラリに追加して保存する共通関数 ★★★
    function addSongsToLibraryAndSave(newSongs) {
        const library = libraryStore.load();
        const existingPaths = new Set(library.map(s => s.path));
        const uniqueNewSongs = newSongs.filter(s => !existingPaths.has(s.path));
        if (uniqueNewSongs.length > 0) {
            const updatedLibrary = library.concat(uniqueNewSongs);
            libraryStore.save(updatedLibrary);
        }
        return uniqueNewSongs;
    }
    ipcMain.handle('scan-paths', async (event, paths) => {
        const libraryPath = settingsStore.load().libraryPath;
        if (!libraryPath) {
            console.error('Library path is not set.');
            return [];
        }
        const sourceFiles = await scanPaths(paths);
        const songsWithMetadata = await parseFiles(sourceFiles);
        const newSongObjects = [];
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
                } catch (error) {
                    console.error(`Failed to copy ${originalFileName}:`, error);
                    continue;
                }
            }
            song.path = destPath;
            newSongObjects.push(song);
        }
                // ★★★ 修正: スキャンした曲をlibrary.jsonに保存し、追加された曲のみ返す ★★★
        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        return addedSongs;
        return newSongObjects;
    });

ipcMain.on('add-youtube-link', async (event, url) => {
    // 最初に設定を読み込み、モードを決定（デフォルトは'download'）
    const settings = settingsStore.load();
    const mode = settings.youtubePlaybackMode || 'download';

    try {
        if (!ytdl.validateURL(url)) return;
        const info = await ytdl.getInfo(url);
        const details = info.videoDetails;

        let newSong;

        if (mode === 'download') {
            // --- ダウンロードモード ---
            mainWindow.webContents.send('show-loading', 'YouTube動画をダウンロード中...');
            
            // ★ ダウンロード品質の設定を読み込む ★
            const qualitySetting = settings.youtubeDownloadQuality || 'full';

            let format;
            let fileExtension;
            // ★ 品質に応じてフォーマットと拡張子を決定 ★
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

            newSong = {
                path: destPath, // ローカルファイルのパス
                title: details.title,
                artist: details.author.name,
                album: details.author.name,
                artwork: details.thumbnails[0].url,
                duration: Number(details.lengthSeconds),
                type: 'local', // タイプは'local'
                sourceURL: url  // 元のYouTubeのURLをsourceURLとして追加
            };
            mainWindow.webContents.send('hide-loading');

        } else {
            // --- ストリーミングモード ---
            newSong = {
                path: url, // YouTubeのURL
                title: details.title,
                artist: details.author.name,
                album: 'YouTube',
                artwork: details.thumbnails[0].url,
                duration: Number(details.lengthSeconds),
                type: 'youtube' // タイプは'youtube'
            };
        }

        const addedSongs = addSongsToLibraryAndSave([newSong]);
        if (addedSongs.length > 0) {
            mainWindow.webContents.send('youtube-link-processed', addedSongs[0]);
        }

    } catch (error) {
        console.error('YouTube処理エラー:', error);
        mainWindow.webContents.send('hide-loading');
        mainWindow.webContents.send('show-error', 'YouTube楽曲の処理に失敗しました。');
    }
});
    ipcMain.on('request-initial-play-counts', (event) => {
        event.sender.send('play-counts-updated', playCountsStore.load());
    });

    ipcMain.on('song-finished', (event, songPath) => {
        const counts = playCountsStore.load();
        counts[songPath] = (counts[songPath] || 0) + 1;
        playCountsStore.save(counts);
        event.sender.send('play-counts-updated', counts);
    });

    ipcMain.on('request-initial-settings', (event) => {
        event.sender.send('settings-loaded', settingsStore.load());
    });

    ipcMain.on('save-audio-output-id', (event, deviceId) => {
        const settings = settingsStore.load();
        settings.audioOutputId = deviceId;
        settingsStore.save(settings);
    });

    ipcMain.on('set-library-path', async (event) => {
        const result = await dialog.showOpenDialog(mainWindow, {
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

    ipcMain.handle('create-playlist', (event, name) => {
        const result = playlistManager.createPlaylist(name);
        if (result.success) {
            const allPlaylists = playlistManager.getAllPlaylists();
            mainWindow.webContents.send('playlists-updated', allPlaylists);
        }
        return result;
    });

    // --- 曲の右クリックメニューを表示 ---
    ipcMain.on('show-song-context-menu', (event, song) => {
        const playlists = playlistManager.getAllPlaylists();
        const addToPlaylistSubmenu = playlists.map(name => {
            return {
                label: name,
                click: () => {
                    playlistManager.addSongToPlaylist(name, song);
                }
            };
        });

        const template = [
            {
                label: 'プレイリストに追加',
                submenu: addToPlaylistSubmenu.length > 0 ? addToPlaylistSubmenu : [{ label: '（追加可能なプレイリスト無し）', enabled: false }]
            },
        ];

        const menu = Menu.buildFromTemplate(template);
        menu.popup({ window: mainWindow });
    });
        // ★★★ 以下を追加 ★★★
    ipcMain.on('save-settings', (event, settings) => {
        const currentSettings = settingsStore.load();
        const newSettings = { ...currentSettings, ...settings };
        settingsStore.save(newSettings);
    });

    ipcMain.handle('get-playlist-songs', async (event, playlistName) => {
        // 1. プレイリストファイルから曲のパスリストを取得
        const songPaths = playlistManager.getPlaylistSongs(playlistName);
        if (!songPaths || songPaths.length === 0) {
            return [];
        }
        
        // 2. パスリストから完全な曲情報を解析して返す
        const songs = await parseFiles(songPaths);
        return songs;
    });
        // ★★★ 以下を追加 ★★★
    ipcMain.on('save-settings', (event, settings) => {
        const currentSettings = settingsStore.load();
        const newSettings = { ...currentSettings, ...settings };
        settingsStore.save(newSettings);
    });

    ipcMain.handle('get-settings', () => {
        return settingsStore.load();
    });
}

module.exports = { initializeIpcHandlers };