// YouTube 再生経路の純粋ロジック。
// 曲種別（type）と設定 youtubePlaybackMode から、実際の再生経路
// （local / stream / embed）を決定する。DOM や Wails には依存しない。

export type YouTubePlaybackRoute = 'local' | 'stream' | 'embed';

/**
 * 曲種別と設定値から再生経路を決定する。
 * - youtube 以外の曲は常に 'local'
 * - youtube 曲で設定が 'embed' のときだけ 'embed'
 * - それ以外の youtube 曲は従来どおり 'stream'（非公式ストリーミング）
 */
export function resolveYouTubePlaybackRoute(songType: unknown, youtubePlaybackMode: unknown): YouTubePlaybackRoute {
    if (songType !== 'youtube') return 'local';
    const mode = typeof youtubePlaybackMode === 'string' ? youtubePlaybackMode.trim().toLowerCase() : '';
    return mode === 'embed' ? 'embed' : 'stream';
}

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;

/**
 * YouTube の各種 URL 形式（watch / youtu.be / shorts / embed / live）から
 * 11 文字の動画 ID を抽出する。抽出できない場合は null。
 */
export function extractYouTubeVideoId(url: unknown): string | null {
    if (typeof url !== 'string' || url.trim() === '') return null;

    let parsed: URL;
    try {
        parsed = new URL(url.trim());
    } catch {
        return null;
    }

    const host = parsed.hostname.toLowerCase().replace(/^www\./, '');
    const normaliseId = (candidate: string | null | undefined): string | null => {
        const id = (candidate ?? '').trim();
        return VIDEO_ID_PATTERN.test(id) ? id : null;
    };

    if (host === 'youtu.be') {
        return normaliseId(parsed.pathname.split('/')[1]);
    }

    if (host === 'youtube.com' || host.endsWith('.youtube.com')) {
        const fromQuery = normaliseId(parsed.searchParams.get('v'));
        if (fromQuery) return fromQuery;

        const segments = parsed.pathname.split('/').filter(Boolean);
        if (segments.length >= 2 && ['shorts', 'embed', 'live', 'v'].includes(segments[0])) {
            return normaliseId(segments[1]);
        }
    }

    return null;
}

/**
 * シークバー・時間表示のソースとして埋め込みプレイヤー
 * （IFrame Player API）を使うべき経路かどうかを返す。
 * ライブ（プロセスタップ）中は Go 側の位置・長さが 0 を返すため、
 * embed 経路では YouTube プレイヤー側から時間を取る必要がある。
 */
export function usesEmbedTimeSource(route: YouTubePlaybackRoute | string): boolean {
    return route === 'embed';
}
