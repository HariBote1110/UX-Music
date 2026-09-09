import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const app = {
    GetYouTubeEmbedURL: async () => 'http://127.0.0.1:1234/embed?v=dQw4w9WgXcQ',
};

const nativeResizeObserver = globalThis.ResizeObserver;
const nativeMutationObserver = globalThis.MutationObserver;
let resizeObservers: MockResizeObserver[] = [];
let mutationObservers: MockMutationObserver[] = [];

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

class MockMutationObserver {
    readonly callback: MutationCallback;
    readonly observe = vi.fn();
    readonly disconnect = vi.fn();

    constructor(callback: MutationCallback) {
        this.callback = callback;
        mutationObservers.push(this);
    }
}

beforeEach(() => {
    resizeObservers = [];
    mutationObservers = [];
    Object.defineProperty(globalThis, 'ResizeObserver', {
        configurable: true,
        writable: true,
        value: MockResizeObserver,
    });
    Object.defineProperty(globalThis, 'MutationObserver', {
        configurable: true,
        writable: true,
        value: MockMutationObserver,
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
    Object.defineProperty(globalThis, 'MutationObserver', {
        configurable: true,
        writable: true,
        value: nativeMutationObserver,
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

    it('フルスクリーン切替では iframe を re-parent せず、表示矩形だけを更新する', async () => {
        const player = await import('./youtube-embed-player.js');
        const sidebar = document.getElementById('now-playing-artwork-container')!;
        const fullscreen = document.createElement('div');
        document.body.appendChild(fullscreen);

        await player.mountEmbedPlayer('dQw4w9WgXcQ', { onPlaying: () => {}, onEnded: () => {} });
        const iframe = document.querySelector('iframe');
        const wrapper = document.getElementById('youtube-embed-wrapper');
        expect(wrapper?.parentElement).toBe(document.body);

        expect(player.reattachEmbedPlayer(fullscreen)).toBe(true);

        expect(wrapper?.parentElement).toBe(document.body);
        expect(fullscreen.classList.contains('video-mode')).toBe(true);
        expect(sidebar.classList.contains('video-mode')).toBe(false);
        expect(document.querySelector('iframe')).toBe(iframe);
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
        expect(mutationObservers[0].disconnect).toHaveBeenCalledOnce();
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
