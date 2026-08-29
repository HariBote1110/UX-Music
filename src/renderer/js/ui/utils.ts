import { state } from '../core/state.js';
import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';
// ▲▲▲ 追加 ▲▲▲

export const EQUALIZER_COLOURS_CHANGE_EVENT = 'equalizer-colours-change';

function notifyEqualizerColoursChanged() {
    if (typeof window === 'undefined' || typeof window.dispatchEvent !== 'function') return;
    const event = typeof CustomEvent === 'function'
        ? new CustomEvent(EQUALIZER_COLOURS_CHANGE_EVENT)
        : new Event(EQUALIZER_COLOURS_CHANGE_EVENT);
    window.dispatchEvent(event);
}

/**
 * Resolves the path to an artwork image. This is the single source of truth.
 * @param {object|string|null} artwork - The artwork data from a song or album object.
 * @param {boolean} [isThumbnail=false] - Whether to resolve the thumbnail version.
 * @returns {string} - The URL or path to the artwork image.
 */
export function resolveArtworkPath(artwork, isThumbnail = false) {
    if (!artwork) return DEFAULT_ARTWORK_URL;

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
    return DEFAULT_ARTWORK_URL;
}

/**
 * HTML文字列をエスケープしてXSSを防ぐ
 * @param {string|number} str - エスケープする文字列
 * @returns {string} - エスケープされた文字列
 */
