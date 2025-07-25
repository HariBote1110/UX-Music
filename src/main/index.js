const { app, BrowserWindow } = require('electron');
const path = require('path');
const { registerIpcHandlers } = require('./ipc-handlers');
const fs = require('fs');
const DataStore = require('./data-store');

function initializeLibrary() {
    // ★★★ この処理はipc-handlers内でapp.whenReady()後に実行されるため、ここでは不要 ★★★
    // const settingsStore = new DataStore('settings.json');
    // let settings = settingsStore.load();
    // if (!settings.libraryPath) {
    //     settings.libraryPath = path.join(app.getPath('music'), 'UX_Music');
    //     settingsStore.save(settings);
    // }
    // if (!fs.existsSync(settings.libraryPath)) {
    //     fs.mkdirSync(settings.libraryPath, { recursive: true });
    // }
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

  // ★★★ ここからが修正箇所です ★★★
  // マウスのサイドボタン（戻る）が押されたことを検知
  mainWindow.on('app-command', (e, cmd) => {
    if (cmd === 'browser-backward') {
      // レンダラープロセスに「戻る」ナビゲーションを指示
      mainWindow.webContents.send('navigate-back');
    }
  });
  // ★★★ ここまでが修正箇所です ★★★

  return mainWindow;
}

app.whenReady().then(() => {
  initializeLibrary();
  
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