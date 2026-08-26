import { beforeAll, afterEach, describe, expect, it, vi } from 'vitest';

// シークバーのドラッグ解放（mouseup）がバー要素の外で発生しても
// シークが完了することを検証する（バー1点のみへの mouseup 束縛によるフリーズ回帰防止）。

beforeAll(() => {
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: () => Promise.resolve(null),
        on: () => {},
        removeListener: () => {},
        removeAllListeners: () => {},
    };
});

afterEach(() => {
    vi.resetModules();
    vi.doUnmock('../features/player.js');
    vi.doUnmock('../features/lrc-editor.js');
    document.body.innerHTML = '';
});

describe('シークバーのポインタ解放処理', () => {
    it('バー要素外（document）で mouseup してもシークが完了し、再生が再開する', async () => {
        const seek = vi.fn();
        const playCurrent = vi.fn();
        const pauseCurrent = vi.fn();
        let playing = true;
        const isPlaying = vi.fn(() => playing);

        vi.doMock('../features/player.js', () => ({
            seek,
            togglePlayPause: vi.fn(),
            isPlaying,
            getCurrentTime: vi.fn(() => 0),
            getDuration: vi.fn(() => 100),
            playCurrent: vi.fn(() => { playing = true; playCurrent(); }),
            pauseCurrent: vi.fn(() => { playing = false; pauseCurrent(); }),
        }));
        vi.doMock('../features/lrc-editor.js', () => ({
            updateLrcEditorControls: vi.fn(),
        }));

        document.body.innerHTML = `
            <input id="progress-bar" type="range" min="0" max="100" value="0" />
        `;
        const progressBar = document.getElementById('progress-bar') as HTMLInputElement;

        const { bindSeekBarDragHandlers } = await import('./player-ui.js');

        bindSeekBarDragHandlers(progressBar);

        progressBar.dispatchEvent(new MouseEvent('mousedown'));
        expect(pauseCurrent).toHaveBeenCalledTimes(1);

        progressBar.value = '42';
        // バーの外、document 上で release する (回帰前は isSeeking が解除されなかった)
        document.dispatchEvent(new MouseEvent('mouseup'));

        expect(seek).toHaveBeenCalledWith(42);
        expect(playCurrent).toHaveBeenCalledTimes(1);
    });
});
