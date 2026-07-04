import { beforeEach, describe, expect, it } from 'vitest';
import { EQUALIZER_COLOURS_CHANGE_EVENT, setEqualizerColorFromArtwork } from './utils.js';

describe('setEqualizerColorFromArtwork', () => {
    let cssProperties: Record<string, string>;

    beforeEach(() => {
        cssProperties = {};
        globalThis.document = {
            documentElement: {
                style: {
                    setProperty: (name: string, value: string) => {
                        cssProperties[name] = value;
                    },
                },
            },
        } as unknown as Document;
        globalThis.window = {
            dispatchEvent: (event: Event) => {
                (globalThis.window as unknown as { _listeners?: Array<(e: Event) => void> })
                    ._listeners?.forEach(listener => listener(event));
                return true;
            },
            addEventListener: (_type: string, listener: (e: Event) => void) => {
                const w = globalThis.window as unknown as { _listeners?: Array<(e: Event) => void> };
                w._listeners = w._listeners ?? [];
                w._listeners.push(listener);
            },
        } as unknown as Window & typeof globalThis;
        globalThis.CustomEvent = class CustomEvent<T = unknown> extends Event {
            detail: T;
            constructor(type: string, init?: CustomEventInit<T>) {
                super(type, init);
                this.detail = init?.detail as T;
            }
        } as unknown as typeof CustomEvent;
    });

    it('lets a listener observe the updated equalizer colours once the change event fires', async () => {
        const observedColours: Array<{ colour1: string; colour2: string }> = [];
        window.addEventListener(EQUALIZER_COLOURS_CHANGE_EVENT, () => {
            observedColours.push({
                colour1: cssProperties['--eq-color-1'],
                colour2: cssProperties['--eq-color-2'],
            });
        });

        await setEqualizerColorFromArtwork({ src: './assets/default_artwork.png' });

        // The listener must have fired exactly once and must see the colours
        // already applied to the CSS custom properties at the time it runs —
        // i.e. the event is only dispatched after the colour update completes.
        expect(observedColours).toHaveLength(1);
        expect(observedColours[0]).toEqual({
            colour1: 'var(--highlight-pink)',
            colour2: 'var(--highlight-blue)',
        });
    });

    it('dispatches an event carrying the correct type for the default-artwork fallback path', async () => {
        let receivedType: string | undefined;
        window.addEventListener(EQUALIZER_COLOURS_CHANGE_EVENT, (event: Event) => {
            receivedType = event.type;
        });

        await setEqualizerColorFromArtwork({ src: './assets/default_artwork.png' });

        expect(receivedType).toBe(EQUALIZER_COLOURS_CHANGE_EVENT);
    });
});
