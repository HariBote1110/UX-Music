import { describe, it, expect } from 'vitest';
import { deriveArtworkIdFromArtworkFilename } from './now-playing-metadata.js';

const HASH64 = 'a'.repeat(64);

describe('deriveArtworkIdFromArtworkFilename', () => {
    it('64桁16進数のファイル名（拡張子付き）から stem を取り出す', () => {
        expect(deriveArtworkIdFromArtworkFilename(`${HASH64}.webp`)).toBe(HASH64);
        expect(deriveArtworkIdFromArtworkFilename(`${HASH64}.jpg`)).toBe(HASH64);
    });

    it('パス区切りが含まれていてもファイル名部分だけを見る', () => {
        expect(deriveArtworkIdFromArtworkFilename(`thumbnails/${HASH64}.png`)).toBe(HASH64);
        expect(deriveArtworkIdFromArtworkFilename(`thumbnails\\${HASH64}.png`)).toBe(HASH64);
    });

    it('拡張子が対応外なら空文字', () => {
        expect(deriveArtworkIdFromArtworkFilename(`${HASH64}.gif`)).toBe('');
    });

    it('stem がハッシュ形式でなければ空文字', () => {
        expect(deriveArtworkIdFromArtworkFilename('cover.jpg')).toBe('');
    });

    it('空や未定義なら空文字', () => {
        expect(deriveArtworkIdFromArtworkFilename('')).toBe('');
        expect(deriveArtworkIdFromArtworkFilename(undefined)).toBe('');
    });
});
