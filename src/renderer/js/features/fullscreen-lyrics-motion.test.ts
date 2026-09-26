import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// フルスクリーン歌詞（#fs-lyrics）の同期表示:
// - 曲の途中でフルスクリーンを開いたとき、現在行へ遷移なしで即座に合わせる
// - LRC の行クリックでその行の時刻へシークする

let currentTime = 0;
const seek = vi.fn();

beforeEach(() => {
    currentTime = 0;
    seek.mockReset();
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
    // jsdom は SVG の getTotalLength と ResizeObserver を持たないため最小限の代替を置く
    const svgProto = SVGElement.prototype as unknown as { getTotalLength?: () => number };
    if (!svgProto.getTotalLength) svgProto.getTotalLength = () => 0;
    if (typeof globalThis.ResizeObserver === 'undefined') {
        globalThis.ResizeObserver = class {
            observe() {}
            unobserve() {}
            disconnect() {}
        } as unknown as typeof ResizeObserver;
    }
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: () => Promise.resolve(null),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
    vi.doMock('./player.js', () => ({
        seek,
        getCurrentTime: vi.fn(() => currentTime),
        getDuration: vi.fn(() => 300),
        isPlaying: vi.fn(() => true),
        togglePlayPause: vi.fn(),
    }));
    vi.doMock('./playback-manager.js', () => ({
        playNextSong: vi.fn(),
        playPrevSong: vi.fn(),
        playSong: vi.fn(),
    }));
    vi.doMock('./youtube-embed-player.js', () => ({
        isEmbedPlayerActive: vi.fn(() => false),
        reattachEmbedPlayer: vi.fn(() => false),
    }));
});

afterEach(async () => {
    const view = await import('./fullscreen-view.js');
    view.closeFullscreenView();
    vi.useRealTimers();
    vi.resetModules();
    vi.doUnmock('./player.js');
    vi.doUnmock('./playback-manager.js');
    vi.doUnmock('./youtube-embed-player.js');
    document.body.innerHTML = '';
});

async function openWithLrc() {
    const { state } = await import('../core/state.js');
    state.currentLyricsType = 'lrc';
    state.currentLyrics = Array.from({ length: 12 }, (_, i) => ({ time: i + 1, text: `line ${i}` }));
    state.playbackQueue = [];
    state.currentSongIndex = -1;
    const view = await import('./fullscreen-view.js');
    view.openFullscreenView();
    return view;
}

function lines(): HTMLElement[] {
    return Array.from(document.querySelectorAll<HTMLElement>('#fs-lyrics p[data-index]'));
}

function activeIndex(): number {
    return lines().findIndex(p => p.classList.contains('active'));
}

function expectAllSnapped() {
    for (const p of lines()) {
        expect(p.style.getPropertyValue('--fs-line-dur')).toBe('0ms');
        expect(p.style.getPropertyValue('--fs-line-delay')).toBe('0ms');
    }
}

describe('フルスクリーン歌詞: 途中から開いたときのスナップ', () => {
    it('曲の途中で開くと現在行へ遷移なしで合わせ、次の tick でも一斉に流れない', async () => {
        currentTime = 7.5; // line 6
        await openWithLrc();

        expect(activeIndex()).toBe(6);
        expectAllSnapped();

        currentTime = 7.7;
        vi.advanceTimersByTime(250);
        expect(activeIndex()).toBe(6);
        expectAllSnapped();
    });

    it('遠くへのシークはスナップ、隣接行への行送りはカスケード', async () => {
        currentTime = 1.5;
        await openWithLrc();

        currentTime = 2.5;
        vi.advanceTimersByTime(250);
        expect(activeIndex()).toBe(1);
        expect(lines()[5].style.getPropertyValue('--fs-line-dur')).toBe('800ms');
        expect(lines()[5].style.getPropertyValue('--fs-line-delay')).toBe('160ms');

        currentTime = 10.5;
        vi.advanceTimersByTime(250);
        expect(activeIndex()).toBe(9);
        expectAllSnapped();
    });
});

describe('フルスクリーン歌詞: 行クリックでシーク', () => {
    it('LRC の行をクリックするとその行の時刻へシークする', async () => {
        currentTime = 1.5;
        await openWithLrc();

        lines()[8].dispatchEvent(new MouseEvent('click', { bubbles: true }));

        expect(seek).toHaveBeenCalledTimes(1);
        expect(seek).toHaveBeenCalledWith(9);
        expect(activeIndex()).toBe(8);
        expectAllSnapped();
    });

    it('txt 歌詞の行はクリックしてもシークしない', async () => {
        const { state } = await import('../core/state.js');
        state.currentLyricsType = 'txt';
        state.currentLyrics = 'a\nb\nc';
        state.playbackQueue = [];
        state.currentSongIndex = -1;
        const view = await import('./fullscreen-view.js');
        view.openFullscreenView();

        const p = document.querySelector<HTMLElement>('#fs-lyrics p')!;
        p.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        expect(seek).not.toHaveBeenCalled();
    });
});
