const STYLE_ID = 'dynamic-grid-styles';

function getOrCreateStyleElement() {
    let styleEl = document.getElementById(STYLE_ID);
    if (!styleEl) {
        styleEl = document.createElement('style');
        styleEl.id = STYLE_ID;
        document.head.appendChild(styleEl);
    }
    return styleEl;
}

/**
 * 曲リスト全体のCSS Gridスタイルを動的に更新する
 * @param {string} newColumns - 新しいgrid-template-columnsの値
 */
export function updateGridStyle(newColumns) {
    const styleEl = getOrCreateStyleElement();
    styleEl.textContent = `
        #music-list-header,
        #music-list .song-item,
        #a-detail-list .song-item,
        #p-detail-list .song-item,
        .track-list-container .song-item {
            grid-template-columns: ${newColumns};
        }
    `;
}

/**
 * 指定されたヘッダー要素にリサイズ機能を追加する
 * @param {HTMLElement} headerContainer - #music-list-header要素
 */
export function initColumnResizing(headerContainer) {
    if (!headerContainer) return;

    // 既存のリサイザーをクリア
    headerContainer.querySelectorAll('.column-resizer').forEach(el => el.remove());

    const headers = Array.from(headerContainer.children);

    headers.forEach((header, index) => {
        // 最後の列にはリサイザーを追加しない
        if (index >= headers.length - 1) return;

        const resizer = document.createElement('div');
        resizer.className = 'column-resizer';
        header.appendChild(resizer);

        let isDragging = false;
        let startX = 0;
        let targetStartWidth = 0;
        let nextStartWidth = 0;

        let lastSetTemplate = null; // mousemoveで設定したfrベースの値を記憶

        const onMouseMove = (moveEvent) => {
            if (!isDragging) return;
            const deltaX = moveEvent.clientX - startX;

            const newTargetWidth = targetStartWidth + deltaX;
            const newNextWidth = nextStartWidth - deltaX;

            if (newTargetWidth < 40 || newNextWidth < 40) return; // 最小幅制限

            const currentTemplate = window.getComputedStyle(headerContainer).gridTemplateColumns.split(' ');

            const currentTargetStr = currentTemplate[index] || '';
            const currentNextStr = currentTemplate[index + 1] || '';
            const isFrTarget = currentTargetStr.endsWith('fr');
            const isFrNext = currentNextStr.endsWith('fr');

            if (isFrTarget && isFrNext) {
                // 両方 fr の場合は比率を保ちながら変更（レスポンシブ維持のためfrで保存）
                const prevTargetFr = parseFloat(currentTargetStr);
                const prevNextFr = parseFloat(currentNextStr);
                const combinedFr = prevTargetFr + prevNextFr;
                const combinedWidth = targetStartWidth + nextStartWidth;
                if (combinedWidth <= 0) return;
                const newTargetFr = (newTargetWidth / combinedWidth) * combinedFr;
                const newNextFr = (newNextWidth / combinedWidth) * combinedFr;
                currentTemplate[index] = `${newTargetFr.toFixed(4)}fr`;
                currentTemplate[index + 1] = `${newNextFr.toFixed(4)}fr`;
            } else {
                // px の場合はそのまま px で更新
                currentTemplate[index] = `${newTargetWidth}px`;
                currentTemplate[index + 1] = `${newNextWidth}px`;
            }

            lastSetTemplate = currentTemplate; // frベースの値を記憶
            updateGridStyle(currentTemplate.join(' '));
        };

        const onMouseUp = () => {
            if (!isDragging) return;
            isDragging = false;
            document.removeEventListener('mousemove', onMouseMove);
            document.removeEventListener('mouseup', onMouseUp);
            document.body.style.cursor = '';
            document.body.style.userSelect = '';

            // getComputedStyle(px絶対値)ではなくmousemove中に計算したfr値を保存
            if (lastSetTemplate) {
                import('./column-config.js').then(mod => {
                    mod.updateVisibleColumnWidths(lastSetTemplate);
                });
                lastSetTemplate = null;
            }
        };

        resizer.addEventListener('mousedown', (e) => {
            e.preventDefault();
            e.stopPropagation();

            const targetHeader = headers[index];
            const nextHeader = headers[index + 1];
            if (!targetHeader || !nextHeader) return;

            isDragging = true;
            startX = e.clientX;
            targetStartWidth = targetHeader.offsetWidth;
            nextStartWidth = nextHeader.offsetWidth;

            // ドラッグ中のテキスト選択を防ぐ
            document.body.style.cursor = 'col-resize';
            document.body.style.userSelect = 'none';

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        });
    });
}