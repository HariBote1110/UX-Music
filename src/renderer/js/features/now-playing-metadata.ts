// src/renderer/js/features/now-playing-metadata.ts
/**
 * OS Now Playing / サイドカー用メタデータの純粋な導出ロジック。
 * server 側 internal/scanner/artwork.go の命名規則（SHA256ハッシュのファイル名）と
 * server/app_remote.go の hashStemFromArtworkFilename() に合わせている。
 */

const ARTWORK_HASH_LENGTH = 64;
const SUPPORTED_ARTWORK_EXTENSIONS = new Set(['.webp', '.jpg', '.jpeg', '.png']);
const HEX_PATTERN = /^[0-9a-f]+$/;

/** アートワークファイル名から SHA256 ハッシュ（stem）を抽出する。該当しなければ空文字。 */
export function deriveArtworkIdFromArtworkFilename(filename: string | undefined | null): string {
    if (typeof filename !== 'string') return '';
    const normalised = filename.trim().replace(/\\/g, '/');
    if (!normalised) return '';

    const base = normalised.split('/').pop() ?? '';
    const dotIndex = base.lastIndexOf('.');
    if (dotIndex <= 0) return '';

    const ext = base.slice(dotIndex).toLowerCase();
    if (!SUPPORTED_ARTWORK_EXTENSIONS.has(ext)) return '';

    const stem = base.slice(0, dotIndex);
    if (stem.length !== ARTWORK_HASH_LENGTH) return '';
    if (!HEX_PATTERN.test(stem)) return '';

    return stem;
}
