/**
 * Bilingual lyrics: merge English (main) with Japanese sidecar and build LLM prompts.
 */

export type LrcLine = {
    time: number;
    text: string;
    sourceLine?: number;
    translation?: string;
};

export type PlainLyricLine = {
    text: string;
    translation?: string;
};

const timeRegex = /\[(\d{2})[:.](\d{2})[.](\d{2,3})\]/g;

export function parseLRC(lrcContent: string): LrcLine[] {
    const lines = lrcContent.split('\n');
    const lyrics: LrcLine[] = [];

    lines.forEach((line, sourceLine) => {
        const text = line.replace(timeRegex, '').trim();
        const matches = [...line.matchAll(timeRegex)];

        if (matches.length > 0) {
            matches.forEach(match => {
                const minutes = Number.parseInt(match[1], 10);
                const seconds = Number.parseInt(match[2], 10);
                const milliseconds = Number.parseInt(match[3].padEnd(3, '0'), 10);
                const time = minutes * 60 + seconds + milliseconds / 1000;

                lyrics.push({ time, text: text || ' ', sourceLine });
            });
        }
    });

    lyrics.sort((a, b) => (a.time - b.time) || (a.sourceLine ?? 0) - (b.sourceLine ?? 0));

    /** 同一タイムスタンプの連続行は二分探索が末尾だけ選ぶため、微増で単調にする */
    for (let i = 1; i < lyrics.length; i += 1) {
        const prevT = lyrics[i - 1].time;
        if (lyrics[i].time <= prevT) {
            lyrics[i].time = prevT + 1e-4;
        }
    }

    return lyrics;
}

function timeKey(time: number): number {
    return Math.round(time * 1000) / 1000;
}

/** True when the primary lyric line has no visible words (instrumental / blank). */
export function isBlankPrimaryLine(text: string | undefined): boolean {
    return text === undefined || text.trim() === '';
}

/**
 * Merge primary LRC with Japanese LRC that uses the same timestamps.
 * Interludes (blank English) never show Japanese, even if the sidecar has 間奏 etc.
 */
export function mergeLrcWithJaLrc(primary: LrcLine[], jaLines: LrcLine[]): LrcLine[] {
    const byTime = new Map<number, string>();
    for (const j of jaLines) {
        const k = timeKey(j.time);
        if (!byTime.has(k)) {
            byTime.set(k, j.text);
        }
    }
    return primary.map((line, i) => {
        if (isBlankPrimaryLine(line.text)) {
            return { ...line, translation: undefined };
        }
        const k = timeKey(line.time);
        const fromTime = byTime.get(k);
        const fromIndex = jaLines[i]?.text;
        const pick = fromTime !== undefined ? fromTime : fromIndex;
        const trimmed = pick !== undefined && pick.trim() !== '' ? pick : undefined;
        return { ...line, translation: trimmed };
    });
}

/**
 * One Japanese line per timed primary line (same order as sorted LRC entries).
 */
export function mergeLrcWithJaTxt(primary: LrcLine[], jaTxt: string): LrcLine[] {
    const jaRows = splitLyricsLines(jaTxt);
    return primary.map((line, i) => {
        if (isBlankPrimaryLine(line.text)) {
            return { ...line, translation: undefined };
        }
        const t = i < jaRows.length ? jaRows[i] : undefined;
        const trimmed = t !== undefined && t.trim() !== '' ? t : undefined;
        return { ...line, translation: trimmed };
    });
}

function splitLyricsLines(text: string): string[] {
    if (!text) {
        return [];
    }
    return text.split('\n');
}

/**
 * Line-by-line TXT + ja.txt
 */
export function mergePlainTxtWithJa(mainTxt: string, jaTxt: string): PlainLyricLine[] {
    const en = splitLyricsLines(mainTxt);
    const ja = splitLyricsLines(jaTxt);
    const n = Math.max(en.length, ja.length);
    const out: PlainLyricLine[] = [];
    for (let i = 0; i < n; i += 1) {
        const text = en[i] !== undefined ? (en[i].trim() === '' ? ' ' : en[i]) : ' ';
        let tr = ja[i] !== undefined && ja[i].trim() !== '' ? ja[i] : undefined;
        if (isBlankPrimaryLine(text)) {
            tr = undefined;
        }
        out.push({ text, translation: tr });
    }
    return out;
}

/** Shown in the prompt in place of an empty/whitespace English line (instrumental / 間奏). */
export const LYRICS_INTERLUDE_PLACEHOLDER =
    '[INTERLUDE: no English line on this line — you must still output a separate numbered line; use 間奏, …, ～, or leave nothing after the number; do NOT move the next verse up into this number]';

