import { describe, expect, it } from 'vitest';
import {
    buildJaLrcFileContent,
    buildJaTxtFileContent,
    buildLyricsTranslationPrompt,
    deriveLyricsFileBase,
    formatLrcTimestamp,
    mergeLrcWithJaLrc,
    mergeLrcWithJaTxt,
    mergePlainTxtWithJa,
    parseLRC,
    parseNumberedLinesFromPastedText,
} from './lyrics-translation.js';

describe('parseLRC', () => {
    it('preserves time order', () => {
        const r = parseLRC('[00:02.00]Second\n[00:01.00]First\n');
        expect(r[0].text).toBe('First');
        expect(r[0].time).toBe(1);
        expect(r[1].time).toBe(2);
    });
});

describe('mergeLrcWithJaLrc', () => {
    it('attaches by timestamp', () => {
        const en = parseLRC('[00:10.00]Hello');
        const ja = parseLRC('[00:10.00]こんにちは');
        const m = mergeLrcWithJaLrc(en, ja);
        expect(m[0].translation).toBe('こんにちは');
    });

    it('falls back to same index when primary timestamp is missing in ja', () => {
        const en = parseLRC('[00:00.00]A');
        const ja = parseLRC('[00:10.00]あ');
        const m = mergeLrcWithJaLrc(en, ja);
        expect(m[0].translation).toBe('あ');
    });

    it('drops Japanese on blank English lines (interlude)', () => {
        const en = parseLRC('[00:00.00]A\n[00:01.00]\n[00:02.00]C');
        const ja = parseLRC('[00:00.00]あ\n[00:01.00]間奏\n[00:02.00]う');
        const m = mergeLrcWithJaLrc(en, ja);
        expect(m[0].translation).toBe('あ');
        expect(m[1].translation).toBeUndefined();
        expect(m[2].translation).toBe('う');
    });
});

describe('mergeLrcWithJaTxt', () => {
    it('zips by line order', () => {
        const en = parseLRC('[00:00.00]A\n[00:01.00]B');
        const m = mergeLrcWithJaTxt(en, 'あ\nい');
        expect(m[0].translation).toBe('あ');
        expect(m[1].translation).toBe('い');
    });
});

describe('mergePlainTxtWithJa', () => {
    it('zips lines', () => {
        const m = mergePlainTxtWithJa('One\nTwo', 'いち\nに');
        expect(m[0].text).toBe('One');
        expect(m[0].translation).toBe('いち');
        expect(m[1].translation).toBe('に');
    });

    it('omits translation on blank English lines', () => {
        const m = mergePlainTxtWithJa('One\n\nThree', 'いち\n間奏\nさん');
        expect(m[1].translation).toBeUndefined();
        expect(m[2].translation).toBe('さん');
    });
});

describe('buildLyricsTranslationPrompt', () => {
    it('includes title and numbered lines', () => {
        const p = buildLyricsTranslationPrompt({
            title: 'Test',
            artist: 'Unit',
            lines: ['Hello', 'World'],
        });
        expect(p).toContain('Title: Test');
        expect(p).toContain('Artist: Unit');
        expect(p).toContain('1. Hello');
        expect(p).toContain('2. World');
        expect(p).toContain('exactly 2 lines');
    });

    it('uses interlude placeholder for blank lines so numbering is not lost', () => {
        const p = buildLyricsTranslationPrompt({
            title: 'T',
            artist: 'A',
            lines: ['a', '', 'c'],
        });
        expect(p).toContain('3. c');
        expect(p).toContain('2. [INTERLUDE:');
        expect(p).toMatch(/2\.\s+\[INTERLUDE:/);
    });
});

describe('formatLrcTimestamp', () => {
    it('renders one minute and centiseconds', () => {
        expect(formatLrcTimestamp(65.5)).toBe('[01:05.50]');
    });
});

describe('buildJaLrcFileContent', () => {
    it('adds one Japanese line per English timed line', () => {
        const en = parseLRC('[00:00.00]A\n[00:01.00]B');
        const t = buildJaLrcFileContent(en, ['あ', 'い']);
        expect(t).toContain('[00:00.00] あ');
        expect(t).toContain('[00:01.00] い');
    });

    it('writes timestamp only for blank English lines', () => {
        const en = parseLRC('[00:00.00]A\n[00:01.00]\n[00:02.00]C');
        const t = buildJaLrcFileContent(en, ['あ', '間奏', 'う']);
        expect(t).toContain('[00:00.00] あ');
        expect(t).toMatch(/\[00:01\.00\]\n/);
        expect(t).not.toContain('間奏');
        expect(t).toContain('[00:02.00] う');
    });
});

describe('buildJaTxtFileContent', () => {
    it('clears saved text for blank English rows when englishLines is passed', () => {
        const s = buildJaTxtFileContent(['いち', '間奏', 'さん'], ['One', '', 'Three']);
        const lines = s.trimEnd().split('\n');
        expect(lines[1]).toBe('');
        expect(s).not.toContain('間奏');
    });
});

describe('parseNumberedLinesFromPastedText', () => {
    it('parses numbered list', () => {
        const r = parseNumberedLinesFromPastedText('1. 一\n2. 二\n', 2);
        expect(r.ok).toBe(true);
        if (r.ok) {
            expect(r.lines).toEqual(['一', '二']);
        }
    });

    it('accepts fullwidth digits in numbers', () => {
        const r = parseNumberedLinesFromPastedText('１. 一\n２. 二\n', 2);
        expect(r.ok).toBe(true);
        if (r.ok) {
            expect(r.lines).toEqual(['一', '二']);
        }
    });

    it('accepts unnumbered when line count matches', () => {
        const r = parseNumberedLinesFromPastedText('一\n二', 2);
        expect(r.ok).toBe(true);
    });
});

describe('deriveLyricsFileBase', () => {
    it('uses filename stem with underscores to spaces', () => {
        expect(deriveLyricsFileBase({ path: '/M/a/foo_bar.mp3' })).toBe('foo bar');
    });
});
