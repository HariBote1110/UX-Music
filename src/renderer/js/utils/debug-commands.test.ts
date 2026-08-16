import { describe, expect, it, vi, beforeEach } from 'vitest';

describe('enableYoutubeAdvancedModesWithConsent', () => {
    beforeEach(() => {
        document.body.innerHTML = `
            <label data-feature="youtube-advanced" class="hidden"><input type="radio" name="youtube-mode" value="download"></label>
            <label data-feature="youtube-advanced" class="hidden"><input type="radio" name="youtube-mode" value="stream"></label>
            <div id="youtube-quality-group" data-feature="youtube-advanced" class="hidden"></div>
        `;
        (window as unknown as { electronAPI: unknown }).electronAPI = {
            invoke: vi.fn().mockResolvedValue({}),
            send: vi.fn(),
        };
        vi.spyOn(window, 'confirm').mockReturnValue(true);
        vi.spyOn(window, 'alert').mockImplementation(() => undefined);
    });

    it('同意後に data-feature="youtube-advanced" 要素の hidden を解除し、設定を保存する', async () => {
        const { enableYoutubeAdvancedModesWithConsent } = await import('./debug-commands.js');
        const result = await enableYoutubeAdvancedModesWithConsent({ showAlert: false });

        expect(result).toBe(true);
        document.querySelectorAll('[data-feature="youtube-advanced"]').forEach((el) => {
            expect(el.classList.contains('hidden')).toBe(false);
        });
        expect((window as unknown as { electronAPI: { send: ReturnType<typeof vi.fn> } }).electronAPI.send)
            .toHaveBeenCalledWith('save-settings', { enableYoutubeAdvancedModes: true });
    });
});
