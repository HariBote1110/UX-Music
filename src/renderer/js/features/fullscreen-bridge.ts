// @ts-nocheck
// フルスクリーンウィンドウとのBroadcastChannel ブリッジ

const CHANNEL_NAME = 'ux-music-fullscreen';

let bc: BroadcastChannel | null = null;
let fullscreenWindow: Window | null = null;

// 最後に送った状態（新しいフルスクリーンウィンドウが開いた際に再送するため）
let lastSong: { title: string; artist: string; artworkSrc: string } | null = null;
let lastColour1 = '';
let lastColour2 = '';
let lastLyrics: any = null;
let lastLyricsType: string | null = null;
let lastIsPlaying = false;
let lastCurrentTime = 0;
let lastDuration = 0;

function ensureChannel() {
    if (bc) return bc;
    bc = new BroadcastChannel(CHANNEL_NAME);
    bc.addEventListener('message', handleControlMessage);
    return bc;
}

function handleControlMessage(event) {
    const msg = event.data;
    if (!msg || !msg.type) return;

    if (msg.type === 'fullscreen-ready') {
        // フルスクリーンウィンドウが準備完了 — 現在の状態を全送信する
        sendFullState();
        return;
    }

    if (msg.type === 'control') {
        dispatchControlAction(msg.action, msg.value);
    }
}

function sendFullState() {
    const channel = ensureChannel();
    channel.postMessage({
        type: 'state-update',
        song: lastSong,
        colour1: lastColour1,
        colour2: lastColour2,
        lyrics: lastLyrics,
        lyricsType: lastLyricsType,
        isPlaying: lastIsPlaying,
        currentTime: lastCurrentTime,
        duration: lastDuration,
    });
}

function dispatchControlAction(action: string, value: any) {
    // 動的importで循環参照を回避する
    switch (action) {
        case 'toggle-play':
            void import('./player.js').then(({ togglePlayPause }) => togglePlayPause());
            break;
        case 'prev':
            void import('./playback-manager.js').then(({ playPrevSong }) => playPrevSong());
            break;
        case 'next':
            void import('./playback-manager.js').then(({ playNextSong }) => playNextSong());
            break;
        case 'shuffle':
            void import('./playback-manager.js').then(({ toggleShuffle }) => toggleShuffle());
            break;
        case 'loop':
            void import('./playback-manager.js').then(({ toggleLoopMode }) => toggleLoopMode());
            break;
        case 'seek':
            if (typeof value === 'number') {
                void import('./player.js').then(({ seek }) => seek(value));
            }
            break;
        default:
            break;
    }
}

// ---- 公開API ----

/**
 * フルスクリーンウィンドウを新しいウィンドウで開く
 */
export function openFullscreenWindow() {
    ensureChannel();
    const url = new URL('./fullscreen.html', window.location.href).href;
    fullscreenWindow = window.open(url, 'ux-music-fullscreen', 'width=1280,height=800');
}

/**
 * 曲情報の更新を通知する
 */
export function notifyFullscreenSongChange(title: string, artist: string, artworkSrc: string) {
    lastSong = { title, artist, artworkSrc };
    ensureChannel().postMessage({
        type: 'state-update',
        song: lastSong,
    });
}

/**
 * 背景グラデーション色の更新を通知する
 */
export function notifyFullscreenColours(colour1: string, colour2: string) {
    lastColour1 = colour1;
    lastColour2 = colour2;
    ensureChannel().postMessage({
        type: 'colour-update',
        colour1,
        colour2,
    });
}

/**
 * 歌詞データの更新を通知する
 */
export function notifyFullscreenLyrics(lyrics: any, lyricsType: string | null) {
    lastLyrics = lyrics;
    lastLyricsType = lyricsType;
    ensureChannel().postMessage({
        type: 'state-update',
        lyrics,
        lyricsType,
    });
}

/**
 * 再生位置の更新を通知する（高頻度）
 */
export function notifyFullscreenTimeUpdate(currentTime: number, duration: number) {
    lastCurrentTime = currentTime;
    lastDuration = duration;
    ensureChannel().postMessage({
        type: 'time-update',
        currentTime,
        duration,
    });
}

/**
 * 再生/一時停止状態の更新を通知する
 */
export function notifyFullscreenPlayState(isPlaying: boolean) {
    lastIsPlaying = isPlaying;
    ensureChannel().postMessage({
        type: 'play-state',
        isPlaying,
    });
}
