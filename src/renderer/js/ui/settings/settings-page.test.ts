import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * 設定ページの骨組み（左ナビ＋右コンテンツ＋検索フィルタ）の挙動を検証する。
 * DOM 構築は index.html 側の静的マークアップに依存するため、
 * テストでは最小限の骨組みを jsdom 上に用意して動かす。
 */

function buildSettingsDom(): void {
    document.body.innerHTML = `
        <div id="settings-modal-overlay" class="hidden">
            <div id="settings-page">
                <div class="settings-header">
                    <h2 id="settings-title">設定</h2>
                    <button id="settings-close-btn" type="button">閉じる</button>
                </div>
                <div class="settings-body">
                    <nav class="settings-nav">
                        <input type="search" id="settings-search-input">
                        <div class="settings-nav-list" id="settings-nav-list"></div>
                    </nav>
                    <div class="settings-content" id="settings-content">
                        <div class="settings-section" data-section="general" id="settings-section-general">
                            <div class="setting-item"><h4>イースターエッグ</h4></div>
                        </div>
                        <div class="settings-section" data-section="playback" id="settings-section-playback">
                            <div class="setting-item"><h4>グラフィックイコライザー</h4></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <button id="open-settings-btn"></button>
    `;
}

beforeEach(() => {
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: async () => ({}),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
    buildSettingsDom();
});

afterEach(() => {
    document.body.innerHTML = '';
    vi.resetModules();
});

describe('settings-page: セクション切り替え', () => {
    it('ナビをクリックすると対応するセクションだけ表示される', async () => {
        const { createSettingsPage } = await import('./settings-page.js');
        const page = createSettingsPage([
            { id: 'general', title: '一般' },
            { id: 'playback', title: '再生・オーディオ' },
        ]);
        page.mount();

        page.showSection('playback');

        expect(document.getElementById('settings-section-general')!.classList.contains('hidden')).toBe(true);
        expect(document.getElementById('settings-section-playback')!.classList.contains('hidden')).toBe(false);
    });

    it('open-settings カスタムイベントの section 指定でそのセクションが開く', async () => {
        const { createSettingsPage } = await import('./settings-page.js');
        const page = createSettingsPage([
            { id: 'general', title: '一般' },
            { id: 'playback', title: '再生・オーディオ' },
        ]);
        page.mount();

        document.dispatchEvent(new CustomEvent('open-settings', { detail: { section: 'audio' } }));

        expect(document.getElementById('settings-modal-overlay')!.classList.contains('hidden')).toBe(false);
        expect(document.getElementById('settings-section-playback')!.classList.contains('hidden')).toBe(false);
    });
});

describe('settings-page: 検索フィルタ', () => {
    it('検索語に一致しない項目は隠れる', async () => {
        const { createSettingsPage } = await import('./settings-page.js');
        const page = createSettingsPage([
            { id: 'general', title: '一般' },
            { id: 'playback', title: '再生・オーディオ' },
        ]);
        page.mount();

        const input = document.getElementById('settings-search-input') as HTMLInputElement;
        input.value = 'イコライザー';
        input.dispatchEvent(new Event('input'));

        const generalItem = document.querySelector('#settings-section-general .setting-item') as HTMLElement;
        const playbackItem = document.querySelector('#settings-section-playback .setting-item') as HTMLElement;
        expect(generalItem.classList.contains('setting-item--filtered-out')).toBe(true);
        expect(playbackItem.classList.contains('setting-item--filtered-out')).toBe(false);
    });

    it('検索語を消すとすべて再表示される', async () => {
        const { createSettingsPage } = await import('./settings-page.js');
        const page = createSettingsPage([
            { id: 'general', title: '一般' },
            { id: 'playback', title: '再生・オーディオ' },
        ]);
        page.mount();

        const input = document.getElementById('settings-search-input') as HTMLInputElement;
        input.value = 'イコライザー';
        input.dispatchEvent(new Event('input'));
        input.value = '';
        input.dispatchEvent(new Event('input'));

        const generalItem = document.querySelector('#settings-section-general .setting-item') as HTMLElement;
        expect(generalItem.classList.contains('setting-item--filtered-out')).toBe(false);
    });
});
