// Pure helpers extracted from runAutoSync() so they can be unit-tested
// without touching DOM, global editor state, or Wails bridge.

export interface LyricLine {
    text: string;
    timestamp: number | null;
}

export interface AlignedTimestamp {
    index: number;
    timestamp: number;
}

export interface AutoSyncPrereqContext {
    currentEditorSong: { path?: string } | null;
    lyricsLines: ReadonlyArray<{ text: string; [k: string]: unknown }>;
}

export interface AutoSyncPrereqResult {
    ok: boolean;
    message?: string;
}

/** Validates the four early-exit conditions before kicking off an auto-sync. */
export function validateAutoSyncPrereqs(
    ctx: AutoSyncPrereqContext,
): AutoSyncPrereqResult {
    const songPath = ctx.currentEditorSong?.path ?? '';
    if (!songPath) {
        return { ok: false, message: '同期対象の曲情報が見つかりません。' };
    }
    if (ctx.lyricsLines.length === 0) {
        return { ok: false, message: '先に歌詞テキストを読み込んでください。' };
    }
    const hasAnyContent = ctx.lyricsLines.some(line => (line.text || '').trim() !== '');
    if (!hasAnyContent) {
        return { ok: false, message: '同期対象の歌詞行がありません。' };
    }
    return { ok: true };
}

function normaliseTimestampForApply(seconds: number): number | null {
    if (!Number.isFinite(seconds)) return null;
    return Number.parseFloat(Math.max(0, seconds).toFixed(3));
}

/**
 * Writes each aligned timestamp into lines[entry.index].timestamp, in place.
 * Returns the count of entries that were actually applied (after validation).
 *
 * Mirrors the loop body in runAutoSync(): index must be an integer in-range,
 * timestamp must be a finite number, and the value is clamped to >= 0.
 */
export function applyAlignedTimestamps(
    lines: LyricLine[],
    aligned: ReadonlyArray<AlignedTimestamp>,
): number {
    let applied = 0;
    for (const entry of aligned) {
        if (!Number.isInteger(entry?.index)) continue;
        if (entry.index < 0 || entry.index >= lines.length) continue;
        if (typeof entry.timestamp !== 'number' || Number.isNaN(entry.timestamp)) continue;
        const normalised = normaliseTimestampForApply(entry.timestamp);
        if (normalised === null) continue;
        lines[entry.index].timestamp = normalised;
        applied += 1;
    }
    return applied;
}
