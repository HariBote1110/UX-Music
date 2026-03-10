const STYLE_ID = 'dynamic-grid-styles';

// モジュールレベルで「最後に設定したテンプレート文字列」を保持
// これにより getComputedStyle (px変換) を使わずに済む
let _currentTemplate = null;

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
    _currentTemplate = newColumns; // fr値のままキャッシュ
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
        let dragTemplate = null; // ドラッグ中の現在テンプレート(fr値)

        const onMouseMove = (moveEvent) => {
            if (!isDragging) return;
            const deltaX = moveEvent.clientX - startX;

            const newTargetWidth = targetStartWidth + deltaX;
            const newNextWidth = nextStartWidth - deltaX;

            if (newTargetWidth < 40 || newNextWidth < 40) return;

            // getComputedStyle は使わず、モジュールキャッシュ(_currentTemplate)を使う
            const templateStr = dragTemplate || _currentTemplate;
            if (!templateStr) return;

            const cols = templateStr.split(' ');
            if (index >= cols.length - 1) return;

            const targetStr = cols[index];
            const nextStr = cols[index + 1];
            const isFrTarget = targetStr.endsWith('fr');
            const isFrNext = nextStr.endsWith('fr');

            const newCols = [...cols];

            if (isFrTarget && isFrNext) {
                // fr同士: 合計frを保ちながら比率を変更
                const prevTargetFr = parseFloat(targetStr);
                const prevNextFr = parseFloat(nextStr);
                const combinedFr = prevTargetFr + prevNextFr;
                const combinedWidth = targetStartWidth + nextStartWidth;
                if (combinedWidth <= 0) return;
                const newTargetFr = (newTargetWidth / combinedWidth) * combinedFr;
                const newNextFr = (newNextWidth / combinedWidth) * combinedFr;
                newCols[index] = `${newTargetFr.toFixed(4)}fr`;
                newCols[index + 1] = `${newNextFr.toFixed(4)}fr`;
            } else {
                newCols[index] = `${newTargetWidth}px`;
                newCols[index + 1] = `${newNextWidth}px`;
            }

            dragTemplate = newCols.join(' ');
            updateGridStyle(dragTemplate);
        };

        const onMouseUp = () => {
            if (!isDragging) return;
            isDragging = false;
            document.removeEventListener('mousemove', onMouseMove);
            document.removeEventListener('mouseup', onMouseUp);
            document.body.style.cursor = '';
            document.body.style.userSelect = '';

            // fr値のままcolumn-configに保存（getComputedStyleは使用しない）
            if (dragTemplate) {
                const finalTemplateParts = dragTemplate.split(' ');
                import('./column-config.js').then(mod => {
                    mod.updateVisibleColumnWidths(finalTemplateParts);
                });
            }
            dragTemplate = null;
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
            dragTemplate = null; // リセット（_currentTemplateを使う）

            document.body.style.cursor = 'col-resize';
            document.body.style.userSelect = 'none';

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        });
    });
}