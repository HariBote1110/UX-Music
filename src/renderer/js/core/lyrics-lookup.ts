/**
 * 歌詞検索キューの候補名を作る。Electron（env-setup）と Wails（bridge）の両経路で共有する。
 * 候補は「ファイル名（拡張子なし）→ 曲名」の順。空や重複は除く。
 */
export function lyricsLookupCandidates(song: { path?: unknown; title?: unknown } | null | undefined): string[] {
    const candidates: string[] = [];
    const songPath = typeof song?.path === 'string' ? song.path.trim() : '';
    const songTitle = typeof song?.title === 'string' ? song.title.trim() : '';

    if (songPath) {
        const fileName = songPath.split(/[\\/]/).pop() || '';
        const dotIndex = fileName.lastIndexOf('.');
        const baseName = dotIndex > 0 ? fileName.slice(0, dotIndex) : fileName;
        if (baseName.trim()) {
            candidates.push(baseName.trim());
        }
    }
    if (songTitle) {
        candidates.push(songTitle);
    }

    return [...new Set(candidates)];
}

/**
 * 候補を順に getLyrics へ渡し、最初に type が 'lrc' または 'txt' の結果を返す。見つからなければ null。
 */
export async function findLyricsWithCandidates(
    getLyrics: (name: string) => Promise<unknown>,
    song: { path?: unknown; title?: unknown } | null | undefined,
): Promise<unknown | null> {
    for (const candidate of lyricsLookupCandidates(song)) {
        const result = await getLyrics(candidate);
        if (result && typeof result === 'object') {
            const type = (result as { type?: unknown }).type;
            if (type === 'lrc' || type === 'txt') {
                return result;
            }
        }
    }
    return null;
}
