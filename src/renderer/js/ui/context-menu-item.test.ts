// src/renderer/js/ui/context-menu-item.test.ts
/**
 * コンテキストメニューの新しい項目モデル（checked / icon / danger / disabled / shortcut）と
 * サブメニューのホバー挙動（クローズ遅延・ビューポート内クランプ）を検証するテスト。
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
    buildMenuElement,
    computeSubmenuPlacement,
    SUBMENU_CLOSE_DELAY_MS,
} from './utils.js';

describe('buildMenuElement のラベル整列', () => {
    it('checked の有無にかかわらず、先頭スロットが常に存在する', () => {
        const menu = buildMenuElement([
            { label: 'チェックあり', checked: true, action: () => {} },
            { label: 'チェックなし', checked: false, action: () => {} },
            { label: '指定なし', action: () => {} },
        ]);
        const items = menu.querySelectorAll('.context-menu-item');
        expect(items.length).toBe(3);
        items.forEach(item => {
            // 先頭スロットは常に最初の子要素として存在する
            const leading = item.querySelector(':scope > .context-menu-item__leading');
            expect(leading).not.toBeNull();
            expect(item.firstElementChild).toBe(leading);
        });
    });

    it('ラベル要素は状態に関わらず常に2番目の子要素になる（整列崩れ防止）', () => {
        const menu = buildMenuElement([
            { label: 'A', checked: true, action: () => {} },
            { label: 'B', action: () => {} },
        ]);
        const items = Array.from(menu.querySelectorAll('.context-menu-item'));
        items.forEach(item => {
            const label = item.querySelector('.context-menu-item__label');
            expect(item.children[1]).toBe(label);
        });
    });
});

describe('buildMenuElement の checked 表示', () => {
    it('checked: true のときチェックアイコン(SVG)を先頭スロットに描画する', () => {
        const menu = buildMenuElement([{ label: '項目', checked: true, action: () => {} }]);
        const leading = menu.querySelector('.context-menu-item__leading') as HTMLElement;
        expect(leading.innerHTML).toContain('<svg');
    });

    it('checked が未指定/false のとき先頭スロットは空のまま', () => {
        const menu = buildMenuElement([{ label: '項目', action: () => {} }]);
        const leading = menu.querySelector('.context-menu-item__leading') as HTMLElement;
        expect(leading.innerHTML.trim()).toBe('');
    });

    it('label にチェック文字("✓")や空白パディングを含めなくても良い', () => {
        const menu = buildMenuElement([{ label: '項目', checked: true, action: () => {} }]);
        const label = menu.querySelector('.context-menu-item__label') as HTMLElement;
        expect(label.textContent).toBe('項目');
    });
});

describe('buildMenuElement の disabled / danger / shortcut / separator', () => {
    it('disabled: true で .disabled クラスが付く（enabled: false と同義）', () => {
        const menu = buildMenuElement([{ label: '項目', disabled: true, action: () => {} }]);
        const item = menu.querySelector('.context-menu-item') as HTMLElement;
        expect(item.classList.contains('disabled')).toBe(true);
    });

    it('danger: true で .danger クラスが付く', () => {
        const menu = buildMenuElement([{ label: '削除', danger: true, action: () => {} }]);
        const item = menu.querySelector('.context-menu-item') as HTMLElement;
        expect(item.classList.contains('danger')).toBe(true);
    });

    it('shortcut を指定すると末尾にショートカット表示が入る', () => {
        const menu = buildMenuElement([{ label: '項目', shortcut: '⌘K', action: () => {} }]);
        const shortcut = menu.querySelector('.context-menu-item__shortcut');
        expect(shortcut?.textContent).toBe('⌘K');
    });

    it('separator: true でも区切り線が描画される（type: "separator" と同義）', () => {
        const menu = buildMenuElement([
            { label: 'A', action: () => {} },
            { separator: true },
            { label: 'B', action: () => {} },
        ]);
        expect(menu.querySelectorAll('.context-menu-separator').length).toBe(1);
    });
});

describe('computeSubmenuPlacement（ビューポート内クランプの純粋関数）', () => {
    it('右側に十分な余白があれば右開きになる', () => {
        const placement = computeSubmenuPlacement(
            { left: 100, right: 200, top: 50 },
            { width: 150, height: 100 },
            { width: 1000, height: 800 },
        );
        expect(placement.side).toBe('right');
    });

    it('右側に収まらない場合は左開きに反転する', () => {
        const placement = computeSubmenuPlacement(
            { left: 900, right: 980, top: 50 },
            { width: 150, height: 100 },
            { width: 1000, height: 800 },
        );
        expect(placement.side).toBe('left');
    });

    it('下端からはみ出す場合は負の topOffset で上方向にずらす', () => {
        const placement = computeSubmenuPlacement(
            { left: 100, right: 200, top: 700 },
            { width: 150, height: 200 },
            { width: 1000, height: 800 },
        );
        expect(placement.topOffset).toBeLessThan(0);
    });

    it('収まる場合は topOffset が 0', () => {
        const placement = computeSubmenuPlacement(
            { left: 100, right: 200, top: 50 },
            { width: 150, height: 100 },
            { width: 1000, height: 800 },
        );
        expect(placement.topOffset).toBe(0);
    });
});

describe('サブメニューのホバー開閉遅延', () => {
    beforeEach(() => {
        vi.useFakeTimers();
    });
    afterEach(() => {
        document.body.innerHTML = '';
        vi.useRealTimers();
    });

    it('親項目から離れても即座には閉じず、遅延後に閉じる', () => {
        const menu = buildMenuElement([
            { label: '親', submenu: [{ label: '子', action: () => {} }] },
        ]);
        document.body.appendChild(menu);
        const parentItem = menu.querySelector('.context-menu-item.has-submenu') as HTMLElement;
        const submenu = parentItem.querySelector('.context-menu--submenu') as HTMLElement;

        parentItem.dispatchEvent(new MouseEvent('mouseenter'));
        expect(submenu.style.display).toBe('block');

        parentItem.dispatchEvent(new MouseEvent('mouseleave'));
        // 遅延時間未満ではまだ開いたまま
        expect(submenu.style.display).toBe('block');

        vi.advanceTimersByTime(SUBMENU_CLOSE_DELAY_MS - 1);
        expect(submenu.style.display).toBe('block');

        vi.advanceTimersByTime(1);
        expect(submenu.style.display).toBe('none');
    });

    it('遅延中にサブメニュー自体へポインタが移動すればクローズをキャンセルする', () => {
        const menu = buildMenuElement([
            { label: '親', submenu: [{ label: '子', action: () => {} }] },
        ]);
        document.body.appendChild(menu);
        const parentItem = menu.querySelector('.context-menu-item.has-submenu') as HTMLElement;
        const submenu = parentItem.querySelector('.context-menu--submenu') as HTMLElement;

        parentItem.dispatchEvent(new MouseEvent('mouseenter'));
        parentItem.dispatchEvent(new MouseEvent('mouseleave'));
        vi.advanceTimersByTime(50);

        submenu.dispatchEvent(new MouseEvent('mouseenter'));
        vi.advanceTimersByTime(SUBMENU_CLOSE_DELAY_MS + 50);
        // サブメニューにポインタが留まっている間は閉じない
        expect(submenu.style.display).toBe('block');

        submenu.dispatchEvent(new MouseEvent('mouseleave'));
        vi.advanceTimersByTime(SUBMENU_CLOSE_DELAY_MS);
        expect(submenu.style.display).toBe('none');
    });
});
