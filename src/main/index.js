const { app, BrowserWindow, protocol } = require('electron');
const path = require('path');
const fs = require('fs');
const { performance } = require('perf_hooks');
const { connectToDiscord } = require('./discord-rpc-manager');

// --- ▼▼▼ ここからが修正箇所です ▼▼▼ ---
// '--dev' フラグがあるか確認
if (process.argv.includes('--dev')) {
  // 開発用のデータディレクトリを設定
  const devUserDataPath = path.join(app.getPath('userData'), '..', `${app.getName()}-dev`);
  app.setPath('userData', devUserDataPath);
  console.log(`[DEV MODE] userData path set to: ${devUserDataPath}`);
}
// --- ▲▲▲ ここまでが修正箇所です ▲▲▲

// --- ▼▼▼ MTP機能のために修正 (ステップ8) ▼▼▼ ---
const usbDetection = require('usb-detection');
const { Kalam } = require('./mtp/Kalam'); 
const mtpManager = require('./mtp/mtp-manager'); // mtpDevice の管理を mtpManager に移管
// let mtpDevice = null; // mtpManager を使うため、この行は削除
// --- ▲▲▲ MTP機能のために修正 (ステップ8) ▲▲▲ ---

const startTime = performance.now();
const logPerf = (message) => {
    // タイムスタンプ付きでパフォーマンスログを出力
    console.log(`[PERF][Main] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};

logPerf("Process starting...");
performance.mark('main-process-start');

// 'Main: Full App Startup'の開始時間を記録
console.time("Main: Full App Startup");

// オーディオプロセスのサンドボックスを無効化
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
      nodeIntegration: true,
      contextIsolation: false,
      devTools: true,
      webSecurity: true,
      // MTP機能のIPC通信のために preload スクリプトが必要になる可能性があります
      // preload: path.join(__dirname, 'preload.js'), 
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

  // マウスの「戻る」ボタンの処理
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
  
  const mainWindow = createWindow(); // mainWindow を取得
  connectToDiscord();

  logPerf("Requiring ipc-handlers...");
  const { registerIpcHandlers } = require('./ipc-handlers');
  logPerf("Registering IPC handlers...");
  registerIpcHandlers(); // この中で MTP 用の IPC ハンドラも登録（ステップ8）
  logPerf("IPC handlers registered.");
  performance.mark('ipc-handlers-registered');

  // --- ▼▼▼ MTP機能のために修正 (ステップ8) ▼▼▼ ---
  logPerf("Starting USB detection...");
  try {
    usbDetection.startMonitoring();

    // デバイス接続時の処理
    usbDetection.on('add', async (device) => {
      console.log('USB Device Added:', device);
      
      // if (device.vendorId !== 0x054C) return; 
      
      // mtpDevice -> mtpManager.getDevice() に変更
      if (!mtpManager.getDevice()) { 
        const mtpDeviceInstance = new Kalam(); // 変数名を変更
        mtpManager.setDevice(mtpDeviceInstance); // mtpManager にインスタンスをセット

        try {
          const initResult = await mtpDeviceInstance.initialize(); // 変数名変更
          if (initResult.error) {
            console.error('MTP Init Error:', initResult.error);
            mtpManager.setDevice(null); // mtpManager のインスタンスをクリア
            return;
          }
          console.log('MTP Initialized:', initResult.data);

          // デバイス情報を取得
          const deviceInfo = await mtpDeviceInstance.fetchDeviceInfo(); // 変数名変更
          console.log('MTP Device Info:', deviceInfo.data);
          
          // ストレージ情報を取得
          const storageInfo = await mtpDeviceInstance.listStorages(); // 変数名変更
          if (storageInfo.error) {
            console.error('MTP Storage Info Error:', storageInfo.error);
          } else {
            console.log('MTP Storage Info:', storageInfo.data);
          }

          // レンダラープロセスに通知 (ストレージ情報も渡す)
          if (mainWindow) {
            mainWindow.webContents.send('mtp-device-connected', {
                device: deviceInfo.data,
                storages: storageInfo.data || null // エラーの場合は null を送る
            });
          }

        } catch (err) {
          console.error('MTP Kalam Error:', err);
          mtpManager.setDevice(null); // mtpManager のインスタンスをクリア
        }
      }
    });

    // デバイス切断時の処理
    usbDetection.on('remove', async (device) => {
      console.log('USB Device Removed:', device);
      
      const mtpDeviceInstance = mtpManager.getDevice(); // mtpManager からインスタンス取得
      
      if (mtpDeviceInstance) { // mtpDevice -> mtpDeviceInstance
        await mtpDeviceInstance.dispose(); // 変数名変更
        mtpManager.setDevice(null); // mtpManager のインスタンスをクリア
        console.log('MTP Disposed.');
        
        // レンダラープロセスに通知
        if (mainWindow) {
          mainWindow.webContents.send('mtp-device-disconnected');
        }
      }
    });

  } catch (err) {
    console.error('Failed to start USB detection:', err);
  }
  // --- ▲▲▲ MTP機能のために修正 (ステップ8) ▲▲▲ ---

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', function () {
  // --- ▼▼▼ MTP機能のために修正 (ステップ8) ▼▼▼ ---
  const mtpDeviceInstance = mtpManager.getDevice(); // mtpManager からインスタンス取得
  if (mtpDeviceInstance) { // mtpDevice -> mtpDeviceInstance
    mtpDeviceInstance.dispose().catch(err => console.error('MTP dispose error:', err)); // 変数名変更
  }
  try {
    usbDetection.stopMonitoring();
  } catch (err) {
    console.error('Failed to stop USB monitoring:', err);
  }
  // --- ▲▲▲ MTP機能のために修正 (ステップ8) ▲▲▲ ---

  if (process.platform !== 'darwin') app.quit();
});