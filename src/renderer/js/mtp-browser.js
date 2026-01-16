// src/renderer/js/mtp-browser.js
// MTPストレージブラウザ - Finder風ファイルブラウザ

import { state, elements } from './state.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { formatBytes, showContextMenu } from './ui/utils.js';
const { ipcRenderer } = require('electron');

// 状態管理
let browserState = {
    currentStorageId: null,
    currentPath: '/',
    history: [],
    historyIndex: -1,
    selectedItems: new Set(),
    isLoading: false
};

// DOM要素キャッシュ
let browserElements = {};

/**
 * MTPブラウザを初期化
 * @param {number} storageId - ストレージID
 * @param {string} initialPath - 初期パス
 */
export async function initMtpBrowser(storageId, initialPath = '/') {
    console.log(`[MTP Browser] 初期化: StorageID=${storageId}, Path=${initialPath}`);

    // DOM要素を取得
    browserElements = {
        view: document.getElementById('mtp-browser-view'),
        backBtn: document.getElementById('mtp-browser-back-btn'),
        forwardBtn: document.getElementById('mtp-browser-forward-btn'),
        breadcrumb: document.getElementById('mtp-browser-breadcrumb'),
        closeBtn: document.getElementById('mtp-browser-close-btn'),
        content: document.getElementById('mtp-browser-content'),
        refreshBtn: document.getElementById('mtp-browser-refresh-btn'),
        // デバイス情報ヘッダー
        headerDeviceName: document.getElementById('mtp-header-device-name'),
        headerStorageInfo: document.getElementById('mtp-header-storage-info'),
        headerStorageUsed: document.getElementById('mtp-header-storage-used')
    };

    // 状態をリセット
    browserState = {
        currentStorageId: storageId,
        currentPath: initialPath,
        history: [initialPath],
        historyIndex: 0,
        selectedItems: new Set(),
        isLoading: false
    };

    // イベントリスナーを設定
    setupEventListeners();

    // デバイス情報ヘッダーを更新
    updateDeviceHeader();

    // 初期ディレクトリを読み込み
    await browseDirectory(storageId, initialPath, false);
}

/**
 * イベントリスナーを設定
 */
function setupEventListeners() {
    // 戻るボタン
    browserElements.backBtn.onclick = () => navigateBack();

    // 進むボタン
    browserElements.forwardBtn.onclick = () => navigateForward();

    // 閉じるボタン
    browserElements.closeBtn.onclick = () => closeBrowser();

    // 更新ボタン
    if (browserElements.refreshBtn) {
        browserElements.refreshBtn.onclick = () => refresh();
    }

    // 背景クリックで選択解除
    browserElements.content.onclick = (e) => {
        if (e.target === browserElements.content) {
            clearSelection();
        }
    };
}

/**
 * ディレクトリの内容を取得・表示
 * @param {number} storageId - ストレージID
 * @param {string} fullPath - フルパス
 * @param {boolean} addToHistory - 履歴に追加するか
 */
export async function browseDirectory(storageId, fullPath, addToHistory = true) {
    if (browserState.isLoading) return;

    console.log(`[MTP Browser] ブラウジング: ${fullPath}`);
    browserState.isLoading = true;

    // ローディング表示
    browserElements.content.innerHTML = '<p class="mtp-loading">📂 読み込み中...</p>';
    clearSelection();

    try {
        const result = await ipcRenderer.invoke('mtp-browse-directory', {
            storageId: storageId,
            fullPath: fullPath
        });

        if (result.error) {
            browserElements.content.innerHTML = `<p class="mtp-error">❌ エラー: ${result.error}</p>`;
            return;
        }

        // 状態を更新
        browserState.currentStorageId = storageId;
        browserState.currentPath = fullPath;

        // 履歴に追加
        if (addToHistory) {
            browserState.history = browserState.history.slice(0, browserState.historyIndex + 1);
            browserState.history.push(fullPath);
            browserState.historyIndex = browserState.history.length - 1;
        }

        // ファイルリストを描画
        renderFileList(result.data || []);

        // パンくずリストを更新
        updateBreadcrumb(fullPath);

        // ナビゲーションボタンを更新
        updateNavigationButtons();

    } catch (err) {
        console.error('[MTP Browser] エラー:', err);
        browserElements.content.innerHTML = `<p class="mtp-error">❌ エラー: ${err.message}</p>`;
    } finally {
        browserState.isLoading = false;
    }
}

