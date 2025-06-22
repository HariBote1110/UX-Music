const { app, BrowserWindow } = require('electron');
const path = require('path');
const { initializeIpcHandlers } = require('./ipc-handlers');
//const http = require('http');
//const streamManager = require('./stream-manager');
const fs = require('fs');
const DataStore = require('./data-store');
const { scanPaths, parseFiles } = require('./file-scanner');
const playlistManager = require('./playlist-manager'); // ★★★ playlist-managerをインポート ★★★

/*
// --- ローカルストリーミングサーバー (変更なし) ---
const server = http.createServer(async (req, res) => {
    const streamUrl = streamManager.getUrl();
    if (!streamUrl) {
        res.writeHead(404, { 'Content-Type': 'text/plain' }).end('No stream URL set');
        return;
    }
    try {
        const ytdl = require('@distube/ytdl-core');
        const info = await ytdl.getInfo(streamUrl);
        const format = ytdl.chooseFormat(info.formats, { quality: 'highestaudio' });
        const contentLength = format.contentLength;
        const range = req.headers.range;
        if (range) {
            const parts = range.replace(/bytes=/, "").split("-");
            const start = parseInt(parts[0], 10);
            const end = parts[1] ? parseInt(parts[1], 10) : contentLength - 1;
            const chunksize = (end - start) + 1;
            const stream = ytdl(streamUrl, { filter: 'audioonly', highWaterMark: 1 << 25, range: { start, end } });
            res.writeHead(206, {
                'Content-Range': `bytes ${start}-${end}/${contentLength}`,
                'Accept-Ranges': 'bytes',
                'Content-Length': chunksize,
                'Content-Type': 'audio/mpeg',
            });
            stream.pipe(res);
            stream.on('error', (err) => { res.end(); });
        } else {
            res.writeHead(200, { 'Content-Length': contentLength, 'Content-Type': 'audio/mpeg', 'Accept-Ranges': 'bytes' });
            const stream = ytdl(streamUrl, { filter: 'audioonly', highWaterMark: 1 << 25 });
            stream.pipe(res);
            stream.on('error', (err) => { res.end(); });
        }
    } catch (error) {
        console.error('Failed to handle stream request:', error);
        res.writeHead(500).end('Server error');
    }
});
server.listen(3000, '127.0.0.1', () => {
    console.log('Local streaming server is running on http://127.0.0.1:3000');
});
*/
// --- ライブラリフォルダの初期設定 (変更なし) ---
function initializeLibrary() {
    const settingsStore = new DataStore('settings.json');
    let settings = settingsStore.load();
    if (!settings.libraryPath) {
        settings.libraryPath = path.join(app.getPath('music'), 'UX_Music');
        settingsStore.save(settings);
    }
    if (!fs.existsSync(settings.libraryPath)) {
        fs.mkdirSync(settings.libraryPath, { recursive: true });
    }
}

// ★★★ ここからが修正箇所 ★★★
function createWindow() {
  const mainWindow = new BrowserWindow({
    width: 1280,
    height: 720,
    minWidth: 940,
    minHeight: 560,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    },
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#282828',
      symbolColor: '#ffffff'
    }
  });

  mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

  // --- UIの読み込み完了後、ライブラリとプレイリストをスキャンして送信 ---
  mainWindow.webContents.on('did-finish-load', async () => {
    // ★★★ ここから全面的に修正 ★★★
    // 1. library.jsonから曲ライブラリを読み込む
    const libraryStore = new DataStore('library.json');
    const songs = libraryStore.load();
    mainWindow.webContents.send('load-library', songs);

    // 2. プレイリスト一覧の読み込み (ここは変更なし)
    const allPlaylists = playlistManager.getAllPlaylists();
    mainWindow.webContents.send('playlists-updated', allPlaylists);
    // ★★★ ここまで ★★★
  });

  return mainWindow; // ★ ウィンドウオブジェクトを返すようにする
}

app.whenReady().then(() => {
  initializeLibrary();
  const mainWindow = createWindow(); // ★ 作成したウィンドウを受け取る

  // ★ IPCハンドラは、ウィンドウ作成後に一度だけ初期化する
  initializeIpcHandlers(mainWindow);

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});
// ★★★ ここまでが修正箇所 ★★★