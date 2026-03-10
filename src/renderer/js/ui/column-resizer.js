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
        #p-detail-list .song-item {
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

    // column-config から可視列情報を取得
    let columnConfigModule = null;
    try {
        // 動的importの代わりにlazy参照
        columnConfigModule = null; // will be loaded on first resize
    } catch (e) { /* ignore */ }

    // 既存のリサイザーをクリア
    headerContainer.querySelectorAll('.column-resizer').forEach(el => el.remove());

    const headers = Array.from(headerContainer.children);

    headers.forEach((header, index) => {
        // 最後の列にはリサイザーを追加しない
        if (index >= headers.length - 1) return;

        // リサイズ対象は fr 値を持つ列のみ（固定幅 px の列はスキップ）
        const computedTemplate = window.getComputedStyle(headerContainer).gridTemplateColumns.split(' ');
        // 固定幅の列はリサイズ不要だが、可視列に応じて動的に判断
        // 最低限2列目以降でリサイズハンドルを設置
        if (index < 1) return;

        const resizer = document.createElement('div');
        resizer.className = 'column-resizer';
        header.appendChild(resizer);

        const onMouseDown = (e) => {
            e.preventDefault();
            e.stopPropagation();

            const startX = e.clientX;
            const targetHeader = headers[index];
            const nextHeader = headers[index + 1];

            if (!targetHeader || !nextHeader) return;

            const targetStartWidth = targetHeader.offsetWidth;
            const nextStartWidth = nextHeader.offsetWidth;

            const onMouseMove = (moveEvent) => {
                const deltaX = moveEvent.clientX - startX;

                const newTargetWidth = targetStartWidth + deltaX;
                const newNextWidth = nextStartWidth - deltaX;

                if (newTargetWidth < 80 || newNextWidth < 40) return; // 最小幅制限

                const currentTemplate = window.getComputedStyle(headerContainer).gridTemplateColumns.split(' ');

                // 変更前の2つの値の合計を取得
                const prevTargetVal = parseFloat(currentTemplate[index]);
                const prevNextVal = parseFloat(currentTemplate[index + 1]);

                // px 値の場合はそのまま px で更新
                const isPxTarget = currentTemplate[index].includes('px') || !currentTemplate[index].includes('fr');
                const isPxNext = currentTemplate[index + 1].includes('px') || !currentTemplate[index + 1].includes('fr');

                if (isPxTarget && isPxNext) {
                    // 両方 px の場合
                    currentTemplate[index] = `${newTargetWidth}px`;
                    currentTemplate[index + 1] = `${newNextWidth}px`;
                } else {
                    // fr 値の場合は比率を計算
                    const combinedFr = prevTargetVal + prevNextVal;
                    const combinedWidth = targetStartWidth + nextStartWidth;
                    const newTargetFr = (newTargetWidth / combinedWidth) * combinedFr;
                    const newNextFr = (newNextWidth / combinedWidth) * combinedFr;

                    currentTemplate[index] = `${newTargetFr.toFixed(4)}fr`;
                    currentTemplate[index + 1] = `${newNextFr.toFixed(4)}fr`;
                }

                updateGridStyle(currentTemplate.join(' '));
            };

            const onMouseUp = () => {
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);

                // リサイズ完了時に幅を column-config に保存
                const finalTemplate = window.getComputedStyle(headerContainer).gridTemplateColumns.split(' ');
                import('./column-config.js').then(mod => {
                    mod.updateVisibleColumnWidths(finalTemplate);
                });
            };

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        };

        resizer.addEventListener('mousedown', onMouseDown);
    });
}