/**
 * ファイルリストを描画
 * @param {Array} files - ファイルリスト
 */
function renderFileList(files) {
    if (!files || files.length === 0) {
        browserElements.content.innerHTML = '<p class="mtp-empty">📁 空のフォルダです</p>';
        return;
    }

    // フォルダを先、ファイルを後にソート
    const sorted = [...files].sort((a, b) => {
        if (a.isFolder && !b.isFolder) return -1;
        if (!a.isFolder && b.isFolder) return 1;
        return (a.name || '').localeCompare(b.name || '');
    });

    const listHtml = sorted.map(item => {
        const icon = getFileIcon(item);
        const sizeStr = item.isFolder ? '' : formatBytes(item.size || 0);
        const typeStr = item.isFolder ? 'フォルダ' : getFileType(item.name);
        const fullPath = item.fullPath || `${browserState.currentPath}${browserState.currentPath.endsWith('/') ? '' : '/'}${item.name}`;

        return `
      <div class="mtp-file-item" 
           data-path="${escapeHtml(fullPath)}" 
           data-is-folder="${item.isFolder}"
           data-name="${escapeHtml(item.name)}"
           data-size="${item.size || 0}">
        <span class="mtp-file-icon">${icon}</span>
        <span class="mtp-file-name">${escapeHtml(item.name)}</span>
        <span class="mtp-file-size">${sizeStr}</span>
        <span class="mtp-file-type">${typeStr}</span>
      </div>
    `;
    }).join('');

    // スペーサーをリストの末尾に追加（フッターとのかぶりを防ぐ）
    const spacerHtml = '<div class="mtp-list-spacer"></div>';

    browserElements.content.innerHTML = listHtml + spacerHtml;

    // ファイルアイテムにイベントを追加
    browserElements.content.querySelectorAll('.mtp-file-item').forEach(item => {
        // クリック: 選択
        item.addEventListener('click', (e) => {
            e.stopPropagation();

            if (e.metaKey || e.ctrlKey) {
                // Cmd/Ctrl + クリック: 複数選択
                toggleSelection(item);
            } else if (e.shiftKey) {
                // Shift + クリック: 範囲選択
                rangeSelect(item);
            } else {
                // 通常クリック: 単一選択
                selectOnly(item);
            }
        });

        // ダブルクリック: フォルダを開く
        item.addEventListener('dblclick', (e) => {
            e.stopPropagation();
            const isFolder = item.dataset.isFolder === 'true';

            if (isFolder) {
                const path = item.dataset.path;
                browseDirectory(browserState.currentStorageId, path);
            }
        });

        // 右クリック: コンテキストメニュー
        item.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            e.stopPropagation();

            // まだ選択されていなければ選択する
            if (!browserState.selectedItems.has(item.dataset.path)) {
                selectOnly(item);
            }

            showMtpContextMenu(e.pageX, e.pageY);
        });
    });
}

/**
 * ファイルアイコンを取得
 */
function getFileIcon(item) {
    if (item.isFolder) return '📁';

    const ext = (item.name || '').split('.').pop().toLowerCase();

    const iconMap = {
        // 音楽
        'mp3': '🎵', 'flac': '🎵', 'm4a': '🎵', 'wav': '🎵', 'ogg': '🎵', 'aac': '🎵', 'wma': '🎵',
        // 画像
        'jpg': '🖼️', 'jpeg': '🖼️', 'png': '🖼️', 'gif': '🖼️', 'webp': '🖼️', 'bmp': '🖼️',
        // 動画
        'mp4': '🎬', 'mkv': '🎬', 'avi': '🎬', 'mov': '🎬', 'wmv': '🎬',
        // ドキュメント
        'pdf': '📄', 'doc': '📄', 'docx': '📄', 'txt': '📄', 'rtf': '📄',
        // アーカイブ
        'zip': '📦', 'rar': '📦', '7z': '📦', 'tar': '📦', 'gz': '📦'
    };

    return iconMap[ext] || '📄';
}

/**
 * ファイルタイプを取得
 */
