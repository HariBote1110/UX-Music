import { beforeAll, afterEach, describe, expect, it, vi } from 'vitest';

// 歌詞エディタのシークバーのドラッグ解放（mouseup）がバー要素の外で発生しても
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
    vi.doUnmock('./player.js');
    document.body.innerHTML = '';
});

describe('歌詞エディタのシークバーのポインタ解放処理', () => {
    it('バー要素外（document）で mouseup してもシークが完了する', async () => {
        const seek = vi.fn();

        vi.doMock('./player.js', () => ({
            togglePlayPause: vi.fn(),
            seek,
            getCurrentTime: vi.fn(() => 0),
            getDuration: vi.fn(() => 100),
            isPlaying: vi.fn(() => false),
        }));

        document.body.innerHTML = `
            <input id="lrc-progress-bar" type="range" min="0" max="100" value="0" />
        `;
        const progressBar = document.getElementById('lrc-progress-bar') as HTMLInputElement;

        const { bindEditorSeekBarDragHandlers } = await import('./lrc-editor.js');

        bindEditorSeekBarDragHandlers(progressBar, undefined);

        progressBar.dispatchEvent(new MouseEvent('mousedown'));

        progressBar.value = '37';
        // バーの外、document 上で release する (回帰前は editorIsSeeking が解除されなかった)
        document.dispatchEvent(new MouseEvent('mouseup'));

        expect(seek).toHaveBeenCalledWith(37);
    });
});