export function buildLyricsTranslationPrompt(opts: {
    title: string;
    artist: string;
    lines: string[];
}): string {
    const title = (opts.title || '').trim() || '(untitled)';
    const artist = (opts.artist || '').trim() || '(unknown artist)';
    const n = opts.lines.length;
    const body = opts.lines
        .map((line, i) => {
            const t = line.replace(/\n/g, ' ').trim();
            if (t === '') {
                return `${i + 1}. ${LYRICS_INTERLUDE_PLACEHOLDER}`;
            }
            return `${i + 1}. ${t}`;
        })
        .join('\n');
    return [
        'The following is song lyrics in English. Translate into natural Japanese so that numbered item N in your output corresponds to line N of the list below (same count, no skipping).',
        `There are exactly ${n} lines. You must return exactly ${n} numbered items (1. … through ${n}. …). No extra commentary before the list.`,
        'If a line is an interlude (marked with [INTERLUDE: …]), keep the same number in your list, but you may leave the text after the number empty. The app hides Japanese on blank English lines. Never renumber or merge a later line into the interlude’s number.',
        'Output format: a numbered list in Japanese only. No titles or explanations before 1.',
        '',
        `Title: ${title}`,
        `Artist: ${artist}`,
        '',
        'English lines (one list item = one LRC/line slot; do not change numbering):',
        body,
    ].join('\n');
}

/**
 * Renders a timestamp in [mm:ss.xx] form (LRC line prefix).
 */
export function formatLrcTimestamp(timeSeconds: number): string {
    if (!Number.isFinite(timeSeconds)) {
        return '[00:00.00]';
    }
    const m = Math.floor(timeSeconds / 60);
    const s = timeSeconds - m * 60;
    const whole = Math.floor(s);
    const centis = Math.min(99, Math.round((s - whole) * 100));
    return `[${String(m).padStart(2, '0')}:${String(whole).padStart(2, '0')}.${String(centis).padStart(2, '0')}]`;
}

/**
 * Builds a .ja.lrc file body: same number of lines as the primary timed lyrics, in order.
 * Blank English lines (interludes) are written as timestamp-only; Japanese text is omitted.
 */
export function buildJaLrcFileContent(englishParsed: LrcLine[], jaLines: string[]): string {
    if (englishParsed.length === 0) {
        return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < englishParsed.length; i += 1) {
        const t = formatLrcTimestamp(englishParsed[i].time);
        if (isBlankPrimaryLine(englishParsed[i].text)) {
            parts.push(t);
        } else {
            const j = (jaLines[i] ?? '').trim() || ' ';
            parts.push(`${t} ${j}`);
        }
    }
    return `${parts.join('\n')}\n`;
}

/**
 * Joins ja lines for a .ja.txt sidecar (one line per main lyric line when main is .txt).
 * For blank English lines, the saved line is empty (no 間奏 text).
 */
export function buildJaTxtFileContent(jaLines: string[], englishLines: string[] | null = null): string {
    const body = jaLines.map((l, i) => {
        if (englishLines && englishLines[i] !== undefined && isBlankPrimaryLine(englishLines[i])) {
            return '';
        }
        return l.trimEnd();
    });
    return `${body.join('\n')}\n`;
}

export type ParsedPasteResult = { ok: true; lines: string[] } | { ok: false; reason: string };

const numberedLineRe = /^\s*(\d+)[.)、．:：]\s*(.*)$/;

/**
 * Interprets pasted LLM output: numbered list (1. / 1) / 1、) or plain lines in order.
 */
export function parseNumberedLinesFromPastedText(
    pasted: string,
    expectedCount: number
): ParsedPasteResult {
    if (expectedCount < 1) {
        return { ok: false, reason: '歌詞行がありません' };
    }
    const raw = pasted.replace(/\r\n/g, '\n');
    if (!raw.trim()) {
        return { ok: false, reason: '貼り付け内容が空です' };
    }
    const byIndex = new Map<number, string>();
    for (const line of raw.split('\n')) {
        const normalised = line.replace(/[０-９]/g, ch =>
            String.fromCharCode(ch.charCodeAt(0) - 0xfee0)
        );
        const m = normalised.match(numberedLineRe);
        if (m) {
            const n = Number.parseInt(m[1], 10);
            if (n >= 1) {
                byIndex.set(n, m[2].trim());
            }
        }
    }
    if (byIndex.size > 0) {
        const lines: string[] = [];
        for (let i = 1; i <= expectedCount; i += 1) {
            lines.push(byIndex.get(i) ?? '');
        }
        return { ok: true, lines };
    }
    const onlyNonEmpty = raw
        .split('\n')
        .map(l => l.trim())
        .filter(l => l.length > 0);
    if (onlyNonEmpty.length === expectedCount) {
        return { ok: true, lines: onlyNonEmpty };
    }
    return {
        ok: false,
        reason: `行数が一致しません（英語歌詞 ${expectedCount} 行に対し、空行除く ${onlyNonEmpty.length} 行）。1. 2. … の番号付き形式で貼り付けてください。`,
    };
}

/**
 * First candidate base name, aligned with Go FindLyrics (underscore → space, then server-side sanitise on save).
 */
export function deriveLyricsFileBase(song: { path?: string; title?: string } | null): string {
    if (!song) {
        return '';
    }
    const p = typeof song.path === 'string' ? song.path.trim() : '';
    if (p) {
        const name = p.split(/[\\/]/).pop() || '';
        const d = name.lastIndexOf('.');
        const base = d > 0 ? name.slice(0, d) : name;
        if (base.trim()) {
            return base.replaceAll('_', ' ').trim();
        }
    }
    const t = typeof song.title === 'string' ? song.title.trim() : '';
    return t.replaceAll('_', ' ').trim();
}
