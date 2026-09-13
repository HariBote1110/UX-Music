import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    getCollectionShufflePreference: vi.fn(),
    setCollectionShufflePreference: vi.fn(),
    subscribeCollectionShufflePreferences: vi.fn(),
    showContextMenu: vi.fn(),
    showNotification: vi.fn(),
}));

vi.mock('../features/collection-shuffle.js', () => ({
    getCollectionShufflePreference: mocks.getCollectionShufflePreference,
    setCollectionShufflePreference: mocks.setCollectionShufflePreference,
    subscribeCollectionShufflePreferences: mocks.subscribeCollectionShufflePreferences,
}));

vi.mock('./utils.js', () => ({
    showContextMenu: mocks.showContextMenu,
}));

vi.mock('./notification.js', () => ({
    showNotification: mocks.showNotification,
}));

describe('collection-shuffle-control', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        mocks.subscribeCollectionShufflePreferences.mockReturnValue(vi.fn());
    });

    it('未設定のときニュートラル表示になる', async () => {
        mocks.getCollectionShufflePreference.mockReturnValue(null);
        const { createCollectionShuffleControl } = await import('./collection-shuffle-control.js');

        const control = createCollectionShuffleControl({ kind: 'album', key: 'album-1' });

        expect(control.element.classList.contains('is-unset')).toBe(true);
        expect(control.element.title).toContain('未設定');
    });

    it('シャッフル設定のときアイコンがハイライトされる', async () => {
        mocks.getCollectionShufflePreference.mockReturnValue('on');
        const { createCollectionShuffleControl } = await import('./collection-shuffle-control.js');

        const control = createCollectionShuffleControl({ kind: 'playlist', key: '朝の曲' });

        expect(control.element.classList.contains('is-on')).toBe(true);
        expect(control.element.getAttribute('aria-label')).toContain('シャッフル');
    });

    it('クリックで3択メニューを開き、現在値にチェックが付く', async () => {
        mocks.getCollectionShufflePreference.mockReturnValue('off');
        const { createCollectionShuffleControl } = await import('./collection-shuffle-control.js');

        const control = createCollectionShuffleControl({ kind: 'album', key: 'album-1' });
        document.body.appendChild(control.element);
        control.element.dispatchEvent(new MouseEvent('click', { bubbles: true }));

        expect(mocks.showContextMenu).toHaveBeenCalledTimes(1);
        const items = mocks.showContextMenu.mock.calls[0][2];
        expect(items.map((i: any) => i.label)).toEqual([
            '未設定（通常の設定に従う）',
            'シャッフル',
            '順番通り',
        ]);
        expect(items.find((i: any) => i.label === '順番通り').checked).toBe(true);
        expect(items.find((i: any) => i.label === 'シャッフル').checked).toBe(false);
    });

    it('メニュー項目を選ぶと setCollectionShufflePreference を呼ぶ', async () => {
        mocks.getCollectionShufflePreference.mockReturnValue(null);
        mocks.setCollectionShufflePreference.mockResolvedValue(undefined);
        const { buildShufflePreferenceMenuItems } = await import('./collection-shuffle-control.js');

        const items = buildShufflePreferenceMenuItems({ kind: 'playlist', key: '朝の曲' });
        await items.find((i: any) => i.label === 'シャッフル')!.action!();

        expect(mocks.setCollectionShufflePreference).toHaveBeenCalledWith({ kind: 'playlist', key: '朝の曲' }, 'on');
    });

    it('保存失敗時に通知を表示する', async () => {
        mocks.getCollectionShufflePreference.mockReturnValue(null);
        mocks.setCollectionShufflePreference.mockRejectedValue(new Error('backend error'));
        const { buildShufflePreferenceMenuItems } = await import('./collection-shuffle-control.js');

        const items = buildShufflePreferenceMenuItems({ kind: 'album', key: 'a1' });
        await items.find((i: any) => i.label === '順番通り')!.action!();

        expect(mocks.showNotification).toHaveBeenCalledWith(
            expect.stringContaining('既定のシャッフル設定を保存できませんでした'),
            4000,
        );
    });
});
