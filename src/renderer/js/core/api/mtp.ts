// src/renderer/js/core/api/mtp.ts
/**
 * MTP 操作のための API ブリッジ
 * Electron 互換の invoke インターフェースを介して Wails バックエンドを呼び出す
 */

const electronAPI = (window as any).electronAPI;

/**
 * MTP デバイスを初期化
 */
export async function mtpInitialize() {
    return await electronAPI.invoke('mtp-initialize');
}

/**
 * デバイス情報を取得
 */
export async function mtpFetchDeviceInfo() {
    return await electronAPI.invoke('mtp-fetch-device-info');
}

/**
 * ディレクトリをブラウズ
 * @param {object} data { storageId, fullPath }
 */
export async function mtpBrowseDirectory(data: { storageId: number; fullPath: string }) {
    return await electronAPI.invoke('mtp-browse-directory', data);
}

/**
 * ファイルをアップロード
 */
export async function mtpUploadFiles(data: any) {
    return await electronAPI.invoke('mtp-upload-files', data);
}

/**
 * ファイルをダウンロード
 */
export async function mtpDownloadFiles(data: any) {
    return await electronAPI.invoke('mtp-download-files', data);
}

/**
 * ファイルを削除
 */
export async function mtpDeleteFiles(data: any) {
    return await electronAPI.invoke('mtp-delete-files', data);
}

/**
 * フォルダを作成
 */
export async function mtpMakeDirectory(data: any) {
    return await electronAPI.invoke('mtp-make-directory', data);
}

/**
 * ダウンロード先フォルダを選択
 */
export async function mtpSelectDownloadFolder() {
    return await electronAPI.invoke('mtp-select-download-folder');
}

/**
 * MTP 接続を終了
 */
export async function mtpDispose() {
    return await electronAPI.invoke('mtp-dispose');
}
