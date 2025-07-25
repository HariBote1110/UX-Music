const { app, BrowserWindow } = require('electron');
const path = require('path');
const { registerIpcHandlers } = require('./ipc-handlers');
const fs = require('fs');
const DataStore = require('./data-store');
const { initialize: initializeLogForwarder } = require('./log-forwarder'); // ★★★ 追加 ★★★

// ★★★ アプリ起動の早い段階でログ転送を初期化 ★★★
initializeLogForwarder();

function createWindow() {
  const mainWindow = new BrowserWindow({
    width: 1280,
    height: 720,
    minWidth: 940,
    minHeight: 560,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      // ★★★ ビルド後もDevToolsを開けるようにする設定 ★★★
      devTools: !app.isPackaged, 
    },
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#282828',
      symbolColor: '#ffffff'
    }
  });

  // 開発モード、またはデバッグフラグがある場合はDevToolsを開く
  if (!app.isPackaged || process.argv.includes('--debug')) {
      mainWindow.webContents.openDevTools();
  }

  mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

  mainWindow.on('app-command', (e, cmd) => {
    if (cmd === 'browser-backward') {
      mainWindow.webContents.send('navigate-back');
    }
  });

  return mainWindow;
}

app.whenReady().then(() => {
  registerIpcHandlers(); 
  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});