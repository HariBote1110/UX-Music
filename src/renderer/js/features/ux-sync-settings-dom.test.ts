import { describe, expect, it } from 'vitest';
import {
    normaliseSyncCachePolicy,
    normaliseSyncPreferredFormat,
    syncCachePolicyOptions,
} from './ux-sync-settings.js';

/**
 * A minimal stand-in for an HTMLSelectElement, mirroring the subset of the
 * DOM API that `init-settings.ts` relies on when populating and reading the
 * UX Sync キャッシュ方針 select (appendChild of <option> elements, .value get/set).
 */
class FakeSelectElement {
    private options: Array<{ value: string; label: string }> = [];
    value = '';

    appendOption(value: string, label: string): void {
        this.options.push({ value, label });
    }

    hasOptionValue(value: string): boolean {
        return this.options.some(option => option.value === value);
    }

    optionValues(): string[] {
        return this.options.map(option => option.value);
    }
}

/** Mirrors the population step performed in init-settings.ts for the cache policy select. */
function populateCachePolicySelect(select: FakeSelectElement): void {
    for (const option of syncCachePolicyOptions()) {
        select.appendOption(option.value, option.label);
    }
}

describe('UX Sync キャッシュ方針セレクトの挙動', () => {
    it('選択肢としてミラーと選択同期の2つを提供する', () => {
        const select = new FakeSelectElement();
        populateCachePolicySelect(select);

        expect(select.optionValues()).toEqual(['mirror', 'selective']);
    });

    it('ユーザーが選択した値がそのまま正規化を通過する（有効な値）', () => {
        const select = new FakeSelectElement();
        populateCachePolicySelect(select);

        select.value = 'selective';
        const savedPolicy = normaliseSyncCachePolicy(select.value);

        expect(savedPolicy).toBe('selective');
        expect(select.hasOptionValue(savedPolicy)).toBe(true);
    });

    it('未設定・不正な値は保存時にミラー方針へフォールバックする', () => {
        const select = new FakeSelectElement();
        populateCachePolicySelect(select);

        // ユーザー操作前や壊れた永続化データを想定。
        select.value = '';
        expect(normaliseSyncCachePolicy(select.value)).toBe('mirror');

        select.value = 'unknown-policy';
        expect(normaliseSyncCachePolicy(select.value)).toBe('mirror');
    });

    it('保存後に select.value を正規化結果で上書きしても選択肢からずれない', () => {
        const select = new FakeSelectElement();
        populateCachePolicySelect(select);

        select.value = 'garbage';
        const normalised = normaliseSyncCachePolicy(select.value);
        select.value = normalised;

        expect(select.value).toBe('mirror');
        expect(select.hasOptionValue(select.value)).toBe(true);
    });

    it('音質セレクトの値も同様に不正値からフォールバックする', () => {
        const preferredFormatSelect = new FakeSelectElement();
        preferredFormatSelect.appendOption('original', '原本');
        preferredFormatSelect.appendOption('mp3_320', 'MP3 320kbps');

        preferredFormatSelect.value = 'flac';
        expect(normaliseSyncPreferredFormat(preferredFormatSelect.value)).toBe('original');

        preferredFormatSelect.value = 'mp3_320';
        expect(normaliseSyncPreferredFormat(preferredFormatSelect.value)).toBe('mp3_320');
    });
});