function getFileType(name) {
    const ext = (name || '').split('.').pop().toUpperCase();
    return ext || 'ファイル';
}

/**
 * パンくずリストを更新
 */
function updateBreadcrumb(fullPath) {
    const deviceName = state.mtpDevice?.name || 'デバイス';
    const parts = fullPath.split('/').filter(p => p);

    let html = `<span class="breadcrumb-item clickable" data-path="/">📱 ${escapeHtml(deviceName)}</span>`;

    let currentPath = '';
    parts.forEach((part, index) => {
        currentPath += '/' + part;
        const isLast = index === parts.length - 1;
        html += `<span class="breadcrumb-separator">/</span>`;
        html += `<span class="breadcrumb-item ${isLast ? 'current' : 'clickable'}" data-path="${escapeHtml(currentPath)}">${escapeHtml(part)}</span>`;
    });

    browserElements.breadcrumb.innerHTML = html;

    // クリック可能なパンくずにイベントを追加
    browserElements.breadcrumb.querySelectorAll('.breadcrumb-item.clickable').forEach(item => {
        item.addEventListener('click', () => {
            const path = item.dataset.path;
            browseDirectory(browserState.currentStorageId, path);
        });
    });
}

/**
 * ナビゲーションボタンを更新
 */
function updateNavigationButtons() {
    browserElements.backBtn.disabled = browserState.historyIndex <= 0;
    browserElements.forwardBtn.disabled = browserState.historyIndex >= browserState.history.length - 1;
}

/**
 * 戻る
 */
function navigateBack() {
    if (browserState.historyIndex > 0) {
        browserState.historyIndex--;
        const path = browserState.history[browserState.historyIndex];
        browseDirectory(browserState.currentStorageId, path, false);
    }
}

/**
 * 進む
 */
function navigateForward() {
    if (browserState.historyIndex < browserState.history.length - 1) {
        browserState.historyIndex++;
        const path = browserState.history[browserState.historyIndex];
        browseDirectory(browserState.currentStorageId, path, false);
    }
}

/**
 * 更新
 */
function refresh() {
    browseDirectory(browserState.currentStorageId, browserState.currentPath, false);
}

/**
 * 選択をトグル
 */
function toggleSelection(item) {
    const path = item.dataset.path;

    if (browserState.selectedItems.has(path)) {
        browserState.selectedItems.delete(path);
        item.classList.remove('selected');
    } else {
        browserState.selectedItems.add(path);
        item.classList.add('selected');
    }

    updateSelectionUI();
}

/**
 * 単一選択
 */
function selectOnly(item) {
    clearSelection();
    browserState.selectedItems.add(item.dataset.path);
    item.classList.add('selected');
    updateSelectionUI();
}

/**
 * 範囲選択
 */
function rangeSelect(item) {
    const items = Array.from(browserElements.content.querySelectorAll('.mtp-file-item'));
    const clickedIndex = items.indexOf(item);

    if (clickedIndex === -1) return;

    // 最後に選択したアイテムのインデックスを取得
    let lastSelectedIndex = -1;
    for (let i = 0; i < items.length; i++) {
        if (items[i].classList.contains('selected')) {
            lastSelectedIndex = i;
        }
    }

    if (lastSelectedIndex === -1) {
        selectOnly(item);
        return;
    }

    // 範囲を選択
    const start = Math.min(lastSelectedIndex, clickedIndex);
    const end = Math.max(lastSelectedIndex, clickedIndex);

    for (let i = start; i <= end; i++) {
        browserState.selectedItems.add(items[i].dataset.path);
        items[i].classList.add('selected');
    }

    updateSelectionUI();
}

/**
 * 選択をクリア
 */
function clearSelection() {
    browserState.selectedItems.clear();
    browserElements.content.querySelectorAll('.mtp-file-item.selected').forEach(item => {
        item.classList.remove('selected');
    });
    updateSelectionUI();
}

/**
 * 選択状態のUIを更新
 */
function updateSelectionUI() {
    // 現在は選択状態の表示のみ
    // 将来的にコンテキストメニューでダウンロード・削除を実装可能
    const count = browserState.selectedItems.size;
    console.log(`[MTP Browser] ${count}件選択中`);
}

/**
 * ブラウザを閉じる
 */
