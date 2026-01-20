const { spawn } = require('child_process');
const path = require('path');
const { app } = require('electron');
const EventEmitter = require('events');

class SidecarManager extends EventEmitter {
    constructor() {
        super();
        this.sidecarProcess = null;
        this.pendingRequests = new Map();
        this.requestIdCounter = 0;
        this.isReady = false; // Sidecarの初期化(init)完了フラグ
        this.requestQueue = []; // 初期化待ちのリクエストキュー
    }

    startSidecar() {
        return new Promise((resolve, reject) => {
            // 開発環境では 'go run' を使用し、ビルドの手間を省く
            // 本番ビルド時はバイナリのパスを指定するように書き換える必要がある
            const goDir = path.join(__dirname, '../go');

            console.log('[SidecarManager] Starting Go sidecar...');
            this.sidecarProcess = spawn('go', ['run', '.'], {
                cwd: goDir,
                stdio: ['pipe', 'pipe', 'pipe'] // stdin, stdout, stderr
            });

            this.sidecarProcess.on('error', (err) => {
                console.error('[SidecarManager] Failed to start sidecar:', err);
                reject(err);
            });

            // Goからのメッセージ (stdout)
            this.sidecarProcess.stdout.on('data', (data) => {
                const lines = data.toString().split('\n');
                lines.forEach(line => {
                    if (!line.trim()) return;
                    try {
                        const message = JSON.parse(line);

                        // リクエストIDがあればPromiseを解決
                        if (message.id && this.pendingRequests.has(message.id)) {
                            const { resolve, reject } = this.pendingRequests.get(message.id);
                            this.pendingRequests.delete(message.id);

                            if (message.error) {
                                reject(new Error(message.error));
                            } else {
                                resolve(message.payload);
                            }
                            return;
                        }

                        // メッセージ全体を 'message' イベントとして発火
                        this.emit('message', message);

                        // typeごとのイベントも発火
                        if (message.type) {
                            this.emit(message.type, message.payload);
                        }
                    } catch (e) {
                        // JSONパースエラーは無視 (ログ出力も抑制)
                    }
                });
            });

            // Goのログ (stderr)
            this.sidecarProcess.stderr.on('data', (data) => {
                const text = data.toString().trim();
                if (text) console.error(`[Sidecar Log] ${text}`);
            });

            this.sidecarProcess.on('close', (code) => {
                console.log(`[SidecarManager] Process exited with code ${code}`);
                this.sidecarProcess = null;
                this.isReady = false;
                // 全てのペンディングリクエストをreject
                for (const { reject } of this.pendingRequests.values()) {
                    reject(new Error(`Sidecar process exited with code ${code}`));
                }
                this.pendingRequests.clear();
                // キューもクリア
                this.requestQueue.forEach(({ reject }) => reject(new Error('Sidecar process exited')));
                this.requestQueue = [];
            });

            // プロセスが安定して立ち上がったとみなしてresolve
            setTimeout(async () => {
                if (this.sidecarProcess && !this.sidecarProcess.killed) {
                    console.log('[SidecarManager] Sidecar started successfully.');

                    // ▼▼▼ 初期化メッセージを送信 (待機する) ▼▼▼
                    const ffmpegPath = require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked');
                    const ffprobePath = require('ffprobe-static').path.replace('app.asar', 'app.asar.unpacked');

                    try {
                        // init メッセージは直接送る（まだ isReady = false なので invoke を使うとデッドロックする恐れがあるが、
                        // 下記の invoke 修正で type==='init' はスルーするようにする）
                        await this.invoke('init', {
                            userDataPath: app.getPath('userData'),
                            ffmpegPath,
                            ffprobePath
                        });
                        console.log('[SidecarManager] Sidecar initialized.');

                        // ★★★ 初期化完了。キューを消化 ★★★
                        this.isReady = true;
                        this.processQueue();

                    } catch (initErr) {
                        console.error('[SidecarManager] Failed to initialize sidecar:', initErr);
                        // 初期化失敗でもプロセスは生きているので進めるか、rejectするか。
                        // パス設定がないと動かない機能が多いのでログを出して進める（後で再送などのリカバリは今は考えない）
                    }
                    // ▲▲▲ 送信終了 ▲▲▲

                    resolve();
                } else {
                    reject(new Error('Sidecar process died immediately.'));
                }
            }, 1000);
        });
    }

    sendToSidecar(type, payload = {}) {
        if (!this.sidecarProcess) {
            console.warn('[SidecarManager] Sidecar is not running.');
            return;
        }
        // Fire-and-forget でも初期化待ちをするべきだが、簡易的な通知なら無視してよい場合もある。
        // ここでは安全のため、もし初期化前なら送らない（もしくはキューする）のが正しいが、
        // sendToSidecar は void 返却なので待てない。
        // なので、invoke を使うように推奨していく。ここは既存互換のためそのまま。
        const message = JSON.stringify({ type, payload }) + '\n';
        this.sidecarProcess.stdin.write(message);
    }

    /**
     * Go Sidecar にリクエストを送り、レスポンスを待機する
     * @param {string} type 
     * @param {object} payload 
     * @param {number} timeout timeout in ms
     * @returns {Promise<any>}
     */
    invoke(type, payload = {}, timeout = 30000) {
        return new Promise((resolve, reject) => {
            // 'init' は特別扱いして通す
            if (!this.isReady && type !== 'init') {
                // まだ準備ができていないのでキューに積む
                this.requestQueue.push({ type, payload, timeout, resolve, reject });
                return;
            }

            this._executeRequest(type, payload, timeout, resolve, reject);
        });
    }

    processQueue() {
        while (this.requestQueue.length > 0) {
            const { type, payload, timeout, resolve, reject } = this.requestQueue.shift();
            this._executeRequest(type, payload, timeout, resolve, reject);
        }
    }

    _executeRequest(type, payload, timeout, resolve, reject) {
        if (!this.sidecarProcess) {
            return reject(new Error('Sidecar is not running.'));
        }

        const id = (this.requestIdCounter++).toString();
        this.pendingRequests.set(id, { resolve, reject });

        const message = JSON.stringify({ id, type, payload }) + '\n';
        try {
            this.sidecarProcess.stdin.write(message);
        } catch (err) {
            this.pendingRequests.delete(id);
            reject(err);
            return;
        }

        // タイムアウト設定
        setTimeout(() => {
            if (this.pendingRequests.has(id)) {
                this.pendingRequests.delete(id);
                reject(new Error(`Request ${type} timed out after ${timeout}ms`));
            }
        }, timeout);
    }

    stopSidecar() {
        if (this.sidecarProcess) {
            console.log('[SidecarManager] Killing sidecar process...');
            this.sidecarProcess.kill();
            this.sidecarProcess = null;
        }
    }
}

// シングルトンインスタンスを作成
const sidecarManager = new SidecarManager();

// アプリ終了時に確実に殺す
app.on('before-quit', () => sidecarManager.stopSidecar());

module.exports = sidecarManager;
