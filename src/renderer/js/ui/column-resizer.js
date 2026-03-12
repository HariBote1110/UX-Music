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
 * list-sample.html スタイルの確実な mousedown→move→up パターンを採用。
 * isDragging フラグを廃止し、mousedown でリスナーを登録・mouseup で削除することで
 * 「最初の数px動かないと反応しない」問題を解消。
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

        resizer.addEventListener('mousedown', (e) => {
            e.preventDefault();
            e.stopPropagation();

            const targetHeader = headers[index];
            const nextHeader = headers[index + 1];
            if (!targetHeader || !nextHeader) return;

            // getBoundingClientRect() で実際の描画幅を正確に取得
            const startX = e.clientX;
            const targetStartWidth = targetHeader.getBoundingClientRect().width;
            const nextStartWidth = nextHeader.getBoundingClientRect().width;

            // ドラッグ開始時のテンプレートを確定して保持（_currentTemplate が途中で変わることを防ぐ）
            let dragTemplate = _currentTemplate;

            document.body.style.cursor = 'col-resize';
            document.body.style.userSelect = 'none';

            const onMouseMove = (moveEvent) => {
                const deltaX = moveEvent.clientX - startX;

                const newTargetWidth = targetStartWidth + deltaX;
                const newNextWidth = nextStartWidth - deltaX;

                if (newTargetWidth < 40 || newNextWidth < 40) return;

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
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
                document.body.style.cursor = '';
                document.body.style.userSelect = '';

                // fr値のままcolumn-configに保存（getComputedStyleは使用しない）
                if (dragTemplate && dragTemplate !== _currentTemplate) {
                    const finalTemplateParts = dragTemplate.split(' ');
                    import('./column-config.js').then(mod => {
                        mod.updateVisibleColumnWidths(finalTemplateParts);
                    });
                }
            };

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        });
    });
}