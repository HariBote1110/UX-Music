import { describe, expect, it } from 'vitest';
import {
    LYRICS_CASCADE_DELAY_STEP_MS,
    LYRICS_CASCADE_DURATION_MS,
    isLyricsIndexJump,
    resolveLyricsLineIndexFromTarget,
    resolveLyricsLineSeekTime,
    resolveLyricsMotionTiming,
} from './lyrics-motion.js';

// 同期歌詞の行送りアニメーション判定（サイドバー／フルスクリーン共通）。
// 途中から歌詞を開いた・大きくシークしたときに全行が 800ms＋段差遅延で
// 一斉に流れる（ぐるぐる回って見える）問題の回帰防止。
describe('isLyricsIndexJump', () => {
    it('隣接行への通常の行送りはジャンプではない', () => {
        expect(isLyricsIndexJump(-1, 0)).toBe(false);
        expect(isLyricsIndexJump(4, 5)).toBe(false);
        expect(isLyricsIndexJump(5, 4)).toBe(false);
    });

    it('ポーリング間隔内に短い行を1つ飛ばした程度（2行）はジャンプ扱いしない', () => {
        expect(isLyricsIndexJump(4, 6)).toBe(false);
    });

    it('3行以上離れた移動はジャンプ（途中から開いた・シークした）', () => {
        expect(isLyricsIndexJump(-1, 40)).toBe(true);
        expect(isLyricsIndexJump(3, 40)).toBe(true);
        expect(isLyricsIndexJump(40, 3)).toBe(true);
        expect(isLyricsIndexJump(40, -1)).toBe(true);
    });
});

describe('resolveLyricsMotionTiming', () => {
    it('通常の行送りは既存のカスケード（800ms・行差×40ms）を維持する', () => {
        expect(resolveLyricsMotionTiming(4, 5)).toEqual({
            durationMs: LYRICS_CASCADE_DURATION_MS,
            delayStepMs: LYRICS_CASCADE_DELAY_STEP_MS,
        });
        expect(LYRICS_CASCADE_DURATION_MS).toBe(800);
        expect(LYRICS_CASCADE_DELAY_STEP_MS).toBe(40);
    });

    it('大きなジャンプは遷移なしで即座にスナップする', () => {
        expect(resolveLyricsMotionTiming(-1, 40)).toEqual({ durationMs: 0, delayStepMs: 0 });
        expect(resolveLyricsMotionTiming(40, 2)).toEqual({ durationMs: 0, delayStepMs: 0 });
    });

    it('immediate 指定（表示開始・リサイズ）は行差にかかわらずスナップする', () => {
        expect(resolveLyricsMotionTiming(4, 5, true)).toEqual({ durationMs: 0, delayStepMs: 0 });
    });
});

describe('resolveLyricsLineSeekTime', () => {
    const lyrics = [
        { time: 1.5, text: 'a' },
        { time: 12.25, text: 'b' },
        { time: 30, text: 'c' },
    ];

    it('クリックした行の LRC 時刻をそのまま返す（Mobile の nowPlayingLyricsSeekTime と同じ意味）', () => {
        expect(resolveLyricsLineSeekTime(lyrics, 0)).toBe(1.5);
        expect(resolveLyricsLineSeekTime(lyrics, 1)).toBe(12.25);
        expect(resolveLyricsLineSeekTime(lyrics, 2)).toBe(30);
    });

    it('範囲外・非整数の添字は null', () => {
        expect(resolveLyricsLineSeekTime(lyrics, -1)).toBeNull();
        expect(resolveLyricsLineSeekTime(lyrics, 3)).toBeNull();
        expect(resolveLyricsLineSeekTime(lyrics, 1.5)).toBeNull();
        expect(resolveLyricsLineSeekTime(lyrics, Number.NaN)).toBeNull();
    });

    it('時刻を持たない歌詞（txt）や空配列は null', () => {
        expect(resolveLyricsLineSeekTime(null, 0)).toBeNull();
        expect(resolveLyricsLineSeekTime('plain text', 0)).toBeNull();
        expect(resolveLyricsLineSeekTime([], 0)).toBeNull();
        expect(resolveLyricsLineSeekTime([{ text: 'no time' }], 0)).toBeNull();
    });
});

describe('resolveLyricsLineIndexFromTarget', () => {
    function buildRoot(): HTMLElement {
        const root = document.createElement('div');
        root.innerHTML = `
            <p data-index="0">zero</p>
            <p data-index="1"><span class="primary">one</span><span class="tr">いち</span></p>
            <p class="no-index">plain</p>
        `;
        document.body.appendChild(root);
        return root;
    }

    it('行 p 自身または内側の span から data-index を解決する', () => {
        const root = buildRoot();
        expect(resolveLyricsLineIndexFromTarget(root.querySelector('p[data-index="0"]'), root)).toBe(0);
        expect(resolveLyricsLineIndexFromTarget(root.querySelector('.tr'), root)).toBe(1);
    });

    it('data-index を持たない要素・ルート自身・ルート外は null', () => {
        const root = buildRoot();
        expect(resolveLyricsLineIndexFromTarget(root.querySelector('.no-index'), root)).toBeNull();
        expect(resolveLyricsLineIndexFromTarget(root, root)).toBeNull();
        const outside = document.createElement('p');
        outside.dataset.index = '3';
        document.body.appendChild(outside);
        expect(resolveLyricsLineIndexFromTarget(outside, root)).toBeNull();
        expect(resolveLyricsLineIndexFromTarget(null, root)).toBeNull();
    });
});
