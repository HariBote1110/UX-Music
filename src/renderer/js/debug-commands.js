const { ipcRenderer } = require('electron');
import { setVisualizerFpsLimit, toggleVisualizerEcoMode } from './player.js'; // ★ toggleVisualizerEcoMode をインポート

export function initDebugCommands() {
    const uxDebug = {
        resetLibrary: () => {
            const confirmation = confirm('本当にライブラリをリセットしますか？...');
            if (confirmation) {
                ipcRenderer.send('debug-reset-library');
            }
        },
        rollbackMigration: () => {
            const confirmation = confirm('本当にマイグレーションをロールバックしますか？...');
            if (confirmation) {
                ipcRenderer.send('debug-rollback-migration');
            }
        },
        setVisualizerFps: (fps) => {
            if (typeof fps !== 'number') {
                console.error('[DEBUG] Please provide a number...');
                return;
            }
            setVisualizerFpsLimit(fps);
        },

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        /**
         * ビジュアライザーのエコモード（表示中のみ描画）を切り替えます。
         * @param {boolean} enabled - trueで有効、falseで無効
         */
        toggleVisualizerEcoMode: (enabled) => {
            if (typeof enabled !== 'boolean') {
                console.error('[DEBUG] Please provide a boolean value (true or false).');
                return;
            }
            toggleVisualizerEcoMode(enabled);
        },
        // ▲▲▲ ここまでが修正箇所です ▲▲▲

        help: () => {
            console.log(
                '%cUX Music デバッグコマンド一覧:\n' +
                '%c' +
                '  uxDebug.resetLibrary()                - 全てのライブラリデータを削除します。\n' +
                '  uxDebug.rollbackMigration()         - データ構造のマイグレーションを元に戻します。\n' +
                '  uxDebug.setVisualizerFps(fps)       - ビジュアライザーのFPS上限を設定します。(0で制限解除)\n' +
                '  uxDebug.toggleVisualizerEcoMode(bool) - ビジュアライザーのエコモードを切り替えます。(trueで有効(デフォルト), falseで無効)\n' +
                '  uxDebug.help()                          - このヘルプメッセージを表示します。',
                'font-weight: bold; font-size: 1.2em; color: #1DB954;',
                'font-weight: normal; font-size: 1em; color: inherit;'
            );
        }
    };
    window.uxDebug = uxDebug;
    console.log('%c[DEBUG] デバッグインターフェイスが読み込まれました。コマンド一覧は `uxDebug.help()` を実行してください。', 'color: orange;');
}