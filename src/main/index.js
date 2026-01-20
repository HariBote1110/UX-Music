// src/main/index.js
const { app, BrowserWindow, protocol } = require('electron');
const path = require('path');
const fs = require('fs');
const { performance } = require('perf_hooks');
const { connectToDiscord } = require('./discord-rpc-manager');

// ▼▼▼ 追加: CDリッピングハンドラの読み込み ▼▼▼
const { registerCDRipHandlers } = require('./handlers/cd-rip-handler');
// ▲▲▲ 追加 ▲▲▲

// '--dev' フラグがあるか確認
if (process.argv.includes('--dev')) {
  // 開発用のデータディレクトリを設定
  const devUserDataPath = path.join(app.getPath('userData'), '..', `${app.getName()}-dev`);
  app.setPath('userData', devUserDataPath);
  console.log(`[DEV MODE] userData path set to: ${devUserDataPath}`);
}

const usbDetection = require('usb-detection');
const { Kalam } = require('./mtp/Kalam');
const mtpManager = require('./mtp/mtp-manager');

const startTime = performance.now();
const logPerf = (message) => {
  console.log(`[PERF][Main] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};

logPerf("Process starting...");
performance.mark('main-process-start');

console.time("Main: Full App Startup");
app.commandLine.appendSwitch('no-sandbox-and-zygote');

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
      sandbox: false,
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
      devTools: true,
      webSecurity: true,
    },
    titleBarStyle: 'hidden',
    backgroundColor: '#1c1c1e', // --bg-dark に合わせる
    titleBarOverlay: {
      color: '#1c1c1e',
      symbolColor: '#ffffff'
    }
  });
  logPerf("BrowserWindow instance created");
  performance.mark('browser-window-created');

  mainWindow.webContents.on('did-finish-load', () => {
    logPerf("'did-finish-load' event fired");
    performance.mark('did-finish-load');

    if (!app.isPackaged || process.argv.includes('--debug') || process.argv.includes('--dev')) {
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

  const mainWindow = createWindow();
  connectToDiscord();

  // mtp-manager がレンダラーと通信するために mainWindow を渡す
  mtpManager.setMainWindow(mainWindow);
  logPerf("Main window set for MTP manager.");

  logPerf("Requiring ipc-handlers...");
  // ▼▼▼ 修正: stores を受け取る ▼▼▼
  const { registerIpcHandlers, stores } = require('./ipc-handlers');
  // ▲▲▲ 修正 ▲▲▲

  logPerf("Registering IPC handlers...");
  registerIpcHandlers();

  // ▼▼▼ 追加: CD Rip Handler (macOS only) ▼▼▼
  if (process.platform === 'darwin') {
    // ここで stores を渡すことで設定のロードが可能になる
    registerCDRipHandlers(stores);
    logPerf("CD Rip handlers registered.");
  }
  // ▲▲▲ 追加 ▲▲▲

  logPerf("IPC handlers registered.");
  performance.mark('ipc-handlers-registered');

  // --- ▼▼▼ MTP機能の修正 (ロジックを mtp-manager に集約) ▼▼▼ ---
  logPerf("Starting USB detection...");
  try {
    usbDetection.startMonitoring();

    // デバイス接続時の処理 (簡略化)
    usbDetection.on('add', async (device) => {
      console.log('USB Device Added:', device);
      // if (device.vendorId !== 0x054C) return; 

      if (!mtpManager.getDevice()) {
        const mtpDeviceInstance = new Kalam();
        // mtpManager.setDevice が非同期で初期化と通知を行う
        mtpManager.setDevice(mtpDeviceInstance);
      }
    });

    // デバイス切断時の処理 (簡略化)
    usbDetection.on('remove', async (device) => {
      console.log('USB Device Removed:', device);

      const mtpDeviceInstance = mtpManager.getDevice();

      if (mtpDeviceInstance) {
        await mtpDeviceInstance.dispose();
        mtpManager.setDevice(null); // 切断を mtpManager に通知
        console.log('MTP Disposed.');
      }
    });

  } catch (err) {
    console.error('Failed to start USB detection:', err);
  }
  // --- ▲▲▲ MTP機能の修正 ▲▲▲ ---

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', function () {
  const mtpDeviceInstance = mtpManager.getDevice();
  if (mtpDeviceInstance) {
    mtpDeviceInstance.dispose().catch(err => console.error('MTP dispose error:', err));
  }
  try {
    usbDetection.stopMonitoring();
  } catch (err) {
    console.error('Failed to stop USB monitoring:', err);
  }

  if (process.platform !== 'darwin') app.quit();
});