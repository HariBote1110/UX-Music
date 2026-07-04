import { beforeEach, describe, expect, it, vi } from 'vitest';
import { EQUALIZER_COLOURS_CHANGE_EVENT, setEqualizerColorFromArtwork } from './utils.js';

describe('setEqualizerColorFromArtwork', () => {
    beforeEach(() => {
        const setProperty = vi.fn();
        globalThis.document = {
            documentElement: {
                style: { setProperty },
            },
        } as unknown as Document;
        globalThis.window = {
            dispatchEvent: vi.fn(),
        } as unknown as Window & typeof globalThis;
        globalThis.CustomEvent = class CustomEvent<T = unknown> extends Event {
            detail: T;
            constructor(type: string, init?: CustomEventInit<T>) {
                super(type, init);
                this.detail = init?.detail as T;
            }
        } as unknown as typeof CustomEvent;
    });

    it('notifies listeners after equalizer colours are updated', async () => {
        await setEqualizerColorFromArtwork({ src: './assets/default_artwork.png' });

        const setProperty = document.documentElement.style.setProperty as ReturnType<typeof vi.fn>;
        expect(setProperty).toHaveBeenCalledWith('--eq-color-1', 'var(--highlight-pink)');
        expect(window.dispatchEvent).toHaveBeenCalledWith(expect.objectContaining({
            type: EQUALIZER_COLOURS_CHANGE_EVENT,
        }));
        expect(setProperty.mock.invocationCallOrder[1]).toBeLessThan(
            (window.dispatchEvent as ReturnType<typeof vi.fn>).mock.invocationCallOrder[0]
        );
    });
});
