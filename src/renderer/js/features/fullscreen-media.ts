// フルスクリーン表示における「メディア（映像/静止画ジャケット）」の
// 所在・表示切替を決める純関数群。DOM 副作用を持たないため vitest で
// 単体検証できる。公式再生（embed）のプレイヤー iframe は破棄すると
// 音声タップが切れるため「移動」で扱う必要があり、その移動先の判定を
// ここに集約する。

/** フルスクリーン左側の映像スロット（embed プレイヤーの移動先）の要素 ID。 */
export const FS_VIDEO_SLOT_ID = 'fs-video-slot';

/** サイドバー Now Playing のアートワークコンテナ（embed の通常時の所在）の要素 ID。 */
export const SIDEBAR_ARTWORK_ID = 'now-playing-artwork-container';

export interface EmbedContainerContext {
    /** フルスクリーンオーバーレイが開いているか。 */
    fullscreenOpen: boolean;
    /** 公式再生（embed）プレイヤーが稼働中か。 */
    embedActive: boolean;
}

/** Now Playing の 1:1 / 16:9 を current track と embed 状態から決める。 */
export function resolveArtworkAspectMode(
    song: unknown,
    embedActive: boolean,
): boolean {
    if (!song || typeof song !== 'object') return false;
    const track = song as { type?: unknown; hasVideo?: unknown };
    return Boolean((track.type === 'youtube' && embedActive) || track.hasVideo);
}

/** 実際の current track に基づいて Now Playing の aspect class を同期する。 */
export function syncArtworkAspect(
    container: HTMLElement,
    song: unknown,
    embedActive: boolean,
): void {
    container.classList.toggle('video-mode', resolveArtworkAspectMode(song, embedActive));
}

/**
 * 公式再生（embed）プレイヤー iframe を「どのコンテナへ置くべきか」を
 * 決める。embed が非稼働なら移動対象なし（null）。稼働中はフルスクリーンが
 * 開いていればフルスクリーンの映像スロット、そうでなければサイドバーの
 * アートワークコンテナへ置く。
 */
export function resolveEmbedContainerId(ctx: EmbedContainerContext): string | null {
    if (!ctx.embedActive) return null;
    return ctx.fullscreenOpen ? FS_VIDEO_SLOT_ID : SIDEBAR_ARTWORK_ID;
}

/**
 * フルスクリーン左側で「映像（embed）」を出すか「静止画ジャケット」を
 * 出すかを決める。embed 稼働中は映像、それ以外は静止画ジャケット。
 */
export function resolveFullscreenMediaMode(embedActive: boolean): 'video' | 'artwork' {
    return embedActive ? 'video' : 'artwork';
}
