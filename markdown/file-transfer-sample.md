# MTPファイル転送（アップロード）のサンプルコード

これは、ローカルの絶対パスにあるファイルを、接続中の Android 端末（Walkman など）の指定フォルダに転送する処理の抽象化されたサンプルです。

`ipc-handlers.js` など、メインプロセス側で実行されることを想定しています。

```javascript
// mainプロセス側 (ipc-handlers.js や関連モジュール)

// 1. 必要なモジュールをインポート
// mtp-manager は、index.js で接続時に作成された Kalam インスタンスを保持しています
const mtpManager = require('./mtp/mtp-manager');
// (プログレスバー表示のために BrowserWindow が必要な場合があります)
const { BrowserWindow } = require('electron');

/**
 * MTPデバイス（Android端末）へファイルを転送する非同期関数
 *
 * @param {number} storageId - 転送先のストレージID (例: 65537)
 * @param {string[]} localFilePaths - 転送したいローカルファイルの絶対パスの配列
 * @param {string} destinationPath - 端末側の保存先フォルダパス (例: '/Music/')
 */
async function transferFilesToAndroid(storageId, localFilePaths, destinationPath) {
  console.log(`[転送開始] ${localFilePaths.length}個のファイルを ${destinationPath} へ転送します。`);

  // 2. mtpManager から現在接続中のデバイスインスタンスを取得
  const device = mtpManager.getDevice();

  // 3. デバイスが接続されているか確認
  if (!device) {
    console.error('転送エラー: MTPデバイスが接続されていません。');
    return { error: 'MTP device not connected.' };
  }

  // (オプション) メインウィンドウを取得してプログレスバーを操作する
  const mainWindow = BrowserWindow.getAllWindows()[0];

  try {
    // 4. Kalam インスタンスの transferFiles メソッドを呼び出す
    const result = await device.transferFiles({
      direction: 'upload', // 転送方向: アップロード
      storageId: storageId, // ストレージID
      sources: localFilePaths, // ローカルファイルの絶対パスの配列
      destination: destinationPath, // 端末側の保存先パス
      preprocessFiles: true, // 転送前処理を有効にする

      // --- コールバック関数 (オプション) ---

      // 転送中にエラーが発生した時
      onError: (err) => {
        console.error('[転送エラー]', err);
      },

      // 転送ファイルの前処理（サイズ計算など）が始まった時
      onPreprocess: (fileInfo) => {
        console.log(`[転送準備中] ${fileInfo.name}`);
      },

      // 転送が進捗した時
      onProgress: (progressInfo) => {
        const percent = Math.round(progressInfo.bytesTransferred * 100 / progressInfo.totalBytes);
        console.log(`[転送中] ${progressInfo.fullPath} (${percent}%)`);
        
        // (例: メインウィンドウのプログレスバーを更新)
        if (mainWindow) {
          mainWindow.setProgressBar(progressInfo.bytesTransferred / progressInfo.totalBytes);
        }
      },

      // すべての転送が完了した時
      onCompleted: () => {
        console.log('[転送完了] すべてのファイルが転送されました。');
        
        // (例: プログレスバーをリセット)
        if (mainWindow) {
          mainWindow.setProgressBar(-1); // -1でプログレスバー非表示
        }
      },
    });

    // 5. transferFiles の最終結果をハンドリング
    if (mainWindow) {
      mainWindow.setProgressBar(-1); // 完了またはエラー時にプログレスバーを非表示
    }

    if (result.error) {
      console.error('[転送最終結果] エラー:', result.error);
    } else {
      console.log('[転送最終結果] 成功');
    }

    return result; // 呼び出し元（UI側など）に結果を返す

  } catch (err) {
    // 6. メソッド呼び出し自体の例外処理
    console.error('[転送機能エラー] 予期せぬエラーが発生しました:', err);
    if (mainWindow) {
      mainWindow.setProgressBar(-1);
    }
    return { error: err.message };
  }
}

// --- 実行例 ---
// (UIからのIPCイベントなどで、以下の関数が呼び出されるイメージ)

(async () => {
  // 1. (仮) listStorages() で事前に取得したストレージID
  // 例: const storageInfo = await device.listStorages();
  //     const TARGET_STORAGE_ID = storageInfo.data[0].Sid;
  const TARGET_STORAGE_ID = 65537; 

  // 2. (仮) UIで選択されたローカルファイルの絶対パス
  const filesToTransfer = [
    '/Users/yuki/Music/アーティストA/アルバムX/01 曲A.mp3',
    '/Users/yuki/Music/アーティストB/アルバムY/05 曲B.flac'
  ];

  // 3. (仮) Walkman の保存先
  const TARGET_DESTINATION = '/Music/';

  // 転送を実行
  const transferResult = await transferFilesToAndroid(
    TARGET_STORAGE_ID,
    filesToTransfer,
    TARGET_DESTINATION
  );

  if (transferResult.error) {
    console.log('--- 最終結果: 転送に失敗しました ---');
  } else {
    console.log('--- 最終結果: 転送に成功しました ---');
  }
})();

```

### サンプルの解説

1.  **モジュールのインポート**:

      * `mtpManager` をインポートし、`index.js` で初期化・保持されている `Kalam` インスタンスにアクセスできるようにします。

2.  **デバイスインスタンスの取得**:

      * `mtpManager.getDevice()` で `Kalam` インスタンスを取得します。
      * インスタンスが `null` の場合は、デバイスが接続されていない（または初期化に失敗した）ことを意味するため、エラーを返します。

3.  **`device.transferFiles()` の呼び出し**:

      * これがファイル転送の核となるメソッドです。
      * `direction: 'upload'`: `Kalam.js` に対してアップロード（ローカル→端末）であることを伝えます。
      * `storageId`: `listStorages()` で取得した、端末のストレージ（例: 内部ストレージ）を一意に示す ID です。
      * `sources`: 転送したいローカルファイルの**絶対パス**を**配列**で渡します。
      * `destination`: 端末側の保存先**フォルダ**のパスです。`'/Music/'` のように、通常は末尾に `/` が必要です。

4.  **コールバック関数**:

      * `transferFiles` は `Promise` を返しますが、転送中の進捗はコールバック関数（`onProgress` など）を通じてリアルタイムに通知されます。
      * `onProgress` で受け取った進捗情報（転送済みバイト数/総バイト数）を使い、UI のプログレスバーを更新できます。

5.  **結果のハンドリング**:

      * `await device.transferFiles(...)` が完了すると、`result` オブジェクトが返されます。これには、転送全体が成功したか、あるいは最終段階でエラーが発生したかの情報が含まれます。
      * 転送が完了またはエラーになったら、プログレスバーをリセットします。