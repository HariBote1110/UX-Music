// LAN 中継（/v1/remote/relay）へ渡すサムネイル URL の解決。
// DOM や Wails には依存しない純粋ロジック。
//
// 実際に「利用可能な最高解像度」まで絞り込む（maxresdefault が存在しない
// 動画のフォールバック）のは Go 側 resolveRelayThumbnailURL の役目
// （server/app_remote_relay_thumbnail.go）。ここでは動画IDが分かっている
// 限り常に maxresdefault 候補を渡す — Go 側が到達可能性をプローブして
// sddefault/hqdefault へ段階的にフォールバックする。

/** 指定の YouTube 動画IDに対する最高品質サムネイル候補（maxresdefault）のURL。 */
export function highestQualityYouTubeThumbnailURL(videoId: string): string {
    return `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`;
}

type ArtworkLike = string | { thumbnail?: string; full?: string } | null | undefined;

/**
 * LAN 中継（NotifyYouTubePlaybackState）へ渡すサムネイル候補 URL を決める。
 * 動画IDが分かる場合は常に maxresdefault 候補を返す（Go 側が実在確認して
 * 段階的にフォールバックする）。動画IDが取れない場合のみ、ライブラリの
 * artwork（文字列 or {thumbnail,full}）にフォールバックする。
 */
export function resolveRelayThumbnailCandidate(
    song: { artwork?: ArtworkLike } | null | undefined,
    videoId: string | null | undefined
): string {
    if (videoId) return highestQualityYouTubeThumbnailURL(videoId);

    const artwork = song?.artwork;
    if (typeof artwork === 'string') return artwork;
    if (artwork && typeof artwork === 'object') return artwork.thumbnail || artwork.full || '';
    return '';
}
