/**
 * MTP Sidecar Worker
 * Go (Wails) から起動され、標準入出力で JSON-RPC 通信を行う。
 * Electron 依存を排除し、スタンドアロンで動作する。
 */

const readline = require('readline');
const path = require('path');
const koffi = require('koffi');

// --- 設定 (環境変数または引数で渡す) ---
const KALAM_LIB_PATH = process.env.KALAM_LIB_PATH ||
    path.join(__dirname, '..', '..', 'main', 'bin', 'macos', 'kalam.dylib');

// --- ユーティリティ ---
function log(...args) {
    console.error('[MTP-Sidecar]', ...args);
}

function sendResponse(id, type, payload, error = null) {
    const response = { id, type, payload };
    if (error) response.error = error;
    console.log(JSON.stringify(response));
}

function undefinedOrNull(value) {
    return value === undefined || value === null;
}

// --- Kalam クラス (Electron 依存排除版) ---
const on_cb_result_t = koffi.proto('void on_cb_result_t(char*)');

class Kalam {
    constructor(libPath) {
        this.lib = koffi.load(libPath);
        this.callbackType = on_cb_result_t;

        this.fnDictionary = Object.freeze({
            Initialize: 'void Initialize(on_cb_result_t* onDonePtr)',
            FetchDeviceInfo: 'void FetchDeviceInfo(on_cb_result_t* onDonePtr)',
            FetchStorages: 'void FetchStorages(on_cb_result_t* onDonePtr)',
            Walk: 'void Walk(char* walkInputJson, on_cb_result_t* onDonePtr)',
            DownloadFiles: 'void DownloadFiles(char* downloadFilesInputJson, on_cb_result_t* onPreprocessPtr, on_cb_result_t* onProgressPtr, on_cb_result_t* onDonePtr)',
            UploadFiles: 'void UploadFiles(char* uploadFilesInputJson, on_cb_result_t* onPreprocessPtr, on_cb_result_t* onProgressPtr, on_cb_result_t* onDonePtr)',
            DeleteFile: 'void DeleteFile(char* deleteFileInputJson, on_cb_result_t* onDonePtr)',
            MakeDirectory: 'void MakeDirectory(char* makeDirectoryInputJson, on_cb_result_t* onDonePtr)',
            Dispose: 'void Dispose(on_cb_result_t* onDonePtr)',
        });
    }

    _getData(value) {
        return {
            error: value?.error === '' ? null : value?.error,
            data: value?.data,
        };
    }

    _callSimple(fnName) {
        return new Promise((resolve) => {
            const rawPtr = koffi.register((result) => {
                resolve(this._getData(JSON.parse(result)));
            }, koffi.pointer(this.callbackType));

            const fn = this.lib.func(this.fnDictionary[fnName]);
            fn.async(rawPtr, (err) => {
                koffi.unregister(rawPtr);
                if (!undefinedOrNull(err)) {
                    resolve({ error: err.message || String(err), data: null });
                }
            });
        });
    }

    _callWithJson(fnName, args) {
        return new Promise((resolve) => {
            const rawPtr = koffi.register((result) => {
                resolve(this._getData(JSON.parse(result)));
            }, koffi.pointer(this.callbackType));

            const fn = this.lib.func(this.fnDictionary[fnName]);
            const json = JSON.stringify(args);

            fn.async(json, rawPtr, (err) => {
                koffi.unregister(rawPtr);
                if (!undefinedOrNull(err)) {
                    resolve({ error: err.message || String(err), data: null });
                }
            });
        });
    }

    async initialize() { return this._callSimple('Initialize'); }
    async fetchDeviceInfo() { return this._callSimple('FetchDeviceInfo'); }
    async listStorages() { return this._callSimple('FetchStorages'); }
    async dispose() { return this._callSimple('Dispose'); }

    async walk({ storageId, fullPath, skipHiddenFiles }) {
        return this._callWithJson('Walk', {
            storageId: parseInt(storageId, 10),
            fullPath,
            recursive: false,
            skipDisallowedFiles: false,
            skipHiddenFiles,
        });
    }

    async deleteFile({ storageId, files }) {
        return this._callWithJson('DeleteFile', {
            storageId: parseInt(storageId, 10),
            files,
        });
    }

    async makeDirectory({ storageId, fullPath }) {
        return this._callWithJson('MakeDirectory', {
            storageId: parseInt(storageId, 10),
            fullPath,
        });
    }

