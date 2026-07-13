// YouTube 公式再生（embed）モードの埋め込みプレイヤー管理。
//
// Wails のページは wails:// という独自スキームで動くため、ここから直接
// IFrame Player API を使うと YouTube へ有効な HTTP Referer / origin が
// 渡らず、エラー 153（Referer 欠落による埋め込み拒否）になる。そこで
// Go 側のループバックホスト（http://127.0.0.1:<port>/embed?v=<id>）が
// 配信するページに公式プレイヤーを置き、本体とは postMessage で
// 制御・状態を中継する（プロトコルは youtube-embed-bridge.ts）。
//
// 規約上の理由から映像・コントロールは常に可視（controls=1）とする。
// 再生はミュートで開始し（生音爆音の防止）、プロセスタップ確立後に
// embedUnmute() で音を出す。以後はタップの mutedWhenTapped が
// ヘルパーのシステム出力を消し、音声は Go パイプライン経由でのみ鳴る。

import { getWailsApp } from '../core/bridge.js';
import {
    parseEmbedHostMessage,
    buildEmbedCommand,
    EMBED_PLAYER_STATE,
    type EmbedCommand,
} from './youtube-embed-bridge.js';

export interface EmbedPlayerCallbacks {
    onPlaying: () => void;
    onEnded: () => void;
}

const ARTWORK_CONTAINER_ID = 'now-playing-artwork-container';

interface EmbedSession {
    iframe: HTMLIFrameElement;
    wrapper: HTMLElement;
    callbacks: EmbedPlayerCallbacks;
    /** ホストページからの time メッセージで更新されるキャッシュ。 */
    currentTime: number;
    duration: number;
    state: number;
}

let currentSession: EmbedSession | null = null;
let mountToken = 0;
let messageListenerAttached = false;

/**
 * 埋め込みプレイヤーのイベントを console と Go 側の構造化ログ
 * （E2E 判定用）の両方へ出力する。
 */
function embedLog(message: string): void {
    console.log(`[YouTubeEmbed] ${message}`);
    try {
        void getWailsApp()?.EmbedDebugLog?.(message);
    } catch {
        /* ログ失敗は無視 */
    }
}

/** ホストページ（iframe）からの postMessage を受けて状態キャッシュと導線を更新する。 */
function handleHostMessage(event: MessageEvent): void {
    const session = currentSession;
    if (!session) return;
    if (event.source !== session.iframe.contentWindow) return;

    const message = parseEmbedHostMessage(event.data);
    if (!message) return;

    switch (message.type) {
        case 'ready':
            embedLog(`ready iframeSrc=${session.iframe.src}`);
            break;
        case 'state':
            embedLog(`state=${message.state}${message.state === EMBED_PLAYER_STATE.PLAYING ? ' PLAYING' : message.state === EMBED_PLAYER_STATE.ENDED ? ' ENDED' : ''}`);
            session.state = message.state;
            if (message.state === EMBED_PLAYER_STATE.PLAYING) {
                session.callbacks.onPlaying();
            } else if (message.state === EMBED_PLAYER_STATE.ENDED) {
                session.callbacks.onEnded();
            }
            break;
        case 'error':
            console.error('[YouTubeEmbed] プレイヤーエラー:', message.code);
            embedLog(`error=${message.code}`);
            break;
        case 'time':
            session.currentTime = message.currentTime;
            session.duration = message.duration;
            session.state = message.state;
            break;
    }
}

function ensureMessageListener(): void {
    if (messageListenerAttached) return;
    window.addEventListener('message', handleHostMessage);
    messageListenerAttached = true;
}

/** 稼働中のホストページへ制御コマンドを送る。 */
function sendCommand(command: EmbedCommand): void {
    const target = currentSession?.iframe.contentWindow;
    if (!target) return;
    try {
        target.postMessage(command, '*');
    } catch {
        /* iframe が外れた直後などは無視 */
    }
}

/**
 * アートワーク領域へ埋め込みプレイヤー（ループバックホストの iframe）を
 * 生成して自動再生を開始する。生成に成功したら true を返す。
 */
