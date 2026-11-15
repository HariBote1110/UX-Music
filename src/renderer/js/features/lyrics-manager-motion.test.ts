import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// サイドバー歌詞（#lyrics-view）の同期表示:
// - 曲の途中で歌詞パネルを開いたとき、現在行へ遷移なしで即座に合わせる
// - 大きくシークしたときも全行が一斉に流れない
// - LRC の行クリックでその行の時刻へシークする

const LRC = Array.from({ length: 12 }, (_, i) => `[00:${String(i + 1).padStart(2, '0')}.00]line ${i}`).join('\n');

let currentTime = 0;
const seek = vi.fn();

function flushFrames(): Promise<void> {
    return new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
}

async function setup(lyricsResult: unknown, { active }: { active: boolean }) {
    (window as unknown as { electronAPI: unknown }).electronAPI = {
        CHANNELS: { SEND: {}, ON: {}, INVOKE: {} },
        send: () => {},
        invoke: (channel: string) => Promise.resolve(channel === 'get-lyrics' ? lyricsResult : null),
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

    document.body.innerHTML = `
        <div id="lyrics-container" class="${active ? 'active' : ''}">
            <div id="lyrics-view"></div>
        </div>
    `;
    const { elements } = await import('../core/state.js');
    elements.lyricsView = document.getElementById('lyrics-view');
    const manager = await import('./lyrics-manager.js');
    await manager.loadLyricsForSong({ title: 't', artist: 'a', path: '/music/t.mp3' });
    return manager;
}

function lines(): HTMLElement[] {
    return Array.from(document.querySelectorAll<HTMLElement>('#lyrics-view p[data-index]'));
}

function activeIndex(): number {
    return lines().findIndex(p => p.classList.contains('active'));
}

function expectAllSnapped() {
    for (const p of lines()) {
        expect(p.style.getPropertyValue('--line-motion-duration')).toBe('0ms');
        expect(p.style.getPropertyValue('--line-motion-delay')).toBe('0ms');
    }
}

beforeEach(() => {
    currentTime = 0;
    seek.mockReset();
});

afterEach(() => {
    vi.resetModules();
    vi.doUnmock('./player.js');
    document.body.innerHTML = '';
});

describe('サイドバー歌詞: 途中から開いたときのスナップ', () => {
    it('非表示中に曲が進んでからパネルを開くと、現在行へ遷移なしで合わせる', async () => {
        const manager = await setup({ type: 'lrc', content: LRC }, { active: false });

        currentTime = 7.5; // line 6
        manager.updateSyncedLyrics(currentTime); // 非表示中は何もしない

        document.getElementById('lyrics-container')!.classList.add('active');
        await flushFrames();

        expect(activeIndex()).toBe(6);
        expectAllSnapped();

        // 次の tick で同じ行なら再アニメーションしない
        currentTime = 7.7;
        manager.updateSyncedLyrics(currentTime);
        expect(activeIndex()).toBe(6);
        expectAllSnapped();
    });
});

describe('サイドバー歌詞: 行送りとシーク', () => {
    it('隣接行への行送りはカスケードを維持し、遠くへのシークはスナップする', async () => {
        const manager = await setup({ type: 'lrc', content: LRC }, { active: true });

        manager.updateSyncedLyrics(1.5);
        manager.updateSyncedLyrics(2.5);
        expect(activeIndex()).toBe(1);
        expect(lines()[5].style.getPropertyValue('--line-motion-duration')).toBe('800ms');
        expect(lines()[5].style.getPropertyValue('--line-motion-delay')).toBe('160ms');

        manager.updateSyncedLyrics(10.5);
        expect(activeIndex()).toBe(9);
        expectAllSnapped();
    });
});

describe('サイドバー歌詞: 行クリックでシーク', () => {
    it('LRC の行をクリックするとその行の時刻へシークし、表示もその行へ移る', async () => {
        const manager = await setup({ type: 'lrc', content: LRC }, { active: true });
        manager.updateSyncedLyrics(1.5);

        lines()[8].dispatchEvent(new MouseEvent('click', { bubbles: true }));

        expect(seek).toHaveBeenCalledTimes(1);
        expect(seek).toHaveBeenCalledWith(9);
        expect(activeIndex()).toBe(8);
        expectAllSnapped();
    });

    it('txt 歌詞の行はクリックしてもシークしない', async () => {
        await setup({ type: 'txt', content: 'a\nb\nc' }, { active: true });
        const p = document.querySelector<HTMLElement>('#lyrics-view p')!;
        p.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        expect(seek).not.toHaveBeenCalled();
    });
});
