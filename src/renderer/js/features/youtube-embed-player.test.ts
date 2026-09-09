import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const app = {
    GetYouTubeEmbedURL: async () => 'http://127.0.0.1:1234/embed?v=dQw4w9WgXcQ',
};

const nativeResizeObserver = globalThis.ResizeObserver;
const nativeRequestAnimationFrame = window.requestAnimationFrame;
const nativeCancelAnimationFrame = window.cancelAnimationFrame;
let resizeObservers: MockResizeObserver[] = [];
let animationFrames = new Map<number, FrameRequestCallback>();
let nextAnimationFrameId = 0;

class MockResizeObserver {
    readonly callback: ResizeObserverCallback;
    readonly observe = vi.fn();
    readonly disconnect = vi.fn();

    constructor(callback: ResizeObserverCallback) {
        this.callback = callback;
        resizeObservers.push(this);
    }

    trigger(): void {
        this.callback([], this as unknown as ResizeObserver);
    }
}

function runNextAnimationFrame(): void {
    const next = animationFrames.entries().next().value as [number, FrameRequestCallback] | undefined;
    if (!next) return;
    animationFrames.delete(next[0]);
    next[1](performance.now());
}

beforeEach(() => {
    resizeObservers = [];
    animationFrames = new Map();
    nextAnimationFrameId = 0;
    Object.defineProperty(globalThis, 'ResizeObserver', {
        configurable: true,
        writable: true,
        value: MockResizeObserver,
    });
    Object.defineProperty(window, 'requestAnimationFrame', {
        configurable: true,
        writable: true,
        value: vi.fn((callback: FrameRequestCallback) => {
            const id = ++nextAnimationFrameId;
            animationFrames.set(id, callback);
            return id;
        }),
    });
    Object.defineProperty(window, 'cancelAnimationFrame', {
        configurable: true,
        writable: true,
        value: vi.fn((id: number) => animationFrames.delete(id)),
    });
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: () => Promise.resolve(null),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
    (window as unknown as { go: unknown }).go = { server: { App: app } };
    document.body.innerHTML = '<div id="now-playing-artwork-container"></div>';
});

afterEach(async () => {
    const player = await import('./youtube-embed-player.js');
    player.destroyEmbedPlayer();
    document.body.innerHTML = '';
    delete (window as unknown as { go?: unknown }).go;
    Object.defineProperty(globalThis, 'ResizeObserver', {
        configurable: true,
        writable: true,
        value: nativeResizeObserver,
    });
    Object.defineProperty(window, 'requestAnimationFrame', {
        configurable: true,
        writable: true,
        value: nativeRequestAnimationFrame,
    });
    Object.defineProperty(window, 'cancelAnimationFrame', {
        configurable: true,
        writable: true,
        value: nativeCancelAnimationFrame,
    });
});

