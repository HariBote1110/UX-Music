// src/renderer/js/ui/column-config.js
// リスト列の表示/非表示と幅を管理するモジュール

import { showContextMenu } from './utils.js';

const STORAGE_KEY = 'ux-music-column-config';

/**
 * 全列の定義。
 * key:       内部識別子
 * label:     ヘッダー表示テキスト
 * cssClass:  song-item 内の CSS クラス名
 * width:     デフォルト幅 (CSS grid値)
 * visible:   表示/非表示
 * locked:    true のとき非表示にできない
 * resizable: リサイズ可能か
 */
export const ALL_COLUMNS = [
    { key: 'index', label: '#', cssClass: 'song-index', width: '40px', visible: true, locked: true, resizable: false },
    { key: 'artwork', label: '', cssClass: 'song-artwork-col', width: '56px', visible: true, locked: true, resizable: false },
    { key: 'title', label: 'タイトル', cssClass: 'song-title', width: '5fr', visible: true, locked: true, resizable: true },
    { key: 'artist', label: 'アーティスト', cssClass: 'song-artist', width: '4fr', visible: true, locked: false, resizable: true },
    { key: 'album', label: 'アルバム', cssClass: 'song-album', width: '4fr', visible: true, locked: false, resizable: true },
    { key: 'hires', label: 'HR', cssClass: 'song-hires', width: '40px', visible: true, locked: false, resizable: false },
    { key: 'duration', label: '時間', cssClass: 'song-duration', width: '70px', visible: true, locked: false, resizable: false },
    { key: 'playCount', label: '回数', cssClass: 'song-play-count', width: '60px', visible: true, locked: false, resizable: false },
];

let currentConfig = null;

/**
 * localStorage から列設定を読み込む。なければデフォルトを返す。
 */
export function loadColumnConfig() {
    if (currentConfig) return currentConfig;
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (raw) {
            const saved = JSON.parse(raw);
            currentConfig = ALL_COLUMNS.map(col => {
                const s = saved.find(c => c.key === col.key);
                if (!s) return { ...col };
                // 古いバグでpx絶対値が保存されていた場合はデフォルトfr値を使用
                const savedWidth = s.width || col.width;
                const isAbsolutePx = savedWidth.endsWith('px') && col.width.endsWith('fr');
                return {
                    ...col,
                    visible: s.visible !== undefined ? s.visible : col.visible,
                    width: isAbsolutePx ? col.width : savedWidth,
                };
            });
            return currentConfig;
        }
    } catch (e) {
        console.warn('[ColumnConfig] Failed to load:', e);
    }
    currentConfig = ALL_COLUMNS.map(col => ({ ...col }));
    return currentConfig;
}

/**
 * 現在の列設定を localStorage に保存する。
 */
export function saveColumnConfig(config) {
    currentConfig = config || currentConfig;
    if (!currentConfig) return;
    try {
        const toSave = currentConfig.map(({ key, visible, width }) => ({ key, visible, width }));
        localStorage.setItem(STORAGE_KEY, JSON.stringify(toSave));
    } catch (e) {
        console.warn('[ColumnConfig] Failed to save:', e);
    }
}

/**
 * 可視列のみを返す。
 */
export function getVisibleColumns() {
    const config = loadColumnConfig();
    return config.filter(col => col.visible);
}

/**
 * 可視列に基づいた grid-template-columns の値を返す。
 */
export function getGridTemplate() {
    return getVisibleColumns().map(col => col.width).join(' ');
}

/**
 * 列の表示/非表示を切り替えてリストを再描画する。
 * @param {string} columnKey - 列のキー
 * @param {Function} onUpdate - 変更後のコールバック
 */
export function toggleColumnVisibility(columnKey, onUpdate) {
    const config = loadColumnConfig();
    const col = config.find(c => c.key === columnKey);
    if (!col || col.locked) return;
    col.visible = !col.visible;
    saveColumnConfig(config);
    if (onUpdate) onUpdate();
}

/**
 * 可視列の幅を更新して保存する。
 * @param {string[]} widths - 可視列と同じ順序の幅のリスト
 */
export function updateVisibleColumnWidths(widths) {
    const config = loadColumnConfig();
    const visible = config.filter(c => c.visible);
    widths.forEach((w, i) => {
        if (visible[i]) visible[i].width = w;
    });
    saveColumnConfig(config);
}

/**
 * ヘッダー上の右クリックメニューで列の表示/非表示を切り替える。
 * @param {MouseEvent} e
 * @param {Function} onUpdate - 変更後のコールバック
 */
export function showColumnContextMenu(e, onUpdate) {
    e.preventDefault();
    const config = loadColumnConfig();
    const menuItems = config
        .filter(col => !col.locked)
        .map(col => ({
            label: `${col.visible ? '✓ ' : '   '}${col.label}`,
            action: () => toggleColumnVisibility(col.key, onUpdate),
        }));
    showContextMenu(e.pageX, e.pageY, menuItems);
}

/**
 * キャッシュをリセットする (テスト用)
 */
export function resetColumnConfigCache() {
    currentConfig = null;
}
