// uxmusic/src/main/mtp/mtp-manager.js

let mtpDevice = null;
let mainWindow = null; // レンダラープロセスに通知するためのウィンドウインスタンス

console.log('[MTP-LOG] mtp-manager.js がロードされました。');

/**
 * メインウィンドウのインスタンスを設定
 * @param {BrowserWindow} win
 */
function setMainWindow(win) {
  mainWindow = win;
  if (win) {
    console.log('[MTP-LOG] メインウィンドウが mtp-manager に設定されました。');
  } else {
    console.warn('[MTP-LOG] メインウィンドウの設定解除（または失敗）');
  }
}

/**
 * MTPデバイスインスタンスを設定 (非同期処理)
 * @param {Kalam | null} deviceInstance
 */
async function setDevice(deviceInstance) {
  
  // デバイス切断処理
  if (deviceInstance === null) {
    console.log('[MTP-LOG] setDevice が呼び出されました (デバイス切断)。');
    mtpDevice = null;
    if (mainWindow && !mainWindow.isDestroyed()) {
      // --- ▼▼▼ 修正 ▼▼▼ ---
      console.log('[MTP-LOG] レンダラープロセスへ "mtp-device-disconnected" を送信します。');
      if (mainWindow.webContents && !mainWindow.webContents.isDestroyed()) { mainWindow.webContents.send('mtp-device-disconnected'); }
      // --- ▲▲▲ 修正 ▲▲▲ ---
    }
    return;
  }

  // デバイス接続処理
  mtpDevice = deviceInstance;
  console.log('[MTP-LOG] setDevice が呼び出されました (デバイス接続)。初期化を開始します...');

  try {
    const initResult = await mtpDevice.initialize();
    if (initResult.error) {
      throw new Error(`MTP Init Error: ${initResult.error}`);
    }
    console.log('[MTP-LOG] MTP Initialized:', initResult.data);

    // デバイス情報を取得
    const deviceInfoResult = await mtpDevice.fetchDeviceInfo();
    if (deviceInfoResult.error) {
      throw new Error(`MTP Device Info Error: ${deviceInfoResult.error}`);
    }
    const deviceInfo = deviceInfoResult.data;
    console.log('[MTP-LOG] MTP Device Info:', deviceInfo);

    // ストレージ情報を取得
    const storageInfoResult = await mtpDevice.listStorages();
    if (storageInfoResult.error) {
      console.warn('MTP Storage Info Error:', storageInfoResult.error);
    }
    const storageInfo = storageInfoResult.data || null;
    console.log('[MTP-LOG] MTP Storage Info:', storageInfo);

    // --- ▼▼▼ ★★★ ここからが修正箇所です ★★★ ▼▼▼ ---

    // 1. UIに渡すストレージ情報を構築 (ipc.js の期待する形式)
    let storagesForUI = [];
    if (storageInfo && storageInfo.length > 0) {
      storagesForUI = storageInfo.map(storage => ({
        id: storage.Sid, // ★★★ 転送に必要なストレージID ★★★
        free: storage.Info.FreeSpaceInBytes,
        total: storage.Info.MaxCapability,
        description: storage.Info.StorageDescription
      }));
      console.log('[MTP-LOG] UI用のストレージ情報を構築しました:', storagesForUI);
    } else {
      console.warn('[MTP-LOG] UI用のストレージ情報を構築できませんでした。');
    }

    // 2. UIに渡すデバイス情報オブジェクトを構築 (ipc.js の期待する形式)
    const payload = {
      device: {
        name: deviceInfo.usbDeviceInfo.Product || deviceInfo.mtpDeviceInfo.Model || 'MTP Device',
        mtpDeviceInfo: deviceInfo.mtpDeviceInfo,
        usbDeviceInfo: deviceInfo.usbDeviceInfo
      },
      storages: storagesForUI // 上で構築した配列
    };

    // --- ▲▲▲ ★★★ ここまでが修正箇所です ★★★ ▲▲▲ ---
    

    // ウィンドウが存在する場合のみ通知
    if (mainWindow && !mainWindow.isDestroyed()) {
      // --- ▼▼▼ 修正 ▼▼▼ ---
      console.log('[MTP-LOG] レンダラープロセスへ "mtp-device-connected" (接続完了) を送信します。', payload);
      if (mainWindow.webContents && !mainWindow.webContents.isDestroyed()) { mainWindow.webContents.send('mtp-device-connected', payload); }
      // --- ▲▲▲ 修正 ▲▲▲ ---
    } else {
      console.warn('[MTP-LOG] デバイス初期化完了。しかし mainWindow が未設定のため通知できません。');
    }

  } catch (err) {
    console.error('[MTP-LOG] MTPデバイスの処理中にエラー:', err);
    mtpDevice = null; // エラーが発生したらデバイスをクリア
    if (mainWindow && !mainWindow.isDestroyed()) {
      // --- ▼▼▼ 修正 ▼▼▼ ---
      // エラーが発生したことも通知（切断扱い）
      if (mainWindow.webContents && !mainWindow.webContents.isDestroyed()) { mainWindow.webContents.send('mtp-device-disconnected'); }
      // --- ▲▲▲ 修正 ▲▲▲ ---
    }
  }
}

/**
 * MTPデバイスインスタンスを取得
 * @returns {Kalam | null}
 */
function getDevice() {
  return mtpDevice;
}

module.exports = {
  setMainWindow,
  setDevice,
  getDevice,
};