const electronAPI = window.electronAPI;
import { state } from '../core/state.js';
// ▲▲▲ 追加 ▲▲▲

/**
 * Resolves the path to an artwork image. This is the single source of truth.
 * @param {object|string|null} artwork - The artwork data from a song or album object.
 * @param {boolean} [isThumbnail=false] - Whether to resolve the thumbnail version.
 * @returns {string} - The URL or path to the artwork image.
 */
export function resolveArtworkPath(artwork, isThumbnail = false) {
    // Light Flight Mode が有効な場合は、アートワークの読み込みを完全に停止する
    if (state.isLightFlightMode) return './assets/default_artwork.png';

    if (!artwork) return './assets/default_artwork.png';

    // Handle external URLs (http, data URIs)
    if (typeof artwork === 'string' && (artwork.startsWith('http') || artwork.startsWith('data:'))) {
        return artwork;
    }

    // Handle the standard artwork object { full, thumbnail }
    if (typeof artwork === 'object' && artwork.full && artwork.thumbnail) {
        const fileName = isThumbnail ? artwork.thumbnail : artwork.full;
        const subDir = isThumbnail ? 'thumbnails' : '';
        const safePath = (subDir ? subDir + '/' : '') + fileName.replace(/\\/g, '/');
        const url = `safe-artwork://${safePath}`;
        return window.go !== undefined ? url.replace('safe-artwork://', '/safe-artwork/') : url;
    }

    // Fallback for legacy string-based artwork data
    if (typeof artwork === 'string') {
        const safePath = artwork.replace(/\\/g, '/');
        const url = `safe-artwork://${safePath}`;
        return window.go !== undefined ? url.replace('safe-artwork://', '/safe-artwork/') : url;
    }

    console.warn('Unknown artwork format received, using default.', artwork);
    return './assets/default_artwork.png';
}

/**
 * HTML文字列のエスケープ処理
 * @param {string} str - エスケープする文字列
 * @returns {string} - エスケープされた文字列
 */
export function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

/**
 * 要素内のテキストがはみ出しているかをチェックし、アニメーション用の設定を行う
 * @param {HTMLElement} wrapper - .marquee-wrapper 要素
 */
export function checkTextOverflow(wrapper) {
    if (!wrapper) return;

    const content = wrapper.querySelector('.marquee-content');
    if (!content) {
        return;
    }
    const span = content.querySelector('span');
    if (!span) return;

    // 元の状態に戻す
    wrapper.classList.remove('is-overflowing');
    const duplicates = content.querySelectorAll('span[aria-hidden="true"]');
    duplicates.forEach(d => d.remove());

    const isOverflowing = span.scrollWidth > wrapper.clientWidth;

    if (isOverflowing) {
        wrapper.classList.add('is-overflowing');
        // アニメーション用にテキストを複製
        const duplicate = span.cloneNode(true);
        duplicate.setAttribute('aria-hidden', 'true');
        content.appendChild(duplicate);
    }
}


/**
 * 指定されたセレクターに一致する全ての要素に対して、テキストオーバーフローのチェックを行う
 * @param {string} selector - 対象要素のCSSセレクター
 */
export function updateTextOverflowForSelector(selector) {
    requestAnimationFrame(() => {
        document.querySelectorAll(selector).forEach(checkTextOverflow);
    });
}


/**
 * 秒数を mm:ss 形式の文字列に変換する
 * @param {number} seconds - 秒数
 * @returns {string} - フォーマットされた時間文字列
 */
export function formatTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '0:00';
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}

/**
 * ファイル拡張子が含まれている可能性のある曲名を整形する
 * @param {string} title - 曲名
 * @returns {string} - 拡張子が削除された曲名
 */
const supportedExtensions = ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.mp4'];
export function formatSongTitle(title) {
    if (typeof title !== 'string') return 'Unknown Title';
    const lastDotIndex = title.lastIndexOf('.');
    // ドットがないか、先頭にある場合はファイル名ではないと判断
    if (lastDotIndex <= 0) {
        return title;
    }
    const extension = title.substring(lastDotIndex).toLowerCase();
    if (supportedExtensions.includes(extension)) {
        return title.substring(0, lastDotIndex);
    }
    return title;
}


/**
 * 指定した位置にコンテキストメニューを表示する
 * @param {number} x - X座標
 * @param {number} y - Y座標
 * @param {Array<object>} items - メニューアイテムの配列
 */
export function showContextMenu(x, y, items) {
    removeContextMenu();
    const menu = document.createElement('div');
    menu.className = 'context-menu';
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;

    items.forEach(item => {
        const menuItem = document.createElement('div');
        menuItem.className = 'context-menu-item';
        menuItem.textContent = item.label;

        if (item.submenu) {
            menuItem.classList.add('has-submenu');
            const submenu = document.createElement('div');
            submenu.className = 'context-menu-submenu';
            item.submenu.forEach(subItem => {
                const subMenuItem = document.createElement('div');
                subMenuItem.className = 'context-menu-item';
                subMenuItem.textContent = subItem.label;
                if (subItem.enabled === false) {
                    subMenuItem.classList.add('disabled');
                } else {
                    subMenuItem.addEventListener('click', (e) => {
                        e.stopPropagation();
                        if (subItem.action) {
                            subItem.action();
                        }
                        removeContextMenu();
                    });
                }
                submenu.appendChild(subMenuItem);
            });
            menuItem.appendChild(submenu);
        } else if (item.action) {
            menuItem.addEventListener('click', () => {
                item.action();
                removeContextMenu();
            });
        }

        menu.appendChild(menuItem);
    });

    document.body.appendChild(menu);

    // クリックでメニューを閉じる（次のフレームで登録して、現在のクリックイベントを無視）
    setTimeout(() => {
        const closeHandler = (e) => {
            // コンテキストメニュー内のクリックは無視
            if (menu.contains(e.target)) return;
            removeContextMenu();
            document.removeEventListener('click', closeHandler);
            document.removeEventListener('contextmenu', closeHandler);
        };
        document.addEventListener('click', closeHandler);
        document.addEventListener('contextmenu', closeHandler);
    }, 0);
}

