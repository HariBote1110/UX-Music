// src/renderer/js/ui/grid-density.ts
//
// アルバム/アーティスト/プレイリストのグリッド表示密度（アイテムの最小幅）を
// 3段階（compact/standard/large）で切り替えるための、永続化込みの小さなモジュール。
// CSS 側は styles/views.css の `--grid-item-min` 変数（:root 既定値は base.css）
// を `grid-template-columns: repeat(auto-fill, minmax(var(--grid-item-min), 1fr))`
// で参照しているだけなので、この変数を書き換えるだけで再描画なしにレイアウトが
// 追従する。

import { musicApi } from '../core/bridge.js';

export type GridDensity = 'compact' | 'standard' | 'large';

const DENSITY_PX: Record<GridDensity, number> = {
    compact: 120,
    standard: 160,
    large: 220,
};

const DENSITY_LABELS: Record<GridDensity, string> = {
    compact: '小',
    standard: '標準',
    large: '大',
};

const DENSITY_ORDER: GridDensity[] = ['compact', 'standard', 'large'];

export function isGridDensity(value: unknown): value is GridDensity {
    return value === 'compact' || value === 'standard' || value === 'large';
}

/** 密度設定 → px の純粋なマッピング。不明な値は 'standard' 扱い。 */
export function gridDensityToPx(density: unknown): number {
    return DENSITY_PX[isGridDensity(density) ? density : 'standard'];
}

let currentDensity: GridDensity = 'standard';

/** 現在アプリに適用されている密度設定（UI 描画時の初期選択状態に使う）。 */
export function getCurrentGridDensity(): GridDensity {
    return currentDensity;
}

/** `--grid-item-min` CSS 変数へ反映するだけで、永続化は行わない。 */
export function applyGridDensity(density: unknown): void {
    currentDensity = isGridDensity(density) ? density : 'standard';
    document.documentElement.style.setProperty('--grid-item-min', `${gridDensityToPx(currentDensity)}px`);
}

/** 反映 + 設定として保存する。 */
export async function saveGridDensity(density: GridDensity): Promise<void> {
    applyGridDensity(density);
    await musicApi.saveSettings({ gridDensity: density });
}

/**
 * アイコン無しの3段階セグメントコントロールを生成する。
 * .view-header の右側（既存のボタン類と並ぶ位置）に置くことを想定。
 */
export function createGridDensityControl(): HTMLElement {
    const wrapper = document.createElement('div');
    wrapper.className = 'grid-density-control';
    wrapper.setAttribute('role', 'group');
    wrapper.setAttribute('aria-label', 'グリッド表示密度');

    DENSITY_ORDER.forEach((density) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'grid-density-btn';
        btn.textContent = DENSITY_LABELS[density];
        btn.classList.toggle('active', density === currentDensity);
        btn.addEventListener('click', () => {
            if (density === currentDensity) return;
            void saveGridDensity(density);
            wrapper.querySelectorAll('.grid-density-btn').forEach((el) => el.classList.remove('active'));
            btn.classList.add('active');
        });
        wrapper.appendChild(btn);
    });

    return wrapper;
}
