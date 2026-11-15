/**
 * 同期歌詞（LRC）の行送りモーション判定とクリックシーク解決。
 * サイドバー（lyrics-manager）とフルスクリーン（fullscreen-view）で共有する純粋関数群。
 */

/** 通常の行送りで各行が動く時間（ms）。overshoot 付きのカスケード。 */
export const LYRICS_CASCADE_DURATION_MS = 800;
/** 通常の行送りで、現在行からの距離 1 行ごとに加える遅延（ms）。 */
export const LYRICS_CASCADE_DELAY_STEP_MS = 40;
/**
 * これを超える行差の移動は「ジャンプ」とみなしスナップする。
 * 2 行までは、ポーリング間隔内に短い行を1つ飛ばしただけの通常再生として扱う。
 */
const LYRICS_JUMP_THRESHOLD_LINES = 2;

export interface LyricsMotionTiming {
    durationMs: number;
    delayStepMs: number;
}

const SNAP_TIMING: LyricsMotionTiming = { durationMs: 0, delayStepMs: 0 };

/** 表示中の行 prevIndex から nextIndex への移動がジャンプ（シーク・途中表示）かどうか。 */
export function isLyricsIndexJump(prevIndex: number, nextIndex: number): boolean {
    return Math.abs(nextIndex - prevIndex) > LYRICS_JUMP_THRESHOLD_LINES;
}

/**
 * 行送りの遷移時間を決める。immediate（表示開始・リサイズ）やジャンプは
 * 全行を遷移なしでスナップし、隣接行への行送りだけカスケードで動かす。
 */
export function resolveLyricsMotionTiming(
    prevIndex: number,
    nextIndex: number,
    immediate = false,
): LyricsMotionTiming {
    if (immediate || isLyricsIndexJump(prevIndex, nextIndex)) {
        return { ...SNAP_TIMING };
    }
    return {
        durationMs: LYRICS_CASCADE_DURATION_MS,
        delayStepMs: LYRICS_CASCADE_DELAY_STEP_MS,
    };
}

/** クリックされた行のシーク先（秒）。時刻付き LRC 行でなければ null。 */
export function resolveLyricsLineSeekTime(lyrics: unknown, index: number): number | null {
    if (!Array.isArray(lyrics) || !Number.isInteger(index) || index < 0 || index >= lyrics.length) {
        return null;
    }
    const time = (lyrics[index] as { time?: unknown } | null)?.time;
    return typeof time === 'number' && Number.isFinite(time) ? time : null;
}

/** クリック対象から root 配下の行 p[data-index] の添字を解決する。 */
export function resolveLyricsLineIndexFromTarget(target: EventTarget | null, root: Element): number | null {
    if (!(target instanceof Element)) {
        return null;
    }
    const line = target.closest<HTMLElement>('p[data-index]');
    if (!line || line === root || !root.contains(line)) {
        return null;
    }
    const index = Number(line.dataset.index);
    return Number.isInteger(index) ? index : null;
}
