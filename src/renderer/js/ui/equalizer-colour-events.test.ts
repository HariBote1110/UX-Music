import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EQUALIZER_COLOURS_CHANGE_EVENT, setEqualizerColorFromArtwork } from './utils.js';

const DEFAULT_COLOUR_1 = 'var(--highlight-pink)';
const DEFAULT_COLOUR_2 = 'var(--highlight-blue)';

/**
 * utils.ts の色抽出は <canvas> の 2D コンテキストに依存しているが、
 * jsdom は getContext('2d') を実装していない。
 * そこで document.createElement('canvas') だけを差し替え、
 * 抽出される画素データをテスト側から与えられるようにする。
 */
function stubCanvasPixels(pixels: number[]): void {
    const context = {
        drawImage: vi.fn(),
        getImageData: vi.fn(() => ({ data: new Uint8ClampedArray(pixels) })),
    };
    const canvas = { width: 0, height: 0, getContext: vi.fn(() => context) };
    const realCreateElement = document.createElement.bind(document);

    vi.spyOn(document, 'createElement').mockImplementation(((tagName: string, ...rest: unknown[]) => {
        if (String(tagName).toLowerCase() === 'canvas') {
            return canvas as unknown as HTMLCanvasElement;
        }
        return realCreateElement(tagName as 'div', ...(rest as []));
    }) as typeof document.createElement);
}

/** 読み込み済みのアートワーク画像を模した最小オブジェクト。 */
function loadedArtwork(src: string) {
    return { src, complete: true, naturalWidth: 4, naturalHeight: 3, width: 4, height: 3, crossOrigin: '' };
}

function currentColours() {
    return {
        colour1: document.documentElement.style.getPropertyValue('--eq-color-1'),
        colour2: document.documentElement.style.getPropertyValue('--eq-color-2'),
    };
}

describe('setEqualizerColorFromArtwork', () => {
    let listeners: Array<() => void>;

    beforeEach(() => {
        listeners = [];
        document.documentElement.style.removeProperty('--eq-color-1');
        document.documentElement.style.removeProperty('--eq-color-2');
    });

    afterEach(() => {
        listeners.forEach(remove => remove());
        document.body.innerHTML = '';
        document.documentElement.style.removeProperty('--eq-color-1');
        document.documentElement.style.removeProperty('--eq-color-2');
        vi.restoreAllMocks();
    });

    /** 本物の window にリスナーを登録し、後片付けも予約する。 */
    function onColoursChanged(handler: (event: Event) => void): void {
        window.addEventListener(EQUALIZER_COLOURS_CHANGE_EVENT, handler);
        listeners.push(() => window.removeEventListener(EQUALIZER_COLOURS_CHANGE_EVENT, handler));
    }

    it('lets a listener observe the updated equalizer colours once the change event fires', async () => {
        const observedColours: Array<{ colour1: string; colour2: string }> = [];
        onColoursChanged(() => observedColours.push(currentColours()));

        await setEqualizerColorFromArtwork({ src: './assets/default_artwork.png' });

        // リスナーはちょうど1回だけ呼ばれ、その時点で CSS 変数が
        // 更新済みでなければならない（＝色の適用後にのみイベントが飛ぶ）。
        expect(observedColours).toHaveLength(1);
        expect(observedColours[0]).toEqual({
            colour1: DEFAULT_COLOUR_1,
            colour2: DEFAULT_COLOUR_2,
        });
    });

    it('dispatches an event carrying the correct type for the default-artwork fallback path', async () => {
        let receivedType: string | undefined;
        onColoursChanged((event: Event) => {
            receivedType = event.type;
        });

        await setEqualizerColorFromArtwork({ src: './assets/default_artwork.png' });

        expect(receivedType).toBe(EQUALIZER_COLOURS_CHANGE_EVENT);
    });

    it('applies the colours extracted from a non-default artwork', async () => {
        // 4画素ぶんのサンプリング対象。最頻色が rgb(64,128,192)、次点が rgb(32,64,96)。
        const colourA = [64, 128, 192, 255];
        const colourB = [32, 64, 96, 255];
        stubCanvasPixels([
            ...colourA,
            ...[0, 0, 0, 0], ...[0, 0, 0, 0], ...[0, 0, 0, 0],
            ...colourB,
            ...[0, 0, 0, 0], ...[0, 0, 0, 0], ...[0, 0, 0, 0],
            ...colourA,
            ...[0, 0, 0, 0], ...[0, 0, 0, 0], ...[0, 0, 0, 0],
        ]);

        const observed: Array<{ colour1: string; colour2: string }> = [];
        onColoursChanged(() => observed.push(currentColours()));

        const artwork = loadedArtwork('file:///Music/artwork/cover.png');
        await setEqualizerColorFromArtwork(artwork);

        // 既定アートワーク以外では抽出結果が CSS 変数に反映される。
        expect(currentColours()).toEqual({
            colour1: 'rgb(64,128,192)',
            colour2: 'rgb(32,64,96)',
        });
        expect(observed).toEqual([{ colour1: 'rgb(64,128,192)', colour2: 'rgb(32,64,96)' }]);
        // CORS 対策として crossOrigin が補われる。
        expect(artwork.crossOrigin).toBe('Anonymous');
    });

    it('falls back to the default colours when extraction yields no colours', async () => {
        // 画素が1つも取れなかった場合、抽出結果は null になる。
        stubCanvasPixels([]);

        const observed: Array<{ colour1: string; colour2: string }> = [];
        onColoursChanged(() => observed.push(currentColours()));

        await setEqualizerColorFromArtwork(loadedArtwork('file:///Music/artwork/cover.png'));

        expect(currentColours()).toEqual({
            colour1: DEFAULT_COLOUR_1,
            colour2: DEFAULT_COLOUR_2,
        });
        expect(observed).toHaveLength(1);
    });

    it('uses the default colours when no artwork element or src is supplied', async () => {
        const observed: string[] = [];
        onColoursChanged(event => observed.push(event.type));

        await setEqualizerColorFromArtwork(null);
        expect(currentColours()).toEqual({ colour1: DEFAULT_COLOUR_1, colour2: DEFAULT_COLOUR_2 });

        document.documentElement.style.removeProperty('--eq-color-1');
        document.documentElement.style.removeProperty('--eq-color-2');

        await setEqualizerColorFromArtwork({ src: '' });
        expect(currentColours()).toEqual({ colour1: DEFAULT_COLOUR_1, colour2: DEFAULT_COLOUR_2 });

        expect(observed).toHaveLength(2);
    });
});
