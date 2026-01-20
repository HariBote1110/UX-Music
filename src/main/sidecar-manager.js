const { spawn } = require('child_process');
const path = require('path');
const { app } = require('electron');
const EventEmitter = require('events');

class SidecarManager extends EventEmitter {
    constructor() {
        super();
        this.sidecarProcess = null;
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
                        // 受信ログはうるさいのでデバッグ時のみ有効化推奨
                        // console.log('[SidecarManager] Received:', message);

                        // メッセージ全体を 'message' イベントとして発火
                        this.emit('message', message);

                        // typeごとのイベントも発火 (例: 'scan-library-success')
                        if (message.type) {
                            this.emit(message.type, message.payload);
                        }
                    } catch (e) {
                        console.log('[SidecarManager] Raw Output:', line);
                    }
                });
            });

            // Goのログ (stderr)
            this.sidecarProcess.stderr.on('data', (data) => {
                // 改行を取り除いてログ出力
                const text = data.toString().trim();
                if (text) console.error(`[Sidecar Log] ${text}`);
            });

            this.sidecarProcess.on('close', (code) => {
                console.log(`[SidecarManager] Process exited with code ${code}`);
                this.sidecarProcess = null;
            });

            // プロセスが安定して立ち上がったとみなしてresolve
            setTimeout(() => {
                if (this.sidecarProcess && !this.sidecarProcess.killed) {
                    console.log('[SidecarManager] Sidecar started successfully.');
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
        const message = JSON.stringify({ type, payload }) + '\n';
        this.sidecarProcess.stdin.write(message);
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
