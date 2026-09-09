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
import { extractYouTubeVideoId } from './youtube-embed-route.js';

export interface EmbedPlayerCallbacks {
    onPlaying: () => void;
    onEnded: () => void;
}

const ARTWORK_CONTAINER_ID = 'now-playing-artwork-container';
const SIDEBAR_WRAPPER_Z_INDEX = '1';
const FULLSCREEN_WRAPPER_Z_INDEX = '9001';
const FULLSCREEN_CLOSE_BUTTON_Z_INDEX = '9002';
const POSITION_SETTLE_FRAME_COUNT = 24;

interface EmbedSession {
    videoId: string;
    iframe: HTMLIFrameElement;
    wrapper: HTMLElement;
    container: HTMLElement;
    callbacks: EmbedPlayerCallbacks;
    /** ホストページからの time メッセージで更新されるキャッシュ。 */
    currentTime: number;
    duration: number;
    state: number;
}

let currentSession: EmbedSession | null = null;
let mountToken = 0;
let messageListenerAttached = false;
let positionObserver: ResizeObserver | null = null;
let layoutObserver: MutationObserver | null = null;
let settleFrameId: number | null = null;
let settleFramesRemaining = 0;

interface DetachedFullscreenCloseButton {
    button: HTMLElement;
    parent: Node;
    nextSibling: ChildNode | null;
    position: string;
    zIndex: string;
}

let detachedFullscreenCloseButton: DetachedFullscreenCloseButton | null = null;

function syncWrapperPosition(session: EmbedSession): void {
    const rect = session.container.getBoundingClientRect();
    const isHidden = session.container.hidden
        || getComputedStyle(session.container).display === 'none';
    session.wrapper.style.left = `${rect.left}px`;
    session.wrapper.style.top = `${rect.top}px`;
    session.wrapper.style.width = `${rect.width}px`;
    session.wrapper.style.height = `${rect.height}px`;
    session.wrapper.style.display = !isHidden && rect.width > 0 && rect.height > 0 ? 'block' : 'none';
}

function handlePositionChange(): void {
    if (currentSession) syncWrapperPosition(currentSession);
}

function attachPositionListeners(): void {
    window.addEventListener('resize', handlePositionChange);
    window.addEventListener('scroll', handlePositionChange, true);
}

function detachPositionListeners(): void {
    window.removeEventListener('resize', handlePositionChange);
    window.removeEventListener('scroll', handlePositionChange, true);
}

function disconnectPositionObserver(): void {
    positionObserver?.disconnect();
    positionObserver = null;
}

function observeContainer(container: HTMLElement): void {
    disconnectPositionObserver();
    if (typeof ResizeObserver === 'undefined') return;
    positionObserver = new ResizeObserver(handlePositionChange);
    positionObserver.observe(container);
}

function observeLayoutChanges(): void {
    layoutObserver?.disconnect();
    if (typeof MutationObserver === 'undefined') return;

    // class/hidden の切替や view の再描画は、対象のサイズが変わらなくても
    // 位置を変え得る。wrapper の style 属性は監視せず、自己更新の連鎖を防ぐ。
    layoutObserver = new MutationObserver(handlePositionChange);
    layoutObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['class', 'hidden'],
        childList: true,
        subtree: true,
    });
}

function disconnectLayoutObserver(): void {
    layoutObserver?.disconnect();
    layoutObserver = null;
}

function stopPositionSettle(): void {
    if (settleFrameId !== null) {
        window.cancelAnimationFrame(settleFrameId);
        settleFrameId = null;
    }
    settleFramesRemaining = 0;
}

function runPositionSettle(): void {
    settleFrameId = null;
    if (!currentSession || settleFramesRemaining <= 0) return;

    syncWrapperPosition(currentSession);
    settleFramesRemaining -= 1;
    if (settleFramesRemaining > 0) {
        settleFrameId = window.requestAnimationFrame(runPositionSettle);
    }
}

function startPositionSettle(): void {
    settleFramesRemaining = POSITION_SETTLE_FRAME_COUNT;
    if (settleFrameId === null && typeof window.requestAnimationFrame === 'function') {
        settleFrameId = window.requestAnimationFrame(runPositionSettle);
    }
}

function promoteFullscreenCloseButton(): void {
    if (detachedFullscreenCloseButton) return;
    const button = document.getElementById('fs-close-btn');
    if (!button || button.parentElement === document.body) return;

    detachedFullscreenCloseButton = {
        button,
        parent: button.parentNode,
        nextSibling: button.nextSibling,
        position: button.style.position,
        zIndex: button.style.zIndex,
    };
    document.body.appendChild(button);
    button.style.position = 'fixed';
    button.style.zIndex = FULLSCREEN_CLOSE_BUTTON_Z_INDEX;
}