describe('YouTube embed player lifecycle', () => {
    it('キュー通知で current track がローカル曲になったら embed を破棄する', async () => {
        const player = await import('./youtube-embed-player.js');
        const { handleQueueStateChangedEvent } = await import('./playback-manager.js');

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });
        expect(player.isEmbedPlayerActive()).toBe(true);

        handleQueueStateChangedEvent({
            items: [{ id: 'local-1', type: 'local', path: '/Music/local.flac', title: 'Local' }],
            index: 0,
            active: true,
        }, {
            findSong: () => null,
            updatePlayingIndicators: () => {},
            renderQueueView: () => {},
            updateNowPlayingView: () => {},
            loadLyricsForSong: () => {},
            prefetchUpcomingRemoteTracks: () => {},
            updateShuffleLoopButtons: () => {},
        });

        expect(player.isEmbedPlayerActive()).toBe(false);
    });

    it('embed 破棄後の transport controls は Go のローカルプレイヤーへ送る', async () => {
        const player = await import('./youtube-embed-player.js');
        const { handleQueueStateChangedEvent } = await import('./playback-manager.js');
        const { initElements } = await import('../core/state.js');
        const { initPlayer, playCurrent, pauseCurrent, seek, togglePlayPause } = await import('./player.js');

        handleQueueStateChangedEvent({
            items: [{ id: 'local-1', type: 'local', path: '/Music/local.flac', title: 'Local' }],
            index: 0,
            active: true,
        }, {
            findSong: () => null,
            updatePlayingIndicators: () => {},
            renderQueueView: () => {},
            updateNowPlayingView: () => {},
            loadLyricsForSong: () => {},
            prefetchUpcomingRemoteTracks: () => {},
            updateShuffleLoopButtons: () => {},
        });
        expect(player.isEmbedPlayerActive()).toBe(false);

        const audioResume = vi.fn(async () => {});
        const audioPause = vi.fn(async () => {});
        const audioSeek = vi.fn(async () => {});
        Object.assign(app, {
            AudioResume: audioResume,
            AudioPause: audioPause,
            AudioSeek: audioSeek,
            AudioGetStatus: async () => ({ position: 0, duration: 0, playing: false, paused: true }),
        });
        document.body.innerHTML += `
            <button id="play-pause-btn"></button>
            <input id="progress-bar" />
            <input id="volume-slider" value="1" />
            <button id="volume-icon-btn"></button>
            <button id="shuffle-btn"></button>
            <button id="loop-btn"></button>
            <span id="current-time"></span>
            <span id="total-duration"></span>
        `;
        initElements();
        await initPlayer(null, { onNextSong: () => {}, onPrevSong: () => {} });

        await playCurrent();
        await pauseCurrent();
        await seek(12);
        await togglePlayPause();

        expect(audioResume).toHaveBeenCalledTimes(2);
        expect(audioPause).toHaveBeenCalledOnce();
        expect(audioSeek).toHaveBeenCalledWith(12);
    });

    it('フルスクリーン切替では iframe と閉じるボタンを re-parent せず、表示矩形だけを更新する', async () => {
        const player = await import('./youtube-embed-player.js');
        const sidebar = document.getElementById('now-playing-artwork-container')!;
        const overlay = document.createElement('div');
        overlay.id = 'fs-overlay';
        const closeButton = document.createElement('button');
        closeButton.id = 'fs-close-btn';
        const fullscreen = document.createElement('div');
        fullscreen.id = 'fs-video-slot';
        overlay.append(closeButton, fullscreen);
        document.body.appendChild(overlay);

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });
        const iframe = document.querySelector('iframe');
        const wrapper = document.getElementById('youtube-embed-wrapper');
        expect(wrapper?.parentElement).toBe(document.body);

        expect(player.reattachEmbedPlayer(fullscreen)).toBe(true);

        expect(wrapper?.parentElement).toBe(document.body);
        expect(closeButton.parentElement).toBe(overlay);
        expect(fullscreen.classList.contains('video-mode')).toBe(true);
        expect(sidebar.classList.contains('video-mode')).toBe(false);
        expect(document.querySelector('iframe')).toBe(iframe);

        expect(player.reattachEmbedPlayer(sidebar)).toBe(true);
        expect(closeButton.parentElement).toBe(overlay);
    });

    it('ResizeObserver が通知したコンテナの矩形変更に wrapper が追従する', async () => {
        const player = await import('./youtube-embed-player.js');
        const container = document.getElementById('now-playing-artwork-container')!;
        let rect = { left: 10, top: 20, width: 300, height: 168 };
        vi.spyOn(container, 'getBoundingClientRect').mockImplementation(() => rect as DOMRect);

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });
        const wrapper = document.getElementById('youtube-embed-wrapper')!;
        expect(resizeObservers).toHaveLength(1);
        expect(resizeObservers[0].observe).toHaveBeenCalledWith(container);
        expect(wrapper.style.left).toBe('10px');
        expect(wrapper.style.width).toBe('300px');

        rect = { left: 42, top: 64, width: 512, height: 288 };
        resizeObservers[0].trigger();
        runNextAnimationFrame();

        expect(wrapper.style.left).toBe('42px');
        expect(wrapper.style.top).toBe('64px');
        expect(wrapper.style.width).toBe('512px');
        expect(wrapper.style.height).toBe('288px');
    });

    it('destroyEmbedPlayer で ResizeObserver が切断される', async () => {
        const player = await import('./youtube-embed-player.js');
        const container = document.getElementById('now-playing-artwork-container')!;
        vi.spyOn(container, 'getBoundingClientRect').mockReturnValue({
            left: 0, top: 0, width: 300, height: 168,
        } as DOMRect);

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });
        player.destroyEmbedPlayer();

        expect(resizeObservers[0].disconnect).toHaveBeenCalledOnce();
    });

    it('同一フレーム内の複数トリガーでは矩形を一度だけ読む', async () => {
        const player = await import('./youtube-embed-player.js');
        const container = document.getElementById('now-playing-artwork-container')!;
        const rect = { left: 10, top: 20, width: 300, height: 168 };
        const rectSpy = vi.spyOn(container, 'getBoundingClientRect').mockReturnValue(rect as DOMRect);

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });
        const readsAfterMount = rectSpy.mock.calls.length;

        resizeObservers[0].trigger();
        resizeObservers[0].trigger();
        window.dispatchEvent(new Event('resize'));
        window.dispatchEvent(new Event('scroll'));

        expect(rectSpy).toHaveBeenCalledTimes(readsAfterMount);
        runNextAnimationFrame();
        expect(rectSpy).toHaveBeenCalledTimes(readsAfterMount + 1);
    });

    it('コンテナがゼロサイズなら wrapper を非表示にする', async () => {
        const player = await import('./youtube-embed-player.js');
        const container = document.getElementById('now-playing-artwork-container')!;
        vi.spyOn(container, 'getBoundingClientRect').mockReturnValue({
            left: 42, top: 64, width: 0, height: 0,
        } as DOMRect);

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });

        expect(document.getElementById('youtube-embed-wrapper')?.style.display).toBe('none');
    });
});
