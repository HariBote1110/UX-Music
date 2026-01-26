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
function updateGridStyle(newColumns) {
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

    // 既存のリサイザーをクリア
    headerContainer.querySelectorAll('.column-resizer').forEach(el => el.remove());
    
    const headers = Array.from(headerContainer.children);

    headers.forEach((header, index) => {
        // リサイズ可能なのはタイトル、アーティスト、アルバムの右境界線
        // インデックス 2, 3, 4 の要素にリサイザーを追加
        if (index < 2 || index > 4) return;

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

                if (newTargetWidth < 80 || newNextWidth < 80) return; // 最小幅制限

                const currentTemplate = window.getComputedStyle(headerContainer).gridTemplateColumns.split(' ');
                
                // 変更前の2つのfr値の合計を取得
                const prevTargetFr = parseFloat(currentTemplate[index]);
                const prevNextFr = parseFloat(currentTemplate[index + 1]);
                const combinedFr = prevTargetFr + prevNextFr;

                // 2つのセルの合計幅(px)を基準に新しい比率を計算
                const combinedWidth = targetStartWidth + nextStartWidth;
                const newTargetFr = (newTargetWidth / combinedWidth) * combinedFr;
                const newNextFr = (newNextWidth / combinedWidth) * combinedFr;
                
                currentTemplate[index] = `${newTargetFr.toFixed(4)}fr`;
                currentTemplate[index + 1] = `${newNextFr.toFixed(4)}fr`;
                
                updateGridStyle(currentTemplate.join(' '));
            };

            const onMouseUp = () => {
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
            };

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        };

        resizer.addEventListener('mousedown', onMouseDown);
    });
}