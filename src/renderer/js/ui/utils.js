// uxmusic/src/renderer/js/ui/utils.js
const path = require('path');

/**
 * Resolves the path to an artwork image. This is the single source of truth.
 * @param {object|string|null} artwork - The artwork data from a song or album object.
 * @param {boolean} [isThumbnail=false] - Whether to resolve the thumbnail version.
 * @returns {string} - The URL or path to the artwork image.
 */
export function resolveArtworkPath(artwork, isThumbnail = false) {
    if (!artwork) return './assets/default_artwork.png';

    // Handle external URLs (http, data URIs)
    if (typeof artwork === 'string' && (artwork.startsWith('http') || artwork.startsWith('data:'))) {
        return artwork;
    }
    
    // Handle the standard artwork object { full, thumbnail }
    if (typeof artwork === 'object' && artwork.full && artwork.thumbnail) {
        const fileName = isThumbnail ? artwork.thumbnail : artwork.full;
        const subDir = isThumbnail ? 'thumbnails' : '';
        const safePath = path.join(subDir, fileName).replace(/\\/g, '/');
        return `safe-artwork://${safePath}`;
    }
    
    // Fallback for legacy string-based artwork data
    if (typeof artwork === 'string') {
        const safePath = artwork.replace(/\\/g, '/');
        return `safe-artwork://${safePath}`;
    }
    
    console.warn('Unknown artwork format received, using default.', artwork);
    return './assets/default_artwork.png';
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
    document.addEventListener('click', removeContextMenu, { once: true });
    document.addEventListener('contextmenu', removeContextMenu, { once: true });
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