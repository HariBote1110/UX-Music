const { ipcRenderer } = require('electron');

/**
 * デバッグ用コマンドインターフェイスを初期化し、windowオブジェクトに登録する
 */
export function initDebugCommands() {
    const uxDebug = {
        /**
         * ライブラリ、再生回数、ラウドネス情報、アートワークをすべて削除します。
         */
        resetLibrary: () => {
            const confirmation = confirm(
                '本当にライブラリをリセットしますか？\n' +
                'すべての曲、再生回数、ラウドネス情報、アートワークが削除されます。\n' +
                'この操作は元に戻せません。'
            );

            if (confirmation) {
                console.log('[DEBUG] ライブラリのリセットコマンドを送信します...');
                ipcRenderer.send('debug-reset-library');
            } else {
                console.log('[DEBUG] ライブラリのリセットはキャンセルされました。');
            }
        },

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        /**
         * 直前に行われたデータ構造のマイグレーションを元に戻します。
         */
        rollbackMigration: () => {
            const confirmation = confirm(
                '本当にマイグレーションをロールバックしますか？\n' +
                'library.json と albums.json をマイグレーション直前の状態に戻します。\n' +
                'この操作は元に戻せません。'
            );

            if (confirmation) {
                console.log('[DEBUG] マイグレーションのロールバックコマンドを送信します...');
                ipcRenderer.send('debug-rollback-migration');
            } else {
                console.log('[DEBUG] マイグレーションのロールバックはキャンセルされました。');
            }
        },
        // ▲▲▲ ここまでが修正箇所です ▲▲▲

        /**
         * 利用可能なデバッグコマンドのヘルプを表示します。
         */
        help: () => {
            console.log(
                '%cUX Music デバッグコマンド一覧:\n' +
                '%c' +
                '  uxDebug.resetLibrary()        - 全てのライブラリデータ（曲、再生回数、ラウドネス、アートワーク）を削除します。\n' +
                '  uxDebug.rollbackMigration() - 直前に行われたデータ構造のマイグレーションを元に戻します。\n' +
                '  uxDebug.help()                - このヘルプメッセージを表示します。',
                'font-weight: bold; font-size: 1.2em; color: #1DB954;',
                'font-weight: normal; font-size: 1em; color: inherit;'
            );
        }
    };

    window.uxDebug = uxDebug;
    console.log('%c[DEBUG] デバッグインターフェイスが読み込まれました。コマンド一覧は `uxDebug.help()` を実行してください。', 'color: orange;');
}