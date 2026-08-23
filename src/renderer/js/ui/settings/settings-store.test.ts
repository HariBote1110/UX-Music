import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * 設定ページの保存契約: 「OK で一括保存」ではなく、コントロール変更のたびに
 * 即時 `musicApi.saveSettings` を呼ぶことを保証する。
 */

describe('settings-store', () => {
    beforeEach(() => {
        (window as unknown as { electronAPI: unknown }).electronAPI = {
            CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
            send: () => {},
            invoke: async () => ({}),
            on: () => {},
            removeListener: () => {},
            removeAllListeners: () => {},
        };
    });

    afterEach(() => {
        vi.resetModules();
    });

    it('save() は即座に musicApi.saveSettings をパッチ差分だけで呼ぶ', async () => {
        const { save } = await import('./settings-store.js');
        const bridge = await import('../../core/bridge.js');
        const spy = vi.spyOn(bridge.musicApi, 'saveSettings').mockResolvedValue(undefined);

        await save({ enableEasterEggs: true });

        expect(spy).toHaveBeenCalledTimes(1);
        expect(spy).toHaveBeenCalledWith({ enableEasterEggs: true });
    });

    it('save() のたびに購読者へパッチが通知される', async () => {
        const { save, subscribe } = await import('./settings-store.js');
        const bridge = await import('../../core/bridge.js');
        vi.spyOn(bridge.musicApi, 'saveSettings').mockResolvedValue(undefined);

        const received: Record<string, unknown>[] = [];
        const unsubscribe = subscribe(patch => received.push(patch));

        await save({ uiTheme: 'music-center' });
        unsubscribe();
        await save({ uiTheme: 'default' });

        expect(received).toEqual([{ uiTheme: 'music-center' }]);
    });

    it('readSettings() は保存済み設定を読み出す', async () => {
        (window as unknown as { electronAPI: { invoke: () => Promise<unknown> } }).electronAPI.invoke =
            async () => ({ uiTheme: 'music-center' });
        const { readSettings } = await import('./settings-store.js');

        const settings = await readSettings();

        expect(settings.uiTheme).toBe('music-center');
    });
});
