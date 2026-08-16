import { describe, expect, it } from 'vitest';
import { getNormalizeViewHtml } from './normalize-view-html.js';

// normalize-view.ts が document.getElementById() で実際に引く要素 ID の全列挙。
// normalize-view-html.ts が公開する定数を輸入すると「同じファイル同士が一致する」
// ことしか示せないため、消費側（normalize-view.ts）の参照をここへ写し取る。
// 重複しているのは意図的で、HTML が消費側の必要とする ID を落としたら
// このテストが落ちるのが狙い。
// 内訳:
//  - 直接の getElementById(...) リテラル 14 件
//  - bind(id, ...) ヘルパー経由（内部で getElementById する）4 件
const IDS_LOOKED_UP_BY_NORMALIZE_VIEW = [
    // 直接 getElementById するもの
    'normalize-file-list',
    'normalize-select-all',
    'normalize-analyze-btn',
    'normalize-apply-btn',
    'target-lufs-slider',
    'target-lufs-value',
    'normalize-progress-bar',
    'normalize-progress-label',
    'normalize-progress-container',
    'normalize-drop-zone',
    'output-folder-container',
    'output-folder-path',
    'backup-container',
    'backup-toggle',
    // bind() ヘルパー経由で getElementById するもの
    'normalize-add-files-btn',
    'normalize-add-folder-btn',
    'normalize-load-library-btn',
    'select-output-folder-btn',
];

describe('getNormalizeViewHtml', () => {
    it('normalize-view.ts が参照する要素 ID をすべて含む', () => {
        // ループが空回りして無条件に通ることを防ぐガード
        expect(IDS_LOOKED_UP_BY_NORMALIZE_VIEW.length).toBe(18);

        const html = getNormalizeViewHtml();
        for (const id of IDS_LOOKED_UP_BY_NORMALIZE_VIEW) {
            expect(html).toContain(`id="${id}"`);
        }
    });

    it('ID の列挙に重複がない', () => {
        const unique = new Set(IDS_LOOKED_UP_BY_NORMALIZE_VIEW);
        expect(unique.size).toBe(IDS_LOOKED_UP_BY_NORMALIZE_VIEW.length);
    });
});
