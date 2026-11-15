import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// 歌詞ロードの世代管理: 曲送りが速く、前の曲の歌詞取得が後から返っても
// 現在の曲の歌詞を上書きしないこと

type Deferred<T> = { promise: Promise<T>; resolve: (value: T) => void };

function deferred<T>(): Deferred<T> {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>(r => {
        resolve = r;
    });
    return { promise, resolve };
}

const songA = { title: 'A', artist: 'x', path: '/music/a.mp3' };
const songB = { title: 'B', artist: 'x', path: '/music/b.mp3' };

afterEach(() => {
    vi.resetModules();
    vi.doUnmock('./player.js');
    document.body.innerHTML = '';
});

beforeEach(() => {
    document.body.innerHTML = `
        <div id="lyrics-container">
            <div id="lyrics-view"></div>
        </div>
    `;
});

async function setupWithPending(pending: Map<string, Deferred<unknown>>) {
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: (channel: string, song: { path?: string }) => {
            if (channel !== 'get-lyrics') {
                return Promise.resolve(null);
            }
            const entry = pending.get(song.path ?? '');
            return entry ? entry.promise : Promise.resolve(null);
        },
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
    vi.doMock('./player.js', () => ({
        seek: vi.fn(),
        getCurrentTime: vi.fn(() => 0),
        getDuration: vi.fn(() => 300),
        isPlaying: vi.fn(() => true),
        togglePlayPause: vi.fn(),
    }));
    const { elements } = await import('../core/state.js');
    elements.lyricsView = document.getElementById('lyrics-view');
    const state = (await import('../core/state.js')).state;
    const manager = await import('./lyrics-manager.js');
    return { manager, state, elements };
}

describe('loadLyricsForSong: 速い曲送りでの世代管理', () => {
    it('does not apply a slow response for the previous song after the next song has loaded', async () => {
        const pendingA = deferred<unknown>();
        const pendingB = deferred<unknown>();
        const pending = new Map<string, Deferred<unknown>>([
            [songA.path, pendingA],
            [songB.path, pendingB],
        ]);
        const { manager, state, elements } = await setupWithPending(pending);

        const loadA = manager.loadLyricsForSong(songA);
        const loadB = manager.loadLyricsForSong(songB);

        pendingB.resolve({ type: 'lrc', content: '[00:02.00]beta line' });
        await loadB;
        pendingA.resolve({ type: 'lrc', content: '[00:01.00]alpha line' });
        await loadA;

        expect(state.currentLyrics?.[0]?.text).toBe('beta line');
        expect(elements.lyricsView.textContent).toContain('beta line');
        expect(elements.lyricsView.textContent).not.toContain('alpha line');
    });
});
