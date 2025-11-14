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
      console.log('[MTP-LOG] レンダラープロセスへ "mtp-device-status" (切断) を送信します。');
      mainWindow.webContents.send('mtp-device-status', null);
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
    // (注: ログによると初回は失敗し、2回目で成功しているため、リトライは Kalam 側で自動処理されているか、
    // OSがストレージをマウントするのに時間がかかっているようです。このロジックはひとまず変更しません。)
    const storageInfoResult = await mtpDevice.listStorages();
    if (storageInfoResult.error) {
      console.warn('MTP Storage Info Error:', storageInfoResult.error);
    }
    const storageInfo = storageInfoResult.data || null;
    console.log('[MTP-LOG] MTP Storage Info:', storageInfo);

    // --- ▼▼▼ ★★★ ここからが修正箇所です ★★★ ▼▼▼ ---

    // 1. UIに渡すストレージ情報を構築
    let storageDataForUI = null;
    if (storageInfo && storageInfo.length > 0 && storageInfo[0].Info) {
      // ログから判明した正しいプロパティから値を取得
      storageDataForUI = {
        free: storageInfo[0].Info.FreeSpaceInBytes,
        total: storageInfo[0].Info.MaxCapability
      };
      console.log('[MTP-LOG] UI用のストレージ情報を構築しました:', storageDataForUI);
    } else {
      console.warn('[MTP-LOG] UI用のストレージ情報を構築できませんでした。');
    }

    // 2. UIに渡すデバイス情報オブジェクトを構築
    const deviceDataForUI = {
      // ログから判明した正しいプロパティから名前を取得
      // (usbDeviceInfo.Product が 'WALKMAN', mtpDeviceInfo.Model が 'NW-A300Series')
      name: deviceInfo.usbDeviceInfo.Product || deviceInfo.mtpDeviceInfo.Model || 'MTP Device',
      storage: storageDataForUI // 上で構築した単純なオブジェクト
    };

    // --- ▲▲▲ ★★★ ここまでが修正箇所です ★★★ ▲▲▲ ---
    

    // ウィンドウが存在する場合のみ通知
    if (mainWindow && !mainWindow.isDestroyed()) {
      console.log('[MTP-LOG] レンダラープロセスへ "mtp-device-status" (接続完了) を送信します。', deviceDataForUI);
      mainWindow.webContents.send('mtp-device-status', deviceDataForUI);
    } else {
      console.warn('[MTP-LOG] デバイス初期化完了。しかし mainWindow が未設定のため通知できません。');
    }

  } catch (err) {
    console.error('[MTP-LOG] MTPデバイスの処理中にエラー:', err);
    mtpDevice = null; // エラーが発生したらデバイスをクリア
    if (mainWindow && !mainWindow.isDestroyed()) {
      // エラーが発生したことも通知（切断扱い）
      mainWindow.webContents.send('mtp-device-status', null);
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