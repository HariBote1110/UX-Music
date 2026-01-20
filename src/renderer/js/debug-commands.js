const electronAPI = window.electronAPI;
import { setVisualizerFpsLimit, toggleVisualizerEcoMode } from './player.js';

export function initDebugCommands() {
    const uxDebug = {
        resetLibrary: () => {
            const confirmation = confirm('本当にライブラリをリセットしますか？...');
            if (confirmation) {
                electronAPI.send('debug-reset-library');
            }
        },
        rollbackMigration: () => {
            const confirmation = confirm('本当にマイグレーションをロールバックしますか？...');
            if (confirmation) {
                electronAPI.send('debug-rollback-migration');
            }
        },
        setVisualizerFps: (fps) => {
            if (typeof fps !== 'number') {
                console.error('[DEBUG] Please provide a number...');
                return;
            }
            setVisualizerFpsLimit(fps);
        },
        toggleVisualizerEcoMode: (enabled) => {
            if (typeof enabled !== 'boolean') {
                console.error('[DEBUG] Please provide a boolean value (true or false).');
                return;
            }
            toggleVisualizerEcoMode(enabled);
        },
        enableYouTubeFeatures: () => {
            const confirmationMessage = `
                YouTube機能の有効化に関する注意事項：

                この機能を使用すると、YouTube上のコンテンツをダウンロードまたはストリーミング再生できますが、これは技術的な実験を目的としたものです。

                ・ダウンロードしたコンテンツは、私的利用の範囲を遵守してください。
                ・著作権で保護されたコンテンツの不正なダウンロードや再配布は、法律で固く禁じられています。
                ・この機能を使用したことによって生じるいかなる法的問題についても、開発者は一切の責任を負いません。

                上記を理解し、自己の責任において機能を使用することに同意しますか？
            `;
            const confirmation = confirm(confirmationMessage);
            if (confirmation) {
                console.log('[DEBUG] YouTube features ENABLED.');
                electronAPI.send('save-settings', { enableYouTube: true });
                document.querySelectorAll('[data-feature="youtube"], #add-youtube-btn, #add-youtube-playlist-btn').forEach(el => {
                    el.classList.remove('hidden');
                });
                alert('YouTube機能が有効になりました。');
            } else {
                console.log('[DEBUG] YouTube feature activation cancelled by user.');
            }
        },
        help: () => {
            console.log(
                '%cUX Music デバッグコマンド一覧:\n' +
                '%c' +
                '  uxDebug.resetLibrary()                - 全てのライブラリデータを削除します。\n' +
                '  uxDebug.rollbackMigration()         - データ構造のマイグレーションを元に戻します。\n' +
                '  uxDebug.setVisualizerFps(fps)       - ビジュアライザーのFPS上限を設定します。(0で制限解除)\n' +
                '  uxDebug.toggleVisualizerEcoMode(bool) - ビジュアライザーのエコモードを切り替えます。(trueで有効(デフォルト), falseで無効)\n' +
                '  uxDebug.enableYouTubeFeatures()         - YouTube関連の機能を有効化します。\n' +
                '  uxDebug.help()                          - このヘルプメッセージを表示します。',
                'font-weight: bold; font-size: 1.2em; color: #1DB954;',
                'font-weight: normal; font-size: 1em; color: inherit;'
            );
        }
    };
    window.uxDebug = uxDebug;
    console.log('%c[DEBUG] デバッグインターフェイスが読み込まれました。コマンド一覧は `uxDebug.help()` を実行してください。', 'color: orange;');
}