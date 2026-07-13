// YouTube IFrame Player API の埋め込みプレイヤー管理。
// 公式再生（embed）モードで Now Playing のアートワーク領域に
// 公式プレイヤーを表示し、音声は Go 側のプロセスタップ経由で出力する。
// 規約上の理由から映像・コントロールは常に可視（controls=1）とし、
// muted にはしない（ヘルパー出力のミュートはタップ側が行う）。

interface YTPlayerLike {
    playVideo(): void;
    pauseVideo(): void;
    seekTo(seconds: number, allowSeekAhead: boolean): void;
    getCurrentTime(): number;
    getDuration(): number;
    getPlayerState(): number;
    destroy(): void;
}

interface YTNamespace {
    Player: new (element: HTMLElement, options: Record<string, unknown>) => YTPlayerLike;
    PlayerState: {
        ENDED: number;
        PLAYING: number;
        PAUSED: number;
    };
}

declare global {
    interface Window {
        YT?: YTNamespace;
        onYouTubeIframeAPIReady?: () => void;
    }
}

export interface EmbedPlayerCallbacks {
    onPlaying: () => void;
    onEnded: () => void;
}

const IFRAME_API_URL = 'https://www.youtube.com/iframe_api';
const ARTWORK_CONTAINER_ID = 'now-playing-artwork-container';

let apiReadyPromise: Promise<YTNamespace> | null = null;
let currentPlayer: YTPlayerLike | null = null;
let currentWrapper: HTMLElement | null = null;
let mountToken = 0;

/** IFrame Player API スクリプトをシングルトンとして動的ロードする。 */
function loadIframeApi(): Promise<YTNamespace> {
    if (window.YT?.Player) return Promise.resolve(window.YT);
    if (apiReadyPromise) return apiReadyPromise;

    apiReadyPromise = new Promise<YTNamespace>((resolve, reject) => {
        const previousReady = window.onYouTubeIframeAPIReady;
        window.onYouTubeIframeAPIReady = () => {
            previousReady?.();
            if (window.YT?.Player) {
                resolve(window.YT);
            } else {
                reject(new Error('YouTube IFrame API の初期化に失敗しました'));
            }
        };

        const script = document.createElement('script');
        script.src = IFRAME_API_URL;
        script.async = true;
        script.onerror = () => {
            apiReadyPromise = null;
            reject(new Error('YouTube IFrame API の読み込みに失敗しました'));
        };
        document.head.appendChild(script);
    });
    return apiReadyPromise;
}

/**
 * アートワーク領域へ埋め込みプレイヤーを生成して自動再生を開始する。
 * 生成に成功したら true を返す。
 */
export async function mountEmbedPlayer(videoId: string, callbacks: EmbedPlayerCallbacks): Promise<boolean> {
    const host = document.getElementById(ARTWORK_CONTAINER_ID);
    if (!host) {
        console.warn('[YouTubeEmbed] アートワークコンテナが見つかりません。');
        return false;
    }

    destroyEmbedPlayer();
    const token = ++mountToken;

    host.innerHTML = '';
    host.classList.add('video-mode');
    const wrapper = document.createElement('div');
    wrapper.id = 'youtube-embed-wrapper';
    const mountPoint = document.createElement('div');
    wrapper.appendChild(mountPoint);
    host.appendChild(wrapper);
    currentWrapper = wrapper;

    let yt: YTNamespace;
    try {
        yt = await loadIframeApi();
    } catch (error) {
        console.error('[YouTubeEmbed] IFrame API の準備に失敗しました:', error);
        return false;
    }
    if (token !== mountToken) return false; // 待機中に別の再生開始/停止が走った

    currentPlayer = new yt.Player(mountPoint, {
        width: '100%',
        height: '100%',
        videoId,
        playerVars: {
            autoplay: 1,
            controls: 1,
            enablejsapi: 1,
            rel: 0,
            playsinline: 1,
        },
        events: {
            onStateChange: (event: { data: number }) => {
                if (token !== mountToken) return;
                if (event.data === yt.PlayerState.PLAYING) {
                    callbacks.onPlaying();
                } else if (event.data === yt.PlayerState.ENDED) {
                    callbacks.onEnded();
                }
            },
            onError: (event: { data: number }) => {
                console.error('[YouTubeEmbed] プレイヤーエラー:', event?.data);
            },
        },
    });
    return true;
}

/** 埋め込みプレイヤーを破棄し、アートワーク領域を空に戻す。 */
export function destroyEmbedPlayer(): void {
    mountToken += 1;
    if (currentPlayer) {
        try {
            currentPlayer.destroy();
        } catch {
            // destroy は iframe が既に外れていると例外を投げることがある
        }
        currentPlayer = null;
    }
    if (currentWrapper) {
        currentWrapper.remove();
        currentWrapper = null;
    }
    const host = document.getElementById(ARTWORK_CONTAINER_ID);
    host?.classList.remove('video-mode');
}

export function isEmbedPlayerActive(): boolean {
    return currentPlayer !== null;
}

/**
 * updateNowPlayingView 等でコンテナが再描画されたとき、稼働中の
 * 埋め込みプレイヤーを新しいコンテナへ付け直す。付け直せたら true。
 */
export function reattachEmbedPlayer(container: HTMLElement): boolean {
    if (!currentPlayer || !currentWrapper) return false;
    container.classList.add('video-mode');
    container.appendChild(currentWrapper);
    return true;
}

function safeNumber(fn: () => number): number {
    if (!currentPlayer) return 0;
    try {
        const value = fn();
        return Number.isFinite(value) ? value : 0;
    } catch {
        return 0;
    }
}

export function embedGetCurrentTime(): number {
    return safeNumber(() => currentPlayer!.getCurrentTime());
}

export function embedGetDuration(): number {
    return safeNumber(() => currentPlayer!.getDuration());
}

function embedPlayerState(): number | null {
    if (!currentPlayer || typeof currentPlayer.getPlayerState !== 'function') return null;
    try {
        return currentPlayer.getPlayerState();
    } catch {
        return null;
    }
}

export function embedIsPlaying(): boolean {
    return embedPlayerState() === window.YT?.PlayerState.PLAYING;
}

export function embedIsPaused(): boolean {
    return embedPlayerState() === window.YT?.PlayerState.PAUSED;
}

export function embedSeekTo(seconds: number): void {
    if (!currentPlayer) return;
    try {
        currentPlayer.seekTo(Math.max(0, seconds), true);
    } catch {
        // 準備前の seek は無視する
    }
}

export function embedPlay(): void {
    try {
        currentPlayer?.playVideo();
    } catch {
        /* ignore */
    }
}

export function embedPause(): void {
    try {
        currentPlayer?.pauseVideo();
    } catch {
        /* ignore */
    }
}
