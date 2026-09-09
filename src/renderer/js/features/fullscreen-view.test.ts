import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';

// このファイルの位置を起点に実ソース／実スタイルを読む。
// fullscreen-view.ts は core/state.js 経由で Electron ブリッジ等の
// 重い依存を引き込むため import せず、テキストとして検証する
// （fullscreen-media.test.ts と同じ実マークアップ検証の方針）。
const moduleUrl = import.meta.url;
const readRepoFile = (relativePath: string): string =>
    readFileSync(fileURLToPath(new URL(relativePath, moduleUrl)), 'utf8');

const viewSource = readRepoFile('./fullscreen-view.ts');
const componentsCss = readRepoFile('../../styles/components.css');

/** 指定セレクタの最初の `{ ... }` ブロック本文を取り出す。 */
function extractRuleBody(css: string, selector: string): string {
    const escaped = selector.replace(/[.#]/g, '\\$&');
    const match = css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`));
    if (!match) throw new Error(`rule not found: ${selector}`);
    return match[1];
}

describe('フルスクリーンオーバーレイのウィンドウドラッグ帯', () => {
    it('オーバーレイのマークアップに fs-drag-region 要素を持つ', () => {
        expect(viewSource).toMatch(/id="fs-drag-region"/);
        expect(viewSource).toMatch(/class="fs-drag-region"/);
    });

    it('fs-drag-region は fs-close-btn より先に描画される（DOM順）', () => {
        const dragIndex = viewSource.indexOf('id="fs-drag-region"');
        const closeIndex = viewSource.indexOf('id="fs-close-btn"');
        expect(dragIndex).toBeGreaterThan(-1);
        expect(closeIndex).toBeGreaterThan(-1);
        expect(dragIndex).toBeLessThan(closeIndex);
    });

    it('.fs-drag-region は title-bar と同様に drag 指定を両方持つ', () => {
        const body = extractRuleBody(componentsCss, '.fs-drag-region');
        expect(body).toMatch(/-webkit-app-region:\s*drag/);
        expect(body).toMatch(/--wails-draggable:\s*drag/);
    });

    it('.fs-drag-region は上部の細い帯として絶対配置され、通常コンテンツより手前に重なる', () => {
        const body = extractRuleBody(componentsCss, '.fs-drag-region');
        expect(body).toMatch(/position:\s*absolute/);
        expect(body).toMatch(/top:\s*0/);

        const heightMatch = body.match(/height:\s*(\d+)px/);
        expect(heightMatch).not.toBeNull();
        const height = Number(heightMatch![1]);
        // タイトルバー（32px）程度に留め、歌詞・キュー・再生操作の
        // 表示領域を覆わないようにする。
        expect(height).toBeLessThanOrEqual(32);

        const zIndexMatch = body.match(/z-index:\s*(-?\d+)/);
        expect(zIndexMatch).not.toBeNull();
        const dragZIndex = Number(zIndexMatch![1]);

        const closeBody = extractRuleBody(componentsCss, '.fs-close-btn');
        const closeZIndexMatch = closeBody.match(/z-index:\s*(-?\d+)/);
        expect(closeZIndexMatch).not.toBeNull();
        const closeZIndex = Number(closeZIndexMatch![1]);

        // 閉じるボタンは重なっても手前に来て確実にクリックできること。
        expect(closeZIndex).toBeGreaterThan(dragZIndex);
    });

    it('.fs-close-btn はドラッグ帯と重なっても no-drag を明示している', () => {
        const body = extractRuleBody(componentsCss, '.fs-close-btn');
        expect(body).toMatch(/-webkit-app-region:\s*no-drag/);
        expect(body).toMatch(/--wails-draggable:\s*no-drag/);
    });
});
