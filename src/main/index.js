const { app, BrowserWindow } = require('electron');
const path = require('path');
const { registerIpcHandlers } = require('./ipc-handlers'); // ★★★ initializeIpcHandlersから変更
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

  // initializeIpcHandlers(mainWindow); // ★★★ この行を削除 ★★★

  return mainWindow;
}

app.whenReady().then(() => {
  initializeLibrary();
  
  // ★★★ グローバルハンドラを一度だけ登録 ★★★
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