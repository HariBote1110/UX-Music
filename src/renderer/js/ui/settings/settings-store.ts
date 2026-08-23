// src/renderer/js/ui/settings/settings-store.ts
//
// 新設定ページの保存契約: 「OK ボタンで一括保存」を廃止し、コントロールが変更される
// たびに `save(patch)` を即時呼び出す。バックエンドの SaveSettings は shallow merge
// なので、変更されたキーだけを送れば他の設定を壊さない。
//
// 併せて小さな pub/sub を持ち、あるコントロールが保存した変更を他のコントロール
// （例: 別セクションから見えるプレビュー）へ反映したいときに使える。

import { musicApi } from '../../core/bridge.js';
import { loadRendererSettings, type RendererSettingsRead } from '../../core/settings-helpers.js';

export type SettingsPatch = Record<string, unknown>;
type Listener = (patch: SettingsPatch) => void;

const listeners = new Set<Listener>();

/** 現在保存されている設定を読み出す（表示用）。 */
export async function readSettings(): Promise<RendererSettingsRead> {
    return loadRendererSettings();
}

/** 差分だけを即時保存し、購読者へ通知する。 */
export async function save(patch: SettingsPatch): Promise<void> {
    await musicApi.saveSettings(patch);
    for (const listener of listeners) {
        listener(patch);
    }
}

/** 保存イベントを購読する。戻り値の関数で解除する。 */
export function subscribe(listener: Listener): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
}
