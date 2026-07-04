import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';

const indexHtml = readFileSync(new URL('../../index.html', import.meta.url), 'utf8');

describe('UX Sync 設定画面の HTML', () => {
    it('保存タブにキャッシュ方針セレクトを持つ', () => {
        expect(indexHtml).toContain('id="ux-sync-cache-policy-select"');
        expect(indexHtml).toContain('キャッシュ方針');
    });

    it('同期タブの音質セレクトが push 転送用だと分かるラベルを持つ', () => {
        expect(indexHtml).toContain('for="ux-sync-transfer-encoding-select">転送時の音質</label>');
    });
});
