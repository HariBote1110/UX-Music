import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
    normaliseSyncCachePolicy,
    normaliseSyncPreferredFormat,
    syncCachePolicyOptions,
    syncPreferredFormatOptions,
} from './ux-sync-settings.js';

/**
 * init-settings.ts が実際に使っている選択肢流し込み処理を、
 * jsdom の本物の <select> に対して直接動かして検証する。
 * （テスト側でロジックを写経すると本番コードが壊れても気付けないため）
 */
type PopulateSelectOptions = typeof import('../utils/init-settings.js')['populateSelectOptions'];

let populateSelectOptions: PopulateSelectOptions;

beforeEach(async () => {
    // init-settings.ts は依存モジュールの読み込み時に window.electronAPI を参照するため、
    // 動的 import の前に最小限のスタブを用意しておく。
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: async () => null,
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };

    ({ populateSelectOptions } = await import('../utils/init-settings.js'));

    document.body.innerHTML = `
        <select id="ux-sync-cache-policy-select"></select>
        <select id="ux-sync-preferred-format-select"></select>
    `;
});

afterEach(() => {
    document.body.innerHTML = '';
});

function cachePolicySelect(): HTMLSelectElement {
    return document.getElementById('ux-sync-cache-policy-select') as HTMLSelectElement;
}

describe('UX Sync キャッシュ方針セレクトの挙動', () => {
    it('選択肢としてミラーと選択同期の2つを本物の <option> として描画する', () => {
        const select = cachePolicySelect();
        populateSelectOptions(select, syncCachePolicyOptions());

        expect(Array.from(select.options).map(option => option.value)).toEqual(['mirror', 'selective']);
        expect(Array.from(select.options).map(option => option.textContent)).toEqual(
            syncCachePolicyOptions().map(option => option.label),
        );
        expect(select.querySelectorAll('option')).toHaveLength(2);
    });

    it('二重初期化ガードにより、2回呼んでも選択肢が重複しない', () => {
        const select = cachePolicySelect();

        populateSelectOptions(select, syncCachePolicyOptions());
        expect(select.dataset.optionsInitialised).toBe('true');

        // ユーザーが設定画面を開き直した場合を想定して、もう一度初期化する。
        populateSelectOptions(select, syncCachePolicyOptions());

        expect(select.options).toHaveLength(2);
        expect(Array.from(select.options).map(option => option.value)).toEqual(['mirror', 'selective']);
    });

    it('ユーザーが選択した値がそのまま正規化を通過する（有効な値）', () => {
        const select = cachePolicySelect();
        populateSelectOptions(select, syncCachePolicyOptions());

        select.value = 'selective';
        const savedPolicy = normaliseSyncCachePolicy(select.value);

        expect(savedPolicy).toBe('selective');
        // 正規化結果は必ず実在する <option> の値でなければならない。
        expect(select.querySelector(`option[value="${savedPolicy}"]`)).not.toBeNull();
    });

    it('未設定・不正な値は保存時にミラー方針へフォールバックする', () => {
        const select = cachePolicySelect();
        populateSelectOptions(select, syncCachePolicyOptions());

        // 選択肢に無い値を代入すると、本物の <select> は空文字に落ちる。
        select.value = 'unknown-policy';
        expect(select.value).toBe('');
        expect(normaliseSyncCachePolicy(select.value)).toBe('mirror');

        // 壊れた永続化データを直接正規化した場合も同じ結果になる。
        expect(normaliseSyncCachePolicy('unknown-policy')).toBe('mirror');
    });

    it('保存後に select.value を正規化結果で書き戻すと、実在する選択肢が選ばれる', () => {
        const select = cachePolicySelect();
        populateSelectOptions(select, syncCachePolicyOptions());

        const normalised = normaliseSyncCachePolicy('garbage');
        select.value = normalised;

        expect(select.selectedIndex).toBe(0);
        expect(select.options[select.selectedIndex].value).toBe('mirror');
    });

    it('音質セレクトも同じ流し込み処理で構築され、不正値からフォールバックする', () => {
        const select = document.getElementById('ux-sync-preferred-format-select') as HTMLSelectElement;
        populateSelectOptions(select, syncPreferredFormatOptions());

        expect(Array.from(select.options).map(option => option.value)).toEqual(['original', 'mp3_320']);

        select.value = 'flac';
        expect(normaliseSyncPreferredFormat(select.value)).toBe('original');

        select.value = 'mp3_320';
        expect(normaliseSyncPreferredFormat(select.value)).toBe('mp3_320');
    });
});
