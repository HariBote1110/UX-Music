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
 * 曲リスト全体のCSSを動的に更新する
 * @param {string} newColumns - 新しいgrid-template-columnsの値
 */
function updateGridStyle(newColumns) {
    const styleEl = getOrCreateStyleElement();
    // ヘッダーと、すべてのビューの曲アイテムにスタイルが適用されるようにセレクタを指定
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
    const headers = headerContainer.querySelectorAll(':scope > div');
    
    headers.forEach((header, index) => {
        // 最後の列にはリサイザーは不要
        if (index >= headers.length - 1) return;

        const resizer = document.createElement('div');
        resizer.className = 'column-resizer';
        header.appendChild(resizer);

        const onMouseDown = (e) => {
            e.preventDefault();
            e.stopPropagation();

            const startX = e.clientX;
            // ドラッグ開始時の全列の幅をピクセル単位で取得
            const startWidths = Array.from(headers).map(h => h.offsetWidth);

            const onMouseMove = (moveEvent) => {
                const deltaX = moveEvent.clientX - startX;
                
                const newCurrentWidth = startWidths[index] + deltaX;
                const newNextWidth = startWidths[index + 1] - deltaX;
                
                // 列が小さくなりすぎないように最小幅を50pxに制限
                if (newCurrentWidth < 50 || newNextWidth < 50) return;

                // 新しい列幅の配列を作成
                const newGridTemplate = startWidths.map((width, i) => {
                    if (i === index) return `${newCurrentWidth}px`;
                    if (i === index + 1) return `${newNextWidth}px`;
                    return `${width}px`;
                }).join(' ');
                
                // ヘッダーのスタイルを直接更新して、ドラッグ中の見た目をスムーズに
                headerContainer.style.gridTemplateColumns = newGridTemplate;
                // 全ての曲アイテムに適用される動的スタイルシートを更新
                updateGridStyle(newGridTemplate);
            };

            const onMouseUp = () => {
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
                // ここでipcRenderer.sendを使って新しい列幅を保存する処理を追加可能
            };

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        };

        resizer.addEventListener('mousedown', onMouseDown);
    });
}