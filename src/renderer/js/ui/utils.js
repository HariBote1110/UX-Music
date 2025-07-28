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
        if (item.action) {
            menuItem.onclick = () => {
                item.action();
                removeContextMenu();
            };
        }
        menu.appendChild(menuItem);
    });

    document.body.appendChild(menu);
    document.addEventListener('click', removeContextMenu, { once: true });
}

/**
 * 表示されているコンテキストメニューを削除する
 */
function removeContextMenu() {
    const existingMenu = document.querySelector('.context-menu');
    if (existingMenu) {
        existingMenu.remove();
    }
}