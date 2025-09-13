const { app, BrowserWindow, protocol } = require('electron');
const path = require('path');
const fs = require('fs');
const { performance } = require('perf_hooks');

const startTime = performance.now();
const logPerf = (message) => {
    // タイムスタンプ付きでパフォーマンスログを出力
    console.log(`[PERF][Main] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};

logPerf("Process starting...");
performance.mark('main-process-start');

// 'Main: Full App Startup'の開始時間を記録
console.time("Main: Full App Startup");

// ▼▼▼ ここからが修正箇所です ▼▼▼
// 起動スイッチを追加して、OSのメディア制御機能との衝突を回避
app.commandLine.appendSwitch('disable-features', 'HardwareMediaKeyHandling,MediaSessionService');
// オーディオプロセスのサンドボックスを無効化
app.commandLine.appendSwitch('no-sandbox-and-zygote');
// ▲▲▲ ここまでが修正箇所です ▲▲▲

logPerf("Requiring log-forwarder...");
const { initialize: initializeLogForwarder } = require('./log-forwarder');
logPerf("Initializing log-forwarder...");
initializeLogForwarder();
logPerf("Log-forwarder initialized.");

function createWindow() {
  logPerf("createWindow called");
  performance.mark('create-window-start');

  const mainWindow = new BrowserWindow({
    width: 1280,
    height: 720,
    minWidth: 940,
    minHeight: 560,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      devTools: true,
      webSecurity: true,
    },
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#282828',
      symbolColor: '#ffffff'
    }
  });
  logPerf("BrowserWindow instance created");
  performance.mark('browser-window-created');

  mainWindow.webContents.on('did-finish-load', () => {
    logPerf("'did-finish-load' event fired");
    performance.mark('did-finish-load');
    
    if (!app.isPackaged || process.argv.includes('--debug')) {
      mainWindow.webContents.openDevTools();
      logPerf("DevTools opened");
    }

    console.timeEnd("Main: Full App Startup");
    mainWindow.webContents.send('measure-performance');
  });

  logPerf("Starting to load file...");
  performance.mark('load-file-start');
  mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

  mainWindow.on('app-command', (e, cmd) => {
    if (cmd === 'browser-backward') {
      mainWindow.webContents.send('navigate-back');
    }
  });

  return mainWindow;
}

logPerf("Setting up app.whenReady()...");
app.whenReady().then(() => {
  logPerf("app.whenReady resolved");
  performance.mark('app-ready');

  protocol.registerFileProtocol('safe-artwork', (request, callback) => {
    try {
        const url = request.url.substr('safe-artwork://'.length);
        const artworksDir = path.join(app.getPath('userData'), 'Artworks');
        const requestedPath = path.normalize(path.join(artworksDir, url));

        if (!requestedPath.startsWith(artworksDir)) {
            console.error('[Security] Attempted to access path outside of Artworks directory:', requestedPath);
            return callback({ error: -6 });
        }

        callback({ path: requestedPath });
    } catch (error) {
        console.error('Failed to handle safe-artwork protocol request:', error);
        callback({ error: -2 });
    }
  });
  
  createWindow();

  logPerf("Requiring ipc-handlers...");
  const { registerIpcHandlers } = require('./ipc-handlers');
  logPerf("Registering IPC handlers...");
  registerIpcHandlers(); 
  logPerf("IPC handlers registered.");
  performance.mark('ipc-handlers-registered');

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});