function isFullscreenContainer(container: HTMLElement): boolean {
    return container.id === 'fs-video-slot';
}

function restoreFullscreenCloseButton(): void {
    const detached = detachedFullscreenCloseButton;
    if (!detached) return;

    detached.button.style.position = detached.position;
    detached.button.style.zIndex = detached.zIndex;
    if (detached.nextSibling?.parentNode === detached.parent) {
        detached.parent.insertBefore(detached.button, detached.nextSibling);
    } else {
        detached.parent.appendChild(detached.button);
    }
    detachedFullscreenCloseButton = null;
}

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
    // iframe は DOM 上の親を一度だけ body に固定する。WebKit は iframe を
    // 別の親へ appendChild するとページを再読込するため、表示先の矩形だけ
    // を fixed 要素へ反映してフルスクリーンとの切替を行う。
    wrapper.style.position = 'fixed';
    wrapper.style.zIndex = SIDEBAR_WRAPPER_Z_INDEX;
    wrapper.style.overflow = 'hidden';
    wrapper.style.pointerEvents = 'auto';
    const iframe = document.createElement('iframe');
    iframe.src = embedUrl;
    iframe.allow = 'autoplay; encrypted-media; fullscreen';
    iframe.style.width = '100%';
    iframe.style.height = '100%';
    iframe.style.border = '0';
    iframe.style.display = 'block'; // inline 既定だと baseline 分の隙間が出る
    wrapper.appendChild(iframe);
    document.body.appendChild(wrapper);

    ensureMessageListener();
    currentSession = {
        videoId,
        iframe,
        wrapper,
        container: host,
        callbacks,
        currentTime: 0,
        duration: 0,
        state: -1,
    };
    attachPositionListeners();
    observeContainer(host);
    observeLayoutChanges();
    syncWrapperPosition(currentSession);
    return true;
}

/** 埋め込みプレイヤーを破棄し、アートワーク領域を空に戻す。 */
export function destroyEmbedPlayer(): void {
    mountToken += 1;
    stopPositionSettle();
    disconnectPositionObserver();
    disconnectLayoutObserver();
    detachPositionListeners();
    restoreFullscreenCloseButton();
    if (currentSession) {
        currentSession.container.classList.remove('video-mode');
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
 * キューの current track と embed セッションを同期する。キュー経路では
 * player.ts の stop() を通らず Go が直接ローカル曲を開始するため、ここを
 * 実際の current track に基づく embed のライフサイクル境界にする。
 */
export function syncEmbedPlayerForTrack(song: {
    type?: unknown;
    sourceURL?: unknown;
    path?: unknown;
} | null | undefined): void {
    if (!currentSession) return;
    if (song?.type !== 'youtube') {
        destroyEmbedPlayer();
        return;
    }

    const source = typeof song.sourceURL === 'string' && song.sourceURL.trim() !== ''
        ? song.sourceURL
        : song.path;
    const videoId = extractYouTubeVideoId(source);
    if (videoId !== currentSession.videoId) destroyEmbedPlayer();
}

/** Now Playing の再描画前に、コンテナを embed 管理下で空に戻す。 */
export function resetEmbedArtworkContainer(container: HTMLElement): void {
    if (currentSession?.wrapper.parentElement === container) {
        currentSession.wrapper.remove();
    }
    container.replaceChildren();
    container.classList.remove('video-mode');
}

/**
 * updateNowPlayingView 等でコンテナが再描画されたとき、稼働中の
 * 埋め込みプレイヤーの表示先を更新する。iframe は body 配下の固定ホスト
 * に残したまま、表示先の矩形と aspect class だけを同期する。
 */
export function reattachEmbedPlayer(container: HTMLElement): boolean {
    if (!currentSession) return false;
    const previousContainer = currentSession.container;
    const containerChanged = previousContainer !== container;
    const wasFullscreen = isFullscreenContainer(previousContainer);
    const isFullscreen = isFullscreenContainer(container);
    if (containerChanged) {
        currentSession.container.classList.remove('video-mode');
        currentSession.container = container;
        observeContainer(container);
    }
    container.classList.add('video-mode');
    currentSession.wrapper.style.zIndex = isFullscreen
        ? FULLSCREEN_WRAPPER_Z_INDEX
        : SIDEBAR_WRAPPER_Z_INDEX;
    if (isFullscreen) {
        promoteFullscreenCloseButton();
    } else {
        restoreFullscreenCloseButton();
    }
    syncWrapperPosition(currentSession);
    if (containerChanged || isFullscreen !== wasFullscreen) startPositionSettle();
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
