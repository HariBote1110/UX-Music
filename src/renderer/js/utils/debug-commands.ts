import { loadRendererSettings } from '../core/settings-helpers.js';
import { setVisualizerFpsLimit, toggleVisualizerEcoMode } from '../features/player.js';
import { showModalAdvanced } from '../ui/modal.js';
import { getWailsApp } from '../core/bridge.js';

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * 診断用: 公式再生（embed）中に呼び出し、音量を段階的に変えながら Go 出力段の
 * RMS（AudioDebugOutputRMS）を実測する。出力 RMS が音量に比例して変われば Go の
 * 音量制御は届いている。比例するのに聴感が変わらない／RMS がほぼ 0 のままなら、
 * ユーザーは PortAudio 出力ではなく WebKit の生音を聞いている（生音漏れ）と判断できる。
 */
async function embedVolumeProbe(): Promise<void> {
    const app = getWailsApp();
    if (!app || typeof app.AudioDebugOutputRMS !== 'function' || typeof app.AudioSetVolume !== 'function') {
        console.error('[DEBUG] Wails バインディングが利用できません（embed 再生中に実行してください）。');
        return;
    }
    const steps = [1.0, 0.5, 0.25, 0.0];
    console.log('[DEBUG] embedVolumeProbe 開始（各音量で 300ms 待って出力 RMS を計測）:');
    const results: Array<{ volume: number; rms: number }> = [];
    for (const volume of steps) {
        await app.AudioSetVolume(volume);
        await sleep(300);
        const rms = await app.AudioDebugOutputRMS();
        results.push({ volume, rms });
        console.log(`  volume=${volume.toFixed(2)}  outputRMS=${rms.toFixed(6)}`);
    }
    const full = results.find((r) => r.volume === 1.0)?.rms ?? 0;
    const half = results.find((r) => r.volume === 0.5)?.rms ?? 0;
    const zero = results.find((r) => r.volume === 0.0)?.rms ?? 0;
    if (full < 1e-5) {
        console.warn('[DEBUG] 判定: 音量 1.0 でも出力 RMS がほぼ 0。プロセスタップが音声を捕捉していない可能性が高い（＝生音漏れ）。');
    } else if (zero > full * 0.1) {
        console.warn('[DEBUG] 判定: 音量 0 でも出力 RMS が残存。Go 出力段以外の経路で音が出ている可能性。');
    } else {
        const ratio = full > 0 ? half / full : 0;
        console.log(`[DEBUG] 判定: 出力 RMS は音量に比例（half/full=${ratio.toFixed(3)}, 理想 0.5）。Go 出力段の音量制御は正常。`);
        console.log('[DEBUG] それでも聴感が変わらない場合は、聞こえている音が Go 出力ではなく WebKit の生音（生音漏れ）です。');
    }
    // スライダー現在値へ復帰する。
    const slider = document.getElementById('volume-slider') as HTMLInputElement | null;
    const restore = slider ? parseFloat(slider.value) : 1.0;
    await app.AudioSetVolume(Number.isFinite(restore) ? restore : 1.0);
    console.log(`[DEBUG] 音量をスライダー値 ${Number.isFinite(restore) ? restore : 1.0} に復帰しました。`);
}

const electronAPI = window.electronAPI;

// YouTube の公式再生（embed）は既定で常に利用可能。ここで解放するのは
// ダウンロードモード／ストリーミングモード（非公式）の選択 UI のみ。
const YOUTUBE_ADVANCED_MODES_CONSENT_MESSAGE = `
    YouTube追加モードの拡張に関する注意事項：

    既定の公式再生（embed）に加えて、ダウンロードモードおよびストリーミングモード（非公式）を選択できるようになります。これは技術的な実験を目的としたものです。

    ・ダウンロードしたコンテンツは、私的利用の範囲を遵守してください。
    ・著作権で保護されたコンテンツの不正なダウンロードや再配布は、法律で固く禁じられています。
    ・この機能を使用したことによって生じるいかなる法的問題についても、開発者は一切の責任を負いません。

    上記を理解し、自己の責任において機能を使用することに同意しますか？
`;

function requestYoutubeAdvancedModesConsent() {
    if (window.go !== undefined) {
        return new Promise((resolve) => {
            showModalAdvanced({
                title: 'YouTube追加モードの有効化',
                message: YOUTUBE_ADVANCED_MODES_CONSENT_MESSAGE.trim(),
                placeholder: '',
                requireInput: false,
                okText: '同意して有効化',
                cancelText: 'キャンセル',
                onOk: () => resolve(true),
                onCancel: () => resolve(false),
            });
        });
    }
    return Promise.resolve(confirm(YOUTUBE_ADVANCED_MODES_CONSENT_MESSAGE));
}

function revealYoutubeAdvancedModesUI() {
    document.querySelectorAll('[data-feature="youtube-advanced"]').forEach((el) => {
        el.classList.remove('hidden');
    });
}

export async function enableYoutubeAdvancedModesWithConsent({ showAlert = true } = {}) {
    const settings = await loadRendererSettings();
    if (settings.enableYoutubeAdvancedModes) {
        revealYoutubeAdvancedModesUI();
        if (showAlert) {
            alert('YouTube追加モードはすでに有効です。');
        }
        return true;
    }

    const confirmation = await requestYoutubeAdvancedModesConsent();
    if (!confirmation) {
        console.log('[DEBUG] YouTube advanced modes activation cancelled by user.');
        return false;
    }

    console.log('[DEBUG] YouTube advanced modes ENABLED.');
    electronAPI.send('save-settings', { enableYoutubeAdvancedModes: true });
    revealYoutubeAdvancedModesUI();
    if (showAlert) {
        alert('YouTube追加モードが有効になりました。');
    }
    return true;
}

export function initDebugCommands() {
    const uxDebug = {
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
        enableYoutubeAdvancedModes: () => {
            void enableYoutubeAdvancedModesWithConsent({ showAlert: true });
        },
        embedVolumeProbe: () => {
            void embedVolumeProbe();
        },
        help: () => {
            console.log(
                '%cUX Music デバッグコマンド一覧:\n' +
                '%c' +
                '  uxDebug.setVisualizerFps(fps)       - ビジュアライザーのFPS上限を設定します。(0で制限解除)\n' +
                '  uxDebug.toggleVisualizerEcoMode(bool) - ビジュアライザーのエコモードを切り替えます。(trueで有効(デフォルト), falseで無効)\n' +
                '  uxDebug.enableYoutubeAdvancedModes()    - YouTubeのダウンロード／ストリーミング(非公式)モードを有効化します。\n' +
                '  uxDebug.embedVolumeProbe()              - [診断] 公式再生中に音量を変えながら出力RMSを実測し、音量制御が届いているか判定します。\n' +
                '  (補足) 「ライブラリを管理」ボタン連打でも有効化できます。\n' +
                '  uxDebug.help()                          - このヘルプメッセージを表示します。',
                'font-weight: bold; font-size: 1.2em; color: #1DB954;',
                'font-weight: normal; font-size: 1em; color: inherit;'
            );
        }
    };
    window.uxDebug = uxDebug;
    console.log('%c[DEBUG] デバッグインターフェイスが読み込まれました。コマンド一覧は `uxDebug.help()` を実行してください。', 'color: orange;');
}