export function escapeHtml(str) {
    if (typeof str !== 'string') str = String(str || '');
    if (!str) return '';
    return str
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


export type ContextMenuItem = {
    label?: string;
    type?: 'separator';
    action?: () => void;
    enabled?: boolean;
    submenu?: ContextMenuItem[];
    /** true の場合、先頭スロットにチェックアイコンを表示する。 */
    checked?: boolean;
    /** 先頭スロットに表示するアイコン。組み込みアイコン名、または生の inline SVG 文字列。 */
    icon?: string;
    /** true の場合、区切り線として描画する（`type: 'separator'` と同義）。 */
    separator?: boolean;
    /** true の場合、無効化して描画する（`enabled: false` と同義）。 */
    disabled?: boolean;
    /** 末尾スロットに表示するショートカットキーの表示文字列。 */
    shortcut?: string;
    /** true の場合、危険な操作として強調表示する（削除など）。 */
    danger?: boolean;
};

/** サブメニューを閉じるまでの遅延時間 (ms)。親項目とサブメニューの間の隙間を
 * ポインタが横切る間に mouseleave で即座に閉じてしまわないようにするための猶予。 */
export const SUBMENU_CLOSE_DELAY_MS = 150;

const CHECK_ICON_SVG = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 8.5 6.5 12 13 4"></polyline></svg>';

const CHEVRON_ICON_SVG = '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 3 11 8 6 13"></polyline></svg>';

/** よく使う操作向けの組み込みアイコン。`icon` にキー名を指定すると使われる。
 * キーに一致しない場合は、値をそのまま inline SVG 文字列として扱う。 */
const BUILTIN_ICONS: Record<string, string> = {
    play: '<svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden="true"><path d="M4 2.5v11l9-5.5-9-5.5z"></path></svg>',
    'queue-add': '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><line x1="1.5" y1="4" x2="10.5" y2="4"></line><line x1="1.5" y1="8" x2="10.5" y2="8"></line><line x1="1.5" y1="12" x2="7" y2="12"></line><line x1="12" y1="9" x2="12" y2="15"></line><line x1="9" y1="12" x2="15" y2="12"></line></svg>',
    'playlist-add': '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><line x1="1.5" y1="3" x2="10.5" y2="3"></line><line x1="1.5" y1="7" x2="10.5" y2="7"></line><line x1="1.5" y1="11" x2="7" y2="11"></line><circle cx="12" cy="12" r="3.2"></circle><line x1="12" y1="10.6" x2="12" y2="13.4"></line><line x1="10.6" y1="12" x2="13.4" y2="12"></line></svg>',
    delete: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="2.5 4 3.5 4 13.5 4"></polyline><path d="M5.5 4V2.5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1V4"></path><path d="M4.5 4l0.6 9a1 1 0 0 0 1 0.9h4a1 1 0 0 0 1-0.9l0.6-9"></path></svg>',
    info: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><circle cx="8" cy="8" r="6.5"></circle><line x1="8" y1="7" x2="8" y2="11.5"></line><circle cx="8" cy="4.7" r="0.4" fill="currentColor" stroke="none"></circle></svg>',
    download: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="8" y1="1.5" x2="8" y2="10"></line><polyline points="4.5 7 8 10.5 11.5 7"></polyline><line x1="2" y1="13.5" x2="14" y2="13.5"></line></svg>',
};

let activeMenuCleanup: (() => void) | null = null;

export function removeContextMenu() {
    const existingMenu = document.querySelector('.context-menu');
    if (existingMenu) {
        existingMenu.remove();
    }
    if (activeMenuCleanup) {
        activeMenuCleanup();
        activeMenuCleanup = null;
    }
}

/**
 * サブメニューをビューポート内に収めるための配置を計算する（純粋関数、DOM に依存しない）。
 * @param parentRect - 親項目（サブメニューの起点となる項目）の矩形。
 * @param submenuSize - サブメニュー自体の幅・高さ。
 * @param viewport - ビューポートの幅・高さ。
 * @param margin - ビューポート端からの最小余白。
 */
export function computeSubmenuPlacement(
    parentRect: { left: number; right: number; top: number },
    submenuSize: { width: number; height: number },
    viewport: { width: number; height: number },
    margin = 8,
): { side: 'right' | 'left'; topOffset: number } {
    const overflowsRight = parentRect.right + submenuSize.width > viewport.width - margin;
    const side: 'right' | 'left' = overflowsRight ? 'left' : 'right';

    const overflowY = parentRect.top + submenuSize.height - viewport.height + margin;
    const topOffset = overflowY > 0 ? -overflowY : 0;

    return { side, topOffset };
}

function resolveIconMarkup(icon: string): string {
    return BUILTIN_ICONS[icon] ?? icon;
}

export function buildMenuElement(items: ContextMenuItem[], isSubmenu = false): HTMLElement {
    const menu = document.createElement('div');
    menu.className = isSubmenu ? 'context-menu context-menu--submenu' : 'context-menu';

    items.forEach(item => {
        if (item.type === 'separator' || item.separator) {
            const sep = document.createElement('div');
            sep.className = 'context-menu-separator';
            menu.appendChild(sep);
            return;
        }

        const isDisabled = item.enabled === false || item.disabled === true;

        const menuItem = document.createElement('div');
        menuItem.className = 'context-menu-item';
        if (isDisabled) {
            menuItem.classList.add('disabled');
        }
        if (item.danger) {
            menuItem.classList.add('danger');
        }

        // 先頭スロット（チェック/アイコン用）。checked/icon の有無に関わらず常に描画し、
        // ラベルの開始位置が項目間で揃うようにする。
        const leading = document.createElement('span');
        leading.className = 'context-menu-item__leading';
        if (item.checked) {
            leading.innerHTML = CHECK_ICON_SVG;
        } else if (item.icon) {
            leading.innerHTML = resolveIconMarkup(item.icon);
        }
        menuItem.appendChild(leading);

        const label = document.createElement('span');
        label.className = 'context-menu-item__label';
        label.textContent = item.label ?? '';
        menuItem.appendChild(label);

        if (item.submenu) {
            menuItem.classList.add('has-submenu');
            const arrow = document.createElement('span');
            arrow.className = 'context-menu-item__arrow';
            arrow.innerHTML = CHEVRON_ICON_SVG;
            menuItem.appendChild(arrow);

            const submenu = buildMenuElement(item.submenu, true);
            submenu.style.display = 'none';
            menuItem.appendChild(submenu);

            let closeTimer: ReturnType<typeof setTimeout> | null = null;
            const cancelClose = () => {
                if (closeTimer !== null) {
                    clearTimeout(closeTimer);
                    closeTimer = null;
                }
            };
            const scheduleClose = () => {
                cancelClose();
                closeTimer = setTimeout(() => {
                    submenu.style.display = 'none';
                    closeTimer = null;
                }, SUBMENU_CLOSE_DELAY_MS);
            };
            const openSubmenu = () => {
                if (isDisabled) return;
                cancelClose();
                // サブメニューを一時的に表示してサイズを測定
                submenu.style.visibility = 'hidden';
                submenu.style.display = 'block';
                const parentRect = menuItem.getBoundingClientRect();
                const submenuRect = submenu.getBoundingClientRect();
                const placement = computeSubmenuPlacement(
                    parentRect,
                    { width: submenuRect.width, height: submenuRect.height },
                    { width: window.innerWidth, height: window.innerHeight },
                );

                if (placement.side === 'left') {
                    submenu.style.left = 'auto';
                    submenu.style.right = '100%';
                } else {
                    submenu.style.left = '100%';
                    submenu.style.right = 'auto';
                }
                submenu.style.top = placement.topOffset ? `${placement.topOffset}px` : '0';

                submenu.style.visibility = '';
            };

            menuItem.addEventListener('mouseenter', openSubmenu);
            menuItem.addEventListener('mouseleave', scheduleClose);
            // サブメニュー自体にポインタが入った場合はクローズをキャンセルし、
            // 出た場合は改めてクローズを予約する（親項目との隙間をブリッジする）。
            submenu.addEventListener('mouseenter', cancelClose);
            submenu.addEventListener('mouseleave', scheduleClose);

        } else {
            if (item.shortcut) {
                const shortcut = document.createElement('span');
                shortcut.className = 'context-menu-item__shortcut';
                shortcut.textContent = item.shortcut;
                menuItem.appendChild(shortcut);
            }
            if (item.action && !isDisabled) {
                menuItem.addEventListener('click', (e) => {
                    e.stopPropagation();
                    removeContextMenu();
                    item.action!();
                });
            }
        }

        menu.appendChild(menuItem);
    });

    return menu;
}

export type ShowContextMenuOptions = {
    /**
     * true の場合、メニューと無関係な要素のスクロールでもメニューを閉じる（既定値: true）。
     * メニューは position: fixed でビューポートに固定されるため本来スクロール追従は不要だが、
     * 曲リストなどでは「スクロールしたら一覧の文脈が変わったのでメニューを閉じる」という
     * 既存の挙動を維持するために既定で有効にしている。
     * サイドカーメニューのように、他の場所のスクロールと無関係に開いたままにしたい
     * 呼び出し元は false を指定すること。
     */
    closeOnScroll?: boolean;
};

export function showContextMenu(
    x: number,
    y: number,
    items: ContextMenuItem[],
    options: ShowContextMenuOptions = {},
) {
    removeContextMenu();

    const { closeOnScroll = true } = options;

    const menu = buildMenuElement(items);
    // 一時的に非表示でDOMに追加してサイズを計測
    menu.style.visibility = 'hidden';
    document.body.appendChild(menu);

    const rect = menu.getBoundingClientRect();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const clampedX = Math.min(x, vw - rect.width - 8);
    const clampedY = Math.min(y, vh - rect.height - 8);

    menu.style.left = `${Math.max(8, clampedX)}px`;
    menu.style.top = `${Math.max(8, clampedY)}px`;
    menu.style.visibility = '';

    // 矢印キーでの簡易ナビゲーション（トップレベル項目間の移動のみ、サブメニューへの
    // キーボード侵入は対象外としてスコープを抑える）。
    const focusableItems = Array.from(
        menu.querySelectorAll(':scope > .context-menu-item:not(.disabled)'),
    ) as HTMLElement[];
    let focusedIndex = -1;
    const setFocusedIndex = (index: number) => {
        if (focusedIndex >= 0) {
            focusableItems[focusedIndex]?.classList.remove('context-menu-item--focused');
        }
        focusedIndex = index;
        if (focusedIndex >= 0) {
            focusableItems[focusedIndex]?.classList.add('context-menu-item--focused');
        }
    };

    const onKeydown = (e: KeyboardEvent) => {
        if (e.key === 'Escape') {
            removeContextMenu();
            return;
        }
        if (focusableItems.length === 0) return;
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            setFocusedIndex((focusedIndex + 1) % focusableItems.length);
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            setFocusedIndex((focusedIndex - 1 + focusableItems.length) % focusableItems.length);
        } else if (e.key === 'Enter' && focusedIndex >= 0) {
            e.preventDefault();
            focusableItems[focusedIndex].click();
        }
    };
    const onScroll = () => removeContextMenu();
    const onPointerDown = (e: PointerEvent) => {
        if (!menu.contains(e.target as Node)) removeContextMenu();
    };
    const onContextMenu = (e: MouseEvent) => {
        if (!menu.contains(e.target as Node)) removeContextMenu();
    };

    // 現フレームのイベントが終わってから登録（開いた右クリック自体で即閉じないように）
    requestAnimationFrame(() => {
        document.addEventListener('keydown', onKeydown);
        document.addEventListener('pointerdown', onPointerDown, { capture: true });
        document.addEventListener('contextmenu', onContextMenu);
        if (closeOnScroll) {
            document.addEventListener('scroll', onScroll, { capture: true, passive: true });
        }
    });

    activeMenuCleanup = () => {
        document.removeEventListener('keydown', onKeydown);
        document.removeEventListener('pointerdown', onPointerDown, { capture: true });
        document.removeEventListener('contextmenu', onContextMenu);
        if (closeOnScroll) {
            document.removeEventListener('scroll', onScroll, { capture: true });
        }
    };
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
    notifyEqualizerColoursChanged();
}
// ▲▲▲ 追加 ▲▲▲