function closeBrowser() {
    browserElements.view.classList.add('hidden');
    document.getElementById('main-content').classList.remove('hidden');
}

/**
 * MTPブラウザを停止
 */
export function stopMtpBrowser() {
    browserState = {
        currentStorageId: null,
        currentPath: '/',
        history: [],
        historyIndex: -1,
        selectedItems: new Set(),
        isLoading: false
    };
}

/**
 * HTMLエスケープ
 */
function escapeHtml(str) {
    if (!str) return '';
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

/**
 * デバイス情報ヘッダーを更新
 */
function updateDeviceHeader() {
    const device = state.mtpDevice;
    const storages = state.mtpStorages;

    // デバイス名
    if (browserElements.headerDeviceName) {
        browserElements.headerDeviceName.textContent = device?.name || 'MTPデバイス';
    }

    // ストレージ情報
    if (storages && storages.length > 0) {
        const storage = storages[0];
        const used = storage.total - storage.free;
        const usedPercent = ((used / storage.total) * 100).toFixed(1);

        // ストレージ情報テキスト
        if (browserElements.headerStorageInfo) {
            browserElements.headerStorageInfo.textContent =
                `${formatBytes(storage.free)} 空き / ${formatBytes(storage.total)} (${usedPercent}% 使用中)`;
        }

        // ストレージバー
        if (browserElements.headerStorageUsed) {
            browserElements.headerStorageUsed.style.width = `${usedPercent}%`;
        }
    } else {
        if (browserElements.headerStorageInfo) {
            browserElements.headerStorageInfo.textContent = 'ストレージ情報なし';
        }
        if (browserElements.headerStorageUsed) {
            browserElements.headerStorageUsed.style.width = '0%';
        }
    }
}

/**
 * MTPブラウザ用コンテキストメニューを表示
 * @param {number} x - X座標
 * @param {number} y - Y座標
 */
function showMtpContextMenu(x, y) {
    const count = browserState.selectedItems.size;
    const label = count === 1 ? '選択中のアイテム' : `${count}件選択中`;

    const menuItems = [
        {
            label: `⬇️ ダウンロード (${label})`,
            action: () => downloadSelected()
        },
        {
            label: `🗑️ 削除 (${label})`,
            action: () => deleteSelected()
        }
    ];

    showContextMenu(x, y, menuItems);
}

/**
 * 選択したファイルをダウンロード
 */
async function downloadSelected() {
    if (browserState.selectedItems.size === 0) return;

    // ダウンロード先を選択
    const destination = await ipcRenderer.invoke('mtp-select-download-folder');
    if (!destination) return;

    const sources = Array.from(browserState.selectedItems);
    showNotification(`${sources.length}件のダウンロードを開始します...`);

    try {
        const result = await ipcRenderer.invoke('mtp-download-files', {
            storageId: browserState.currentStorageId,
            sources: sources,
            destination: destination
        });

        if (result.error) {
            showNotification(`ダウンロードエラー: ${result.error}`);
        } else {
            showNotification(`${sources.length}件のダウンロードが完了しました`);
        }
        hideNotification(3000);

    } catch (err) {
        showNotification(`エラー: ${err.message}`);
        hideNotification(3000);
    }
}

/**
 * 選択したファイルを削除
 */
async function deleteSelected() {
    if (browserState.selectedItems.size === 0) return;

    const count = browserState.selectedItems.size;
    const confirmMessage = count === 1
        ? 'このアイテムを削除しますか？'
        : `${count}件のアイテムを削除しますか？`;

    if (!confirm(`${confirmMessage}\n\nこの操作は取り消せません。`)) {
        return;
    }

    const files = Array.from(browserState.selectedItems);
    showNotification(`${count}件を削除中...`);

    try {
        const result = await ipcRenderer.invoke('mtp-delete-files', {
            storageId: browserState.currentStorageId,
            files: files
        });

        if (result.error) {
            showNotification(`削除エラー: ${result.error}`);
        } else {
            showNotification(`${count}件を削除しました`);
            // ディレクトリを再読み込み
            await refresh();
        }
        hideNotification(3000);

    } catch (err) {
        showNotification(`エラー: ${err.message}`);
        hideNotification(3000);
    }
}
