import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const app = {
    GetYouTubeEmbedURL: async () => 'http://127.0.0.1:1234/embed?v=dQw4w9WgXcQ',
};

beforeEach(() => {
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
});
