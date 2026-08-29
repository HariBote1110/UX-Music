// src/renderer/js/ui/equalizer.ts
// サイドバーEQタブと設定画面のグラフィックEQは、この1本の共有コンポーネント
// （js/ui/equalizer/graphic-equaliser.ts）と単一の状態ソース（state.equalizerSettings.bands）
// を共有する。旧・簡易EQ（Bass/Mid/Treble の3ノブ）は初回ロード時に一度だけ bands へ
// 折り込んで移行し、以後は bands のみを情報源として扱う。
import { state, elements } from '../core/state.js';
import { applyEqualizerSettings } from '../features/audio-graph.js';
import { musicApi } from '../core/bridge.js';
import { EQ_PRESETS, migrateLegacySimpleSettings, presetBands } from './equalizer/eq-maths.js';
import { mountGraphicEqualiser, refreshAllInstances, type GraphicEqualiserCallbacks } from './equalizer/graphic-equaliser.js';

let saveDebounceTimer: ReturnType<typeof setTimeout> | null = null;
const SAVE_DEBOUNCE_MS = 200;

function saveSettings() {
    musicApi.saveSettings({ equalizer: state.equalizerSettings });
}

/** バンドのドラッグ中など、連続して発生しうる保存要求をデバウンスする。 */
function saveSettingsDebounced() {
    if (saveDebounceTimer !== null) clearTimeout(saveDebounceTimer);
    saveDebounceTimer = setTimeout(() => {
        saveDebounceTimer = null;
        saveSettings();
    }, SAVE_DEBOUNCE_MS);
}

/** 旧・簡易EQ（bass/mid/treble）のみが保存されていた場合、bands へ一度だけ移行する。 */
function migrateLegacySettingsIfNeeded() {
    const migrated = migrateLegacySimpleSettings(state.equalizerSettings);
    if (!migrated) return;
    state.equalizerSettings.bands = migrated.bands;
    state.equalizerSettings.bass = migrated.bass;
    state.equalizerSettings.mid = migrated.mid;
    state.equalizerSettings.treble = migrated.treble;
}

/** state.equalizerSettings.bands（唯一の情報源）を音声グラフへ反映する。 */
export function applyCurrentSettings() {
    const { active, bands, preamp } = state.equalizerSettings;
    if (!active) {
        applyEqualizerSettings({ active: false, preamp: 0, bands: Array(10).fill(0) });
        return;
    }
    applyEqualizerSettings({ active: true, preamp, bands: [...bands] });
}

function applyPresetByName(presetName: string) {
    const bands = presetBands(presetName);
    if (!bands) return;
    state.equalizerSettings.bands = bands;
    applyCurrentSettings();
}

const sharedCallbacks: GraphicEqualiserCallbacks = {
    getState: () => state.equalizerSettings,
    onBandsChange: bands => {
        state.equalizerSettings.bands = bands;
        applyCurrentSettings();
    },
    onPresetChange: presetName => applyPresetByName(presetName),
    onReset: () => applyPresetByName('Flat'),
    onToggleActive: active => {
        state.equalizerSettings.active = active;
        applyCurrentSettings();
    },
    onCommit: () => saveSettingsDebounced(),
};

/**
 * サイドバーEQタブ（#equalizer-view）に共有グラフィックEQを描画する。
 * 冪等: 同じ container への再呼び出しは既存の内容を置き換える。
 */
export function renderEqualizer() {
    const view = elements.equalizerView as HTMLElement | undefined;
    if (!view) return;
    mountGraphicEqualiser(view, 'sidebar', sharedCallbacks);
}

/**
 * 設定画面のEQセクションに共有グラフィックEQを描画する。
 * container は設定画面側が用意して渡す（設定エージェント側の契約）。
 * 後方互換のため container 省略時は #graphic-eq-container を探す。
 */
export function renderGraphicEQ(container?: HTMLElement) {
    const target = container ?? (document.getElementById('graphic-eq-container') as HTMLElement | null);
    if (!target) return;
    mountGraphicEqualiser(target, 'settings', sharedCallbacks);
}

export function initEqualizer() {
    if (!elements.equalizerView) {
        console.warn('[Equalizer] View element not found. Initialization skipped.');
        return;
    }

    migrateLegacySettingsIfNeeded();
    applyCurrentSettings();
    renderEqualizer();
}

// 型のみを再エクスポート（他モジュールから import { EQ_PRESETS } できるようにする）。
export { EQ_PRESETS };