export async function mountEmbedPlayer(videoId: string, callbacks: EmbedPlayerCallbacks): Promise<boolean> {
    const host = document.getElementById(ARTWORK_CONTAINER_ID);
    if (!host) {
        console.warn('[YouTubeEmbed] アートワークコンテナが見つかりません。');
        return false;
    }

    destroyEmbedPlayer();
    const token = ++mountToken;

    let embedUrl = '';
    try {
        embedUrl = (await getWailsApp()?.GetYouTubeEmbedURL?.(videoId)) ?? '';
    } catch (error) {
        console.error('[YouTubeEmbed] 埋め込み URL の取得に失敗しました:', error);
        return false;
    }
    if (embedUrl === '') {
        console.error('[YouTubeEmbed] 埋め込み URL が取得できません（Wails バインディング未提供）。');
        return false;
    }
    if (token !== mountToken) return false; // 待機中に別の再生開始/停止が走った

    embedLog(`mount video=${videoId} embedUrl=${embedUrl} location=${window.location.href} referrer=${document.referrer || '(empty)'} origin=${window.location.origin}`);

    host.innerHTML = '';
    host.classList.add('video-mode');
    const wrapper = document.createElement('div');
    wrapper.id = 'youtube-embed-wrapper';
    // コンテナ（aspect-ratio でサイズが決まる）に常に追従させる。
    // wrapper の高さが auto のままだと、内側 iframe の height:100% が
    // 解決できず、サイドバーのリサイズに高さが追従しない。
    wrapper.style.width = '100%';
    wrapper.style.height = '100%';
    const iframe = document.createElement('iframe');
    iframe.src = embedUrl;
    iframe.allow = 'autoplay; encrypted-media; fullscreen';
    iframe.style.width = '100%';
    iframe.style.height = '100%';
    iframe.style.border = '0';
    iframe.style.display = 'block'; // inline 既定だと baseline 分の隙間が出る
    wrapper.appendChild(iframe);
    host.appendChild(wrapper);

    ensureMessageListener();
    currentSession = {
        iframe,
        wrapper,
        callbacks,
        currentTime: 0,
        duration: 0,
        state: -1,
    };
    return true;
}

/** 埋め込みプレイヤーを破棄し、アートワーク領域を空に戻す。 */
export function destroyEmbedPlayer(): void {
    mountToken += 1;
    if (currentSession) {
        currentSession.wrapper.remove();
        currentSession = null;
    }
    const host = document.getElementById(ARTWORK_CONTAINER_ID);
    host?.classList.remove('video-mode');
}

export function isEmbedPlayerActive(): boolean {
    return currentSession !== null;
}

/**
 * updateNowPlayingView 等でコンテナが再描画されたとき、稼働中の
 * 埋め込みプレイヤーを新しいコンテナへ付け直す。付け直せたら true。
 *
 * 注意: iframe を DOM 上で移動すると WebKit はページを再読込するが、
 * ホストページは同じ URL のため自動再生から再開する。
 */
export function reattachEmbedPlayer(container: HTMLElement): boolean {
    if (!currentSession) return false;
    container.classList.add('video-mode');
    container.appendChild(currentSession.wrapper);
    return true;
}

export function embedGetCurrentTime(): number {
    return currentSession?.currentTime ?? 0;
}

export function embedGetDuration(): number {
    return currentSession?.duration ?? 0;
}

export function embedIsPlaying(): boolean {
    return currentSession?.state === EMBED_PLAYER_STATE.PLAYING;
}

export function embedIsPaused(): boolean {
    return currentSession?.state === EMBED_PLAYER_STATE.PAUSED;
}

export function embedSeekTo(seconds: number): void {
    sendCommand(buildEmbedCommand('seek', seconds));
}

export function embedPlay(): void {
    sendCommand(buildEmbedCommand('play'));
}

export function embedPause(): void {
    sendCommand(buildEmbedCommand('pause'));
}

/**
 * ホストページのミュートを解除して音を出す。埋め込みは常にミュートで
 * 開始する（生音爆音の防止）ため、プロセスタップ確立後にこれを呼んで
 * 初めて音声がタップ経由の Go パイプラインへ流れる。
 */
export function embedUnmute(): void {
    sendCommand(buildEmbedCommand('unmute'));
}
