const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const { initializeIpcHandlers } = require('./ipc-handlers');
const fs = require('fs');
const DataStore = require('./data-store');

// ライブラリフォルダの初期設定
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

  // UIの読み込み完了後にライブラリとプレイリストをスキャンして送信
  mainWindow.webContents.on('did-finish-load', async () => {
    // ライブラリとプレイリスト情報を送信する処理は renderer.jsからの要求に応じて行うため、ここでは不要
  });

  return mainWindow;
}

app.whenReady().then(() => {
  initializeLibrary();
  const mainWindow = createWindow();

  // IPCハンドラは、ウィンドウ作成後に一度だけ初期化する
  initializeIpcHandlers(mainWindow);
  
  // レンダラーからのライブラリ要求に応答するハンドラ
  ipcMain.on('request-initial-library', (event) => {
      const libraryStore = new DataStore('library.json');
      const songs = libraryStore.load();
      event.sender.send('load-library', songs);
  });

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});