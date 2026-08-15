import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { removeContextMenu, showContextMenu } from './utils.js';

/**
 * showContextMenu の「意図しないタイミングでメニューが閉じる」問題を検証するテスト。
 *
 * メニュー要素は CSS 上 position: fixed のためビューポート内で常に同じ位置に留まり、
 * どこかがスクロールしても本来は表示位置を追従させる必要がない。にもかかわらず
 * 既存実装は document 全体を capture フェーズで監視する 'scroll' リスナーを持ち、
 * メニューと無関係な要素のスクロールでも即座にメニューを閉じてしまっていた。
 */
describe('showContextMenu の意図しない dismiss', () => {
    beforeEach(() => {
        document.body.innerHTML = '';
    });

    afterEach(() => {
        removeContextMenu();
        document.body.innerHTML = '';
    });

    async function flushOpenFrame() {
        // showContextMenu はメニューを開いた直後のフレームで dismiss リスナーを登録するため、
        // rAF を一度進めてリスナー登録後の状態にする。
        await new Promise((resolve) => requestAnimationFrame(resolve));
    }

    it('デフォルト動作: 無関係な要素のスクロールでメニューが閉じる（既存の song list などの挙動を維持）', async () => {
        showContextMenu(10, 10, [{ label: 'テスト項目', action: () => {} }]);
        await flushOpenFrame();

        expect(document.querySelector('.context-menu')).not.toBeNull();

        const unrelated = document.createElement('div');
        document.body.appendChild(unrelated);
        unrelated.dispatchEvent(new Event('scroll', { bubbles: true }));

        expect(document.querySelector('.context-menu')).toBeNull();
    });

    it('closeOnScroll: false を指定すると、無関係な要素のスクロールではメニューが閉じない', async () => {
        showContextMenu(10, 10, [{ label: 'テスト項目', action: () => {} }], { closeOnScroll: false });
        await flushOpenFrame();

        expect(document.querySelector('.context-menu')).not.toBeNull();

        const unrelated = document.createElement('div');
        document.body.appendChild(unrelated);
        unrelated.dispatchEvent(new Event('scroll', { bubbles: true }));

        expect(document.querySelector('.context-menu')).not.toBeNull();
    });

    it('closeOnScroll: false でも Escape キーや外側クリックでは閉じる', async () => {
        showContextMenu(10, 10, [{ label: 'テスト項目', action: () => {} }], { closeOnScroll: false });
        await flushOpenFrame();

        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));

        expect(document.querySelector('.context-menu')).toBeNull();
    });
});
