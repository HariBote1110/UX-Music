import { describe, expect, it } from 'vitest';
import { LEGACY_SETTING_KEYS, SETTING_KEY_SECTIONS } from './settings-keys.js';
import { SECTION_IDS } from './section-ids.js';

describe('設定セクションの移行網羅性', () => {
    it('旧 OK ハンドラが保存していた設定キーはすべて、いずれかのセクションに引き継がれている', () => {
        for (const key of LEGACY_SETTING_KEYS) {
            expect(SETTING_KEY_SECTIONS[key], `キー "${key}" の移行先セクションが未定義`).toBeDefined();
            expect(SECTION_IDS).toContain(SETTING_KEY_SECTIONS[key]);
        }
    });

    it('SETTING_KEY_SECTIONS に未知のキーが紛れ込んでいない', () => {
        const known = new Set<string>(LEGACY_SETTING_KEYS);
        for (const key of Object.keys(SETTING_KEY_SECTIONS)) {
            expect(known.has(key)).toBe(true);
        }
    });
});
