// src/renderer/js/ui/column-config.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('./utils.js', () => ({ showContextMenu: vi.fn() }));

import { showContextMenu } from './utils.js';
import { showColumnContextMenu, resetColumnConfigCache } from './column-config.js';

describe('showColumnContextMenu', () => {
    beforeEach(() => {
        resetColumnConfigCache();
        vi.mocked(showContextMenu).mockClear();
    });

    it('チェック状態はテキストの接頭辞ではなく checked フィールドで表現する', () => {
        const e = { preventDefault: () => {}, pageX: 10, pageY: 20 } as unknown as MouseEvent;
        showColumnContextMenu(e, () => {});

        const items = vi.mocked(showContextMenu).mock.calls[0][2];
        // ラベルに ✓ や余白パディングを含めない
        items.forEach(item => {
            expect(item.label).not.toMatch(/^[✓\s]/);
        });
        // 可視列は checked: true になる
        const artistItem = items.find(i => i.label === 'アーティスト');
        expect(artistItem?.checked).toBe(true);
    });
});