/**
 * 表示されているコンテキストメニューを削除する
 */
function removeContextMenu() {
    const existingMenu = document.querySelector('.context-menu');
    if (existingMenu) {
        existingMenu.remove();
        const existingSubMenus = document.querySelectorAll('.context-menu-submenu');
        existingSubMenus.forEach(submenu => submenu.remove());
    }
}

/**
 * バイト数を適切な単位 (B, KB, MB, GB, TB) に変換する
 * @param {number} bytes - バイト数
 * @param {number} [decimals=2] - 小数点以下の桁数
 * @returns {string} - フォーマットされた文字列
 */
export function formatBytes(bytes, decimals = 2) {
    if (!bytes || bytes === 0) return '0 Bytes';
    if (isNaN(bytes) || bytes < 0) return 'N/A';

    const k = 1024;
    const dm = decimals < 0 ? 0 : decimals;
    const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];

    const i = Math.floor(Math.log(bytes) / Math.log(k));

    return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}


// ▼▼▼ 追加 (player.js から移動) ▼▼▼
/**
 * 画像要素から主要な2色を抽出する
 * @param {HTMLImageElement} img - 対象の画像要素
 * @returns {Promise<Array<string>|null>} [色1, 色2] の配列、または null
 */
async function getColorsFromArtwork(img) {
    // 画像がロード完了していない場合、待機する
    if (!img.complete || img.naturalWidth === 0) {
        await new Promise((resolve, reject) => {
            img.onload = resolve;
            img.onerror = reject;
        }).catch(e => {
            console.error("Image loading error for color extraction:", e);
            return null;
        });
        if (!img.complete) return null;
    }

    return new Promise((resolve) => {
        const canvas = document.createElement('canvas');
        const context = canvas.getContext('2d', { willReadFrequently: true });
        const width = canvas.width = img.naturalWidth || img.width;
        const height = canvas.height = img.naturalHeight || img.height;
        try {
            context.drawImage(img, 0, 0);
            const imageData = context.getImageData(0, 0, width, height);
            const data = imageData.data;
            const colorCount = {};
            // ピクセルをサンプリングするステップ（負荷軽減のため）
            const step = Math.max(4, Math.floor(data.length / (1000 * 4))) * 4;
            for (let i = 0; i < data.length; i += step) {
                // 色を量子化（丸める）してキーにする
                const r = Math.round(data[i] / 32) * 32;
                const g = Math.round(data[i + 1] / 32) * 32;
                const b = Math.round(data[i + 2] / 32) * 32;
                const key = `${r},${g},${b}`;
                colorCount[key] = (colorCount[key] || 0) + 1;
            }
            // 最も多く出現した色でソート
            const sortedColors = Object.keys(colorCount).sort((a, b) => colorCount[b] - colorCount[a]);

            if (sortedColors.length >= 2) {
                resolve([`rgb(${sortedColors[0]})`, `rgb(${sortedColors[1]})`]);
            } else if (sortedColors.length === 1) {
                resolve([`rgb(${sortedColors[0]})`, `rgb(${sortedColors[0]})`]);
            } else {
                resolve(null);
            }
        } catch (e) {
            console.error("Canvas color extraction failed (maybe CORS issue?):", e, img.src);
            resolve(null);
        }
    });
}

/**
 * アートワーク画像からイコライザーのグラデーション色を設定する
 * @param {HTMLImageElement} imageElement - アートワークを表示する画像要素
 */
export async function setEqualizerColorFromArtwork(imageElement) {
    const setDefaultColors = () => {
        document.documentElement.style.setProperty('--eq-color-1', 'var(--highlight-pink)');
        document.documentElement.style.setProperty('--eq-color-2', 'var(--highlight-blue)');
    };

    // ライトフライトモードでは色を変更しない
    if (state.isLightFlightMode) {
        setDefaultColors();
        return;
    }

    if (imageElement && imageElement.src && !imageElement.src.endsWith('default_artwork.png')) {
        // CORS対応
        if (!imageElement.crossOrigin) imageElement.crossOrigin = "Anonymous";
        const colors = await getColorsFromArtwork(imageElement);
        if (colors) {
            document.documentElement.style.setProperty('--eq-color-1', colors[0]);
            document.documentElement.style.setProperty('--eq-color-2', colors[1]);
        } else {
            setDefaultColors();
        }
    } else {
        setDefaultColors();
    }
}
// ▲▲▲ 追加 ▲▲▲