    async transferFiles({ direction, storageId, sources, destination, preprocessFiles, onPreprocess, onProgress }) {
        return new Promise((resolve) => {
            const onPreprocessPtr = koffi.register((result) => {
                const { data } = this._getData(JSON.parse(result));
                if (onPreprocess && data) onPreprocess(data);
            }, koffi.pointer(this.callbackType));

            const onProgressPtr = koffi.register((result) => {
                const { data } = this._getData(JSON.parse(result));
                if (onProgress && data) onProgress(data);
            }, koffi.pointer(this.callbackType));

            const onDonePtr = koffi.register((result) => {
                resolve(this._getData(JSON.parse(result)));
            }, koffi.pointer(this.callbackType));

            const fnName = direction === 'upload' ? 'UploadFiles' : 'DownloadFiles';
            const fn = this.lib.func(this.fnDictionary[fnName]);
            const args = {
                storageId: parseInt(storageId, 10),
                sources,
                destination,
                preprocessFiles,
            };

            fn.async(JSON.stringify(args), onPreprocessPtr, onProgressPtr, onDonePtr, (err) => {
                koffi.unregister(onPreprocessPtr);
                koffi.unregister(onProgressPtr);
                koffi.unregister(onDonePtr);
                if (!undefinedOrNull(err)) {
                    resolve({ error: err.message || String(err), data: null });
                }
            });
        });
    }
}

// --- メイン処理 ---
let kalam = null;

async function handleRequest(req) {
    const { id, type, payload } = req;

    try {
        switch (type) {
            case 'init':
                kalam = new Kalam(payload?.libPath || KALAM_LIB_PATH);
                const initResult = await kalam.initialize();
                if (initResult.error) {
                    sendResponse(id, 'init-error', null, initResult.error);
                } else {
                    sendResponse(id, 'init-success', initResult.data);
                }
                break;

            case 'device-info':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const info = await kalam.fetchDeviceInfo();
                sendResponse(id, 'device-info', info.data, info.error);
                break;

            case 'list-storages':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const storages = await kalam.listStorages();
                sendResponse(id, 'storages', storages.data, storages.error);
                break;

            case 'walk':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const walkResult = await kalam.walk(payload);
                sendResponse(id, 'walk-result', walkResult.data, walkResult.error);
                break;

            case 'upload':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const uploadResult = await kalam.transferFiles({
                    direction: 'upload',
                    ...payload,
                    onPreprocess: (data) => sendResponse(id, 'upload-preprocess', data),
                    onProgress: (data) => sendResponse(id, 'upload-progress', data),
                });
                sendResponse(id, 'upload-complete', uploadResult.data, uploadResult.error);
                break;

            case 'download':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const downloadResult = await kalam.transferFiles({
                    direction: 'download',
                    ...payload,
                    onPreprocess: (data) => sendResponse(id, 'download-preprocess', data),
                    onProgress: (data) => sendResponse(id, 'download-progress', data),
                });
                sendResponse(id, 'download-complete', downloadResult.data, downloadResult.error);
                break;

            case 'delete':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const deleteResult = await kalam.deleteFile(payload);
                sendResponse(id, 'delete-result', deleteResult.data, deleteResult.error);
                break;

            case 'mkdir':
                if (!kalam) return sendResponse(id, 'error', null, 'Not initialized');
                const mkdirResult = await kalam.makeDirectory(payload);
                sendResponse(id, 'mkdir-result', mkdirResult.data, mkdirResult.error);
                break;

            case 'dispose':
                if (kalam) {
                    await kalam.dispose();
                    kalam = null;
                }
                sendResponse(id, 'disposed', null);
                break;

            default:
                sendResponse(id, 'error', null, `Unknown command: ${type}`);
        }
    } catch (err) {
        log('Error handling request:', err);
        sendResponse(id, 'error', null, err.message || String(err));
    }
}

// --- 標準入力からの読み取りループ ---
const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false,
});

log('Started. Waiting for commands...');

rl.on('line', async (line) => {
    try {
        const req = JSON.parse(line);
        await handleRequest(req);
    } catch (err) {
        log('Invalid JSON input:', err.message);
        sendResponse('', 'parse-error', null, 'Invalid JSON');
    }
});

rl.on('close', () => {
    log('Stdin closed. Exiting.');
    if (kalam) kalam.dispose().catch(() => { });
    process.exit(0);
});
