// src/renderer/js/ui/collection-shuffle-control.ts
//
// アルバム/プレイリスト詳細ヘッダーおよびグリッドの右クリックメニューで使う、
// コレクション既定シャッフル設定の共有 UI ヘルパー。

import type { CollectionRef, ShufflePreference } from '../features/collection-shuffle.js';
import {
    getCollectionShufflePreference,
    setCollectionShufflePreference,
    subscribeCollectionShufflePreferences,
} from '../features/collection-shuffle.js';
import { showContextMenu, type ContextMenuItem } from './utils.js';
import { showNotification } from './notification.js';

const SHUFFLE_ICON_SVG = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M 2 18 L 7 18 C 10 18 14 6 17 6 L 22 6" /><path d="M 19 3 L 22 6 L 19 9" /><path d="M 2 6 L 7 6 C 10 6 14 18 17 18 L 22 18" /><path d="M 19 15 L 22 18 L 19 21" /></svg>';

const ORDERED_ICON_SVG = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="3" y1="6" x2="17" y2="6" /><line x1="3" y1="12" x2="17" y2="12" /><line x1="3" y1="18" x2="17" y2="18" /><polyline points="19 4 22 6 19 8" /><polyline points="19 10 22 12 19 14" /><polyline points="19 16 22 18 19 20" /></svg>';

const NEUTRAL_ICON_SVG = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="3" y1="6" x2="21" y2="6" /><line x1="3" y1="12" x2="21" y2="12" /><line x1="3" y1="18" x2="21" y2="18" /></svg>';

const PREFERENCE_LABELS: Record<'unset' | 'on' | 'off', string> = {
    unset: '未設定（通常の設定に従う）',
    on: 'シャッフル',
    off: '順番通り',
};

function preferenceKeyOf(pref: ShufflePreference): 'unset' | 'on' | 'off' {
    return pref === 'on' ? 'on' : pref === 'off' ? 'off' : 'unset';
}

function iconFor(pref: ShufflePreference): string {
    const key = preferenceKeyOf(pref);
    if (key === 'on') return SHUFFLE_ICON_SVG;
    if (key === 'off') return ORDERED_ICON_SVG;
    return NEUTRAL_ICON_SVG;
}

async function applyPreference(ref: CollectionRef, pref: ShufflePreference): Promise<void> {
    try {
        await setCollectionShufflePreference(ref, pref);
    } catch (error) {
        showNotification(`既定のシャッフル設定を保存できませんでした: ${(error as Error)?.message || String(error)}`, 4000);
    }
}

/**
 * 既定シャッフル設定を選択するための共通メニュー項目リストを作る。
 * グリッドの右クリックメニューにフラット項目として差し込む場合にも使える。
 */
export function buildShufflePreferenceMenuItems(ref: CollectionRef): ContextMenuItem[] {
    const current = preferenceKeyOf(getCollectionShufflePreference(ref));
    const entries: Array<['unset' | 'on' | 'off', ShufflePreference]> = [
        ['unset', null],
        ['on', 'on'],
        ['off', 'off'],
    ];
    return entries.map(([key, pref]) => ({
        label: PREFERENCE_LABELS[key],
        checked: current === key,
        action: () => void applyPreference(ref, pref),
    }));
}

export type CollectionShuffleControl = {
    element: HTMLElement;
    destroy: () => void;
};

/**
 * アルバム/プレイリスト詳細ヘッダー用の、既定シャッフルを選択する小さなボタンを作る。
 * クリックで showContextMenu による選択メニューを開く。
 * subscribeCollectionShufflePreferences で外部変化にも追従する。
 */
export function createCollectionShuffleControl(ref: CollectionRef): CollectionShuffleControl {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'collection-shuffle-btn';

    const render = () => {
        const pref = getCollectionShufflePreference(ref);
        const key = preferenceKeyOf(pref);
        button.innerHTML = iconFor(pref);
        button.classList.toggle('is-on', key === 'on');
        button.classList.toggle('is-off', key === 'off');
        button.classList.toggle('is-unset', key === 'unset');
        button.title = `既定のシャッフル: ${PREFERENCE_LABELS[key]}`;
        button.setAttribute('aria-label', `既定のシャッフル設定（現在: ${PREFERENCE_LABELS[key]}）`);
    };
    render();

    const unsubscribe = subscribeCollectionShufflePreferences(render);

    button.addEventListener('click', (e) => {
        e.stopPropagation();
        const rect = button.getBoundingClientRect();
        showContextMenu(rect.left, rect.bottom + 4, buildShufflePreferenceMenuItems(ref));
    });

    return {
        element: button,
        destroy: () => unsubscribe(),
    };
}
