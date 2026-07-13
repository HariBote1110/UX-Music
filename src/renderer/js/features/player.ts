// src/renderer/js/player.js

import { elements, state } from '../core/state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
import { updatePlayingIndicators } from '../ui/ui-manager.js';
import { updateLrcEditorControls } from './lrc-editor.js';
import { setEqualizerColorFromArtwork } from '../ui/utils.js';
import {
    startVisualizerLoop,
    stopVisualizerLoop,
    setVisualizerTarget,
    toggleVisualizerEcoMode,
    setVisualizerFpsLimit,
    disconnectVisualizerObserver
} from './visualizer.js';
import {
    initPlayerControls,
    updatePlaybackStateUI,
    updateMetadataUI,
    resetPlaybackUI,
    updateSeekUI
} from '../ui/player-ui.js';
import {
    initAudioGraph,
    resumeAudioContext,
    setBaseGain,
    applyEqualizerSettings,
    setAudioOutput as setAudioOutputDevice,
    activateAudioGraph,
    analyser,
    dataArray
} from './audio-graph.js';
import { musicApi, getWailsApp } from '../core/bridge.js';
import { resolveYouTubePlaybackRoute, extractYouTubeVideoId } from './youtube-embed-route.js';
import {
    mountEmbedPlayer,
    destroyEmbedPlayer,
    isEmbedPlayerActive,
    embedGetCurrentTime,
    embedGetDuration,
    embedIsPlaying,
    embedIsPaused,
    embedSeekTo,
    embedPlay,
    embedPause
} from './youtube-embed-player.js';
import { fetchEmbedEffectiveLoudness } from './youtube-embed-loudness.js';
import { resolveEmbedPlaybackGain } from './playback-gain.js';
import * as WailsApp from '../../wailsjs/go/server/App.js';
import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';
import { loadRendererSettings } from '../core/settings-helpers.js';
const electronAPI = window.electronAPI;

let localPlayer; // Web用（Go環境ではnullまたは未使用）
let currentSongType = 'local';
let isWails = false; // Wails環境フラグ

// Goバックエンドの状態キャッシュ
const goState = {
    currentTime: 0,
    duration: 0,
    isPlaying: false,
    isPaused: false
};
/** @type {ReturnType<typeof setTimeout> | null} */
let goPollTimeoutId = null;
let goPollInFlight = false;
let lastSeekAtMs = 0;
/** 公式再生（embed）中に WebView タップを開始済みかどうか */
let webViewTapStarted = false;

let savedCallbacks = {
    onSongEnded: () => { },
    onNextSong: () => { },
    onPrevSong: () => { }
};

// 状態取得関数の変更
export function getCurrentTime() {
    if (isEmbedPlayerActive()) return embedGetCurrentTime();
    if (isWails) return goState.currentTime;
    return localPlayer ? localPlayer.currentTime : 0;
}
export function getDuration() {
    if (isEmbedPlayerActive()) return embedGetDuration();
    if (isWails) return goState.duration;
    return localPlayer && Number.isFinite(localPlayer.duration) ? localPlayer.duration : 0;
}
export function isPlaying() {
    if (isEmbedPlayerActive()) return embedIsPlaying();
    if (isWails) return goState.isPlaying;
    return localPlayer && !localPlayer.paused && !localPlayer.ended && localPlayer.readyState > 2;
}

// UI操作用の関数
export async function playCurrent() {
    if (isEmbedPlayerActive()) {
        // タップは張ったまま、埋め込みプレイヤー側を再開する
        embedPlay();
    } else if (isWails) {
        await getWailsApp()?.AudioResume?.();
        // ポーリングでUI更新されるのでここでは状態強制更新しない
    } else if (localPlayer) {
        try {
            await localPlayer.play();
        } catch (e) {
            if ((e as Error).name !== 'AbortError') console.error("Playback failed:", e);
        }
    }
}
export async function pauseCurrent() {
    if (isEmbedPlayerActive()) {
        // タップは張ったまま、埋め込みプレイヤー側を一時停止する
        embedPause();
    } else if (isWails) {
        await getWailsApp()?.AudioPause?.();
    } else if (localPlayer) {
        localPlayer.pause();
    }
}

export async function seek(time) {
    const duration = getDuration();
    const seekTime = Math.max(0, Math.min(time, duration));

    if (isEmbedPlayerActive()) {
        embedSeekTo(seekTime);
        lastSeekAtMs = Date.now();
        goState.currentTime = seekTime; // 即時反映
        updateSeekUI(seekTime);
    } else if (isWails) {
        await getWailsApp()?.AudioSeek?.(seekTime);
        lastSeekAtMs = Date.now();
        goState.currentTime = seekTime; // 即時反映
        updateSeekUI(seekTime);
    } else if (localPlayer && !isNaN(time)) {
        localPlayer.currentTime = seekTime;
        updateSeekUI(seekTime);
    }
}
export async function setAudioOutput(deviceId) {
    console.log('[Player] setAudioOutput called with deviceId:', deviceId);
    if (isWails) {
        await getWailsApp()?.AudioSetDevice?.(deviceId);
        musicApi.saveSettings({ audioOutputId: deviceId });
    } else {
        await setAudioOutputDevice(deviceId, localPlayer);
    }
}

export {
    toggleVisualizerEcoMode,
    setVisualizerFpsLimit,
    setVisualizerTarget,
    disconnectVisualizerObserver,
    resumeAudioContext,
    applyEqualizerSettings,
    analyser,
    dataArray,
    setEqualizerColorFromArtwork
};

function attachPlayerListeners(player) {
    if (!player) return;

    player.onended = () => {
        const finishedSong = state.playbackQueue[state.currentSongIndex];
        if (state.analysedQueue.enabled && finishedSong) musicApi.songFinished(finishedSong);
        if (typeof savedCallbacks.onSongEnded === 'function') savedCallbacks.onSongEnded();
        updateLrcEditorControls(false, getDuration(), getDuration());
    };
    player.ontimeupdate = () => {
        updateSyncedLyrics(player.currentTime);
    };
    player.onloadedmetadata = () => {
        updateMetadataUI();
        updateMediaSessionHandlers();
    };

    player.onplaying = () => {
        updatePlaybackStateUI(true);
        resumeAudioContext();
        updatePlayingIndicators();
        startVisualizerLoop();
        updateMediaSessionState('playing');
    };

    player.onpause = () => {
        updatePlaybackStateUI(false);
        stopVisualizerLoop();
        updateMediaSessionState('paused');
    };
}

/** Lyrics panel open: tighter IPC so sync + seek UI stay responsive. */
function goPollDelayMs() {
    try {
        const lyricsEl = document.getElementById('lyrics-container');
        if (lyricsEl?.classList.contains('active')) {
            return 500;
        }
    } catch {
        /* ignore */
    }
    return 1000;
}

// Goバックエンドの状態をポーリングする関数（歌詞非表示時は間隔を延ばして IPC を削減）
function startGoStatePolling() {
    if (goPollTimeoutId != null) {
        clearTimeout(goPollTimeoutId);
        goPollTimeoutId = null;
    }

    const tick = async () => {
        goPollTimeoutId = null;
        if (!getWailsApp()) {
            goPollTimeoutId = setTimeout(tick, goPollDelayMs());
            return;
        }
        if (goPollInFlight) {
            goPollTimeoutId = setTimeout(tick, goPollDelayMs());
            return;
        }

        goPollInFlight = true;
        try {
            let pos;
            let dur;
            let playing;
            let paused;

            const app = getWailsApp();
            if (isEmbedPlayerActive()) {
                // 公式再生（embed）中: Go 側はライブ再生で位置・長さが 0 を
                // 返すため、YouTube プレイヤーから時間情報を取得する。
                pos = embedGetCurrentTime();
                dur = embedGetDuration();
                playing = embedIsPlaying();
                paused = embedIsPaused();
            } else if (typeof app?.AudioGetStatus === 'function') {
                const status = await app.AudioGetStatus();
                pos = Number(status?.position);
                dur = Number(status?.duration);
                playing = Boolean(status?.playing);
                paused = Boolean(status?.paused);
            } else {
                [pos, dur, playing, paused] = await Promise.all([
                    app.AudioGetPosition(),
                    app.AudioGetDuration(),
                    app.AudioIsPlaying(),
                    app.AudioIsPaused()
                ]);
            }

            if (!Number.isFinite(pos)) pos = 0;
            if (!Number.isFinite(dur)) dur = 0;
            playing = Boolean(playing);
            paused = Boolean(paused);

            const wasPlaying = goState.isPlaying;
            const prevPos = goState.currentTime;
            const recentSeek = Date.now() - lastSeekAtMs < 1500;
            let nextPos = pos;

            // Guard against out-of-order async poll results that momentarily rewind time.
            if (playing && wasPlaying && !recentSeek && Number.isFinite(prevPos) && pos+0.15 < prevPos) {
                nextPos = prevPos;
            }

            goState.currentTime = nextPos;
            goState.duration = dur;
            goState.isPlaying = playing;
            goState.isPaused = paused;

            if (playing) {
                updateSyncedLyrics(nextPos);
                updateSeekUI(nextPos); // UI側のシークバー更新

                if (!wasPlaying) {
                    // 再生開始時イベント相当
                    updatePlaybackStateUI(true);
                    updatePlayingIndicators();
                    updateMediaSessionState('playing');
                    startVisualizerLoop();
                }
            } else if (paused && wasPlaying) {
                // 一時停止イベント相当
                updatePlaybackStateUI(false);
                updateMediaSessionState('paused');
                stopVisualizerLoop();
            }

            // duration更新（ロード完了検知など）
            if (dur > 0 && Math.abs((state as any).currentDuration - dur) > 0.5) {
                (state as any).currentDuration = dur; // state.jsの更新はしていないが、UI更新用
                updateMetadataUI();
                updateMediaSessionHandlers();
            }

        } catch (e) {
            // エラー時は何もしない
        } finally {
            goPollInFlight = false;
        }

        goPollTimeoutId = setTimeout(tick, goPollDelayMs());
    };

    goPollTimeoutId = setTimeout(tick, goPollDelayMs());
}

export async function initPlayer(playerElement, callbacks, sinkId = null) {
    savedCallbacks = { ...callbacks };
    isWails = typeof window.go !== 'undefined';
    // Wails: output routing is via Go/PortAudio; `sinkId` is ignored (Web Audio is Electron-only).

    if (isWails) {
        console.log('[Player] Initializing in Wails mode (Go Backend)');
        localPlayer = null; // WailsではAudioElementを使わない

        startGoStatePolling();

        // Goからのイベントリスナー設定
        if (window.runtime) {
            window.runtime.EventsOn("audio-playback-finished", () => {
                console.log('[Player] audio-playback-finished received');
                const finishedSong = state.playbackQueue[state.currentSongIndex];
                if (state.analysedQueue.enabled && finishedSong) musicApi.songFinished(finishedSong);
                if (typeof savedCallbacks.onSongEnded === 'function') savedCallbacks.onSongEnded();
                updateLrcEditorControls(false, getDuration(), getDuration());
            });
        }

    } else {
        localPlayer = playerElement;
        await initAudioGraph(localPlayer, sinkId);
        attachPlayerListeners(localPlayer);
    }

    // コントロールの初期化
    initPlayerControls(localPlayer, {
        onNextSong: savedCallbacks.onNextSong,
        onPrevSong: savedCallbacks.onPrevSong
    });
    updateMediaSessionHandlers();
}

function updateMediaSessionState(state) {
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = state;
}

function setMediaSessionAction(action, handler) {
    if (!('mediaSession' in navigator)) return;
    try {
        navigator.mediaSession.setActionHandler(action, handler);
    } catch (e) {
        // Some webviews do not support every media action.
    }
}

function updateMediaSessionHandlers() {
    setMediaSessionAction('play', () => {
        if (!isPlaying()) void playCurrent();
    });
    setMediaSessionAction('pause', () => {
        if (isPlaying()) void pauseCurrent();
    });
    setMediaSessionAction('stop', () => {
        void stop();
    });
    setMediaSessionAction(
        'previoustrack',
        typeof savedCallbacks.onPrevSong === 'function' ? () => savedCallbacks.onPrevSong() : null
    );
    setMediaSessionAction(
        'nexttrack',
        typeof savedCallbacks.onNextSong === 'function' ? () => savedCallbacks.onNextSong() : null
    );
    setMediaSessionAction('seekto', (details) => {
        if (details && Number.isFinite(details.seekTime)) void seek(details.seekTime);
    });
}
async function setMediaSessionMetadata(song) {
    if (!('mediaSession' in navigator)) return;
    const artwork = [];
    const album = state.albums.get(song.albumKey);
    let artworkSource = song.artwork || (album ? album.artwork : null);
    if (typeof artworkSource === 'object' && artworkSource !== null) artworkSource = artworkSource.thumbnail || artworkSource.full;

    if (typeof artworkSource === 'string' && artworkSource) {
        let src = artworkSource;
        if (!src.startsWith('http') && !src.startsWith('https') && !src.startsWith('data:') && !src.startsWith('blob:')) {
            const normalised = src.replace(/\\/g, '/').replace(/^safe-artwork:\/\//, '/safe-artwork/');
            src = normalised.startsWith('/safe-artwork/') ? normalised : `/safe-artwork/${encodeURI(normalised).replace(/#/g, '%23')}`;
        }
        ['128x128', '256x256'].forEach(size => artwork.push({ src, sizes: size, type: 'image/png' }));
    }
    if (artwork.length === 0) artwork.push({ src: DEFAULT_ARTWORK_URL, sizes: '512x512', type: 'image/png' });
    navigator.mediaSession.metadata = new MediaMetadata({ title: song.title || 'Unknown', artist: song.artist || 'Unknown', album: song.album || '', artwork });
}

function resolveNowPlayingArtworkSource(song) {
    const album = state.albums.get(song.albumKey);
    let artworkSource = song.artwork || (album ? album.artwork : null);
    if (typeof artworkSource === 'object' && artworkSource !== null) {
        artworkSource = artworkSource.full || artworkSource.thumbnail || '';
    }

    if (typeof artworkSource !== 'string') return '';

    let source = artworkSource.trim();
    if (!source) return '';
    if (source.startsWith('http://') || source.startsWith('https://') || source.startsWith('data:') || source.startsWith('blob:')) return '';
    if (source.startsWith('./assets/')) return '';

    if (source.startsWith('/safe-artwork/')) {
        source = source.replace('/safe-artwork/', '');
    } else if (source.startsWith('safe-artwork://')) {
        source = source.replace('safe-artwork://', '');
    }

    try {
        source = decodeURIComponent(source);
    } catch (e) {
        // keep raw source when decoding fails
    }

    return source.replace(/^[/\\]+/, '');
}

async function updateOSNowPlayingMetadata(song) {
    if (!isWails) return;
    if (!getWailsApp()?.AudioSetNowPlayingMetadata) return;
    if (!song) return;

    const payload = {
        title: song.title || 'Unknown',
        artist: song.artist || 'Unknown',
        album: song.album || '',
        artwork: resolveNowPlayingArtworkSource(song)
    };

    try {
        await getWailsApp()?.AudioSetNowPlayingMetadata?.(payload);
    } catch (error) {
        console.warn('[Player] Failed to update OS now playing metadata:', error);
    }
}

/**
 * @param {number} [gainLinear=1.0] — Wails: linear gain from playback-manager (loudness). Electron: ignored; Web Audio `setBaseGain` applies.
 * @returns {Promise<boolean>} true if output playback actually started (Wails: AudioPlay resolved).
 */
export async function play(song, gainLinear = 1.0) {
    await stop();
    if (!song) return false;

    const filePath = typeof song.path === 'string' ? song.path.trim() : '';
    if (!filePath) {
        console.warn('[Player] play() skipped: no file path on song', song?.title);
        return false;
    }

    try {
        // In Wails mode, loudness is applied in Go via `gainLinear`; keep Electron path below.
        if (!isWails) {
            const settings = await loadRendererSettings();
            const TARGET_LOUDNESS =
                typeof settings.targetLoudness === 'number' && Number.isFinite(settings.targetLoudness)
                    ? settings.targetLoudness
                    : -18.0;
            const savedLoudness = await electronAPI.invoke('get-loudness-value', filePath);
            let newBaseGain = 1.0;
            if (typeof savedLoudness === 'number' && Number.isFinite(savedLoudness)) {
                const gainDb = TARGET_LOUDNESS - savedLoudness;
                newBaseGain = Math.pow(10, gainDb / 20);
            }
            setBaseGain(newBaseGain);
        }

        setMediaSessionMetadata(song).catch(() => { });
        if (isWails) {
            try {
                await updateOSNowPlayingMetadata(song);
            } catch (err) {
                console.warn('[Player] updateOSNowPlayingMetadata failed:', err);
            }
        }

        if (song.type === 'youtube' && isWails) {
            const settings = await loadRendererSettings();
            const route = resolveYouTubePlaybackRoute(song.type, settings.youtubePlaybackMode);
            if (route === 'embed') {
                return await playEmbed(song, filePath);
            }
            // ストリーミング再生: 都度 googlevideo の直接 URL を解決し（数時間で
            // 失効するため保存しない）、Go 側のネイティブパイプラインで再生する。
            const sourceUrl = typeof song.sourceURL === 'string' && song.sourceURL.trim() !== ''
                ? song.sourceURL.trim()
                : filePath;
            const streamUrl = await getWailsApp()?.ResolveYouTubeStreamURL?.(sourceUrl);
            if (typeof streamUrl !== 'string' || streamUrl.trim() === '') {
                console.error('[Player] YouTube ストリーム URL の解決に失敗しました:', sourceUrl);
                return false;
            }
            currentSongType = 'youtube';
            await playLocal({ ...song, path: streamUrl }, gainLinear);
            return true;
        }

        currentSongType = 'local';
        await playLocal({ ...song, path: filePath }, gainLinear);
        return true;
    } catch (err) {
        console.error('[Player] play failed:', err);
        return false;
    }
}

/**
 * 公式再生（embed）: Now Playing 領域に YouTube 公式プレイヤーを表示して
 * 再生し、その音声を Core Audio プロセスタップ経由でネイティブ
 * パイプライン（EQ・音量・ビジュアライザー）から出力する。
 */
async function playEmbed(song, sourceCandidate) {
    const sourceUrl = typeof song.sourceURL === 'string' && song.sourceURL.trim() !== ''
        ? song.sourceURL.trim()
        : sourceCandidate;
    const videoId = extractYouTubeVideoId(sourceUrl);
    if (!videoId) {
        console.error('[Player] YouTube 動画 ID の抽出に失敗しました:', sourceUrl);
        return false;
    }

    currentSongType = 'youtube';
    webViewTapStarted = false;

    // ラウドネス取得は再生開始と並行して先に走らせておく（正規化なしでも
    // 再生自体は始められるため、mount をブロックしない）。
    const loudnessPromise = fetchEmbedEffectiveLoudness(videoId);

    const mounted = await mountEmbedPlayer(videoId, {
        onPlaying: () => {
            // PLAYING になった時点で一度だけタップを開始する。
            // タップはポーズ中も張ったままにする（ヘルパーが無音になるだけ）。
            if (webViewTapStarted) return;
            webViewTapStarted = true;
            void getWailsApp()?.AudioStartWebViewTap?.()
                .then(() => {
                    // playLiveSource が開始時に baseGain を 1.0 に戻すため、
                    // 正規化ゲインは必ずタップ開始の解決後に適用する。
                    return applyEmbedNormalisationGain(loudnessPromise);
                })
                .catch((err) => {
                    webViewTapStarted = false;
                    console.error('[Player] WebView タップの開始に失敗しました:', err);
                });
        },
        onEnded: () => {
            // 既存の曲終了導線（playback-manager の次曲遷移）に接続する
            const finishedSong = state.playbackQueue[state.currentSongIndex];
            if (state.analysedQueue.enabled && finishedSong) musicApi.songFinished(finishedSong);
            if (typeof savedCallbacks.onSongEnded === 'function') savedCallbacks.onSongEnded();
            updateLrcEditorControls(false, getDuration(), getDuration());
        }
    });
    if (!mounted) return false;

    const slider = elements.volumeSlider;
    const rawVol = slider && typeof slider.value === 'string' ? parseFloat(slider.value) : 1;
    const volume = Number.isFinite(rawVol) ? Math.min(1, Math.max(0, rawVol)) : 1;
    await WailsApp.AudioSetVolume(volume);

    updatePlayingIndicators();
    updatePlaybackStateUI(true);
    updateMediaSessionState('playing');
    return true;
}

/**
 * 公式再生（embed）のラウドネス正規化ゲインを適用する。
 * 実効ラウドネスが取れない動画は正規化なし（1.0）のまま通常再生する。
 */
async function applyEmbedNormalisationGain(loudnessPromise: Promise<number | null>): Promise<void> {
    try {
        const [effectiveLoudness, settings] = await Promise.all([
            loudnessPromise,
            loadRendererSettings()
        ]);
        // 待機中に停止・曲切替が起きていたら適用しない（ローカル曲経路の
        // ゲインは AudioPlay が曲ごとに設定するため、上書きしない）。
        if (!isEmbedPlayerActive() || !webViewTapStarted) return;

        const targetLoudness =
            typeof settings.targetLoudness === 'number' && Number.isFinite(settings.targetLoudness)
                ? settings.targetLoudness
                : -18.0;
        const gain = resolveEmbedPlaybackGain({ effectiveLoudness, targetLoudness });
        await getWailsApp()?.AudioSetNormalisationGain?.(gain);
        const loudnessLabel = effectiveLoudness === null ? 'n/a' : effectiveLoudness.toFixed(2);
        console.log(`[Player] embed 正規化ゲイン適用: loudness=${loudnessLabel} target=${targetLoudness} gain=${gain.toFixed(4)}`);
        void getWailsApp()?.EmbedDebugLog?.(`gain-applied loudness=${loudnessLabel} target=${targetLoudness} gain=${gain.toFixed(4)}`);
    } catch (err) {
        console.warn('[Player] embed 正規化ゲインの適用に失敗しました:', err);
    }
}

export async function stop() {
    if (isWails) {
        const wasEmbed = isEmbedPlayerActive() || webViewTapStarted;
        destroyEmbedPlayer();
        try {
            if (wasEmbed) {
                // タップ捕捉を停止する（内部で Player.Stop も行われる）
                await getWailsApp()?.AudioStopWebViewTap?.();
                // embed 用の正規化ゲインを解除する（ローカル曲は AudioPlay が
                // 曲ごとにゲインを設定するが、明示的に 1.0 へ戻しておく）。
                await getWailsApp()?.AudioSetNormalisationGain?.(1.0);
            } else {
                await WailsApp.AudioStop();
            }
        } catch (err) {
            console.warn('[Player] AudioStop:', err);
        }
        webViewTapStarted = false;
        goState.isPlaying = false;
        goState.isPaused = false;
        goState.currentTime = 0;
    } else if (localPlayer) {
        localPlayer.pause();
    }
    stopVisualizerLoop();
    resetPlaybackUI();
    if (!isWails) electronAPI.send('playback-stopped');
    updateMediaSessionState('none');
}

async function playLocal(song, gainLinear = 1.0) {
    if (isWails) {
        const path = typeof song.path === 'string' ? song.path.trim() : '';
        if (!path) {
            console.warn('[Player] playLocal(Wails): empty path');
            return;
        }
        const g = Number.isFinite(gainLinear) && gainLinear > 0 ? gainLinear : 1.0;
        console.log(`[Player] Playing with Go Backend: ${path}`);
        await WailsApp.AudioPlay(path, g);
        const slider = elements.volumeSlider;
        const rawVol = slider && typeof slider.value === 'string' ? parseFloat(slider.value) : 1;
        const volume = Number.isFinite(rawVol) ? Math.min(1, Math.max(0, rawVol)) : 1;
        await WailsApp.AudioSetVolume(volume);

        updatePlayingIndicators();
        updatePlaybackStateUI(true);
        updateMediaSessionState('playing');
        return;
    }

    const rate = song.sampleRate || 44100;
    const graph = await activateAudioGraph(rate);
    const newPlayer = graph.audioElement;

    if (localPlayer !== newPlayer) {
        console.log(`[Player] Swapping player element for ${rate}Hz.`);
        if (localPlayer) {
            localPlayer.pause();
            localPlayer.removeAttribute('src');
        }

        const oldEl = document.getElementById('main-player');
        newPlayer.id = 'main-player';
        newPlayer.volume = localPlayer ? localPlayer.volume : 1.0;

        if (oldEl) {
            oldEl.replaceWith(newPlayer);
        } else {
            newPlayer.style.display = 'none';
            document.body.appendChild(newPlayer);
        }

        localPlayer = newPlayer;
        attachPlayerListeners(localPlayer);
    }

    const normalizedPath = song.path.replace(/\\/g, '/');
    const safePath = normalizedPath.split('/').map(encodeURIComponent).join('/');
    localPlayer.src = `file://${safePath}`;

    try {
        await localPlayer.play();
    } catch (error) {
        if ((error as Error).name !== 'AbortError') {
            console.error(`Playback failed for ${song.title}:`, error, 'Path:', localPlayer.src);
            savedCallbacks.onSongEnded();
        }
    }
}

export async function togglePlayPause() {
    if (isEmbedPlayerActive()) {
        if (embedIsPlaying()) {
            embedPause();
        } else {
            embedPlay();
        }
        return;
    }
    if (isWails) {
        const isPlaying = goState.isPlaying;
        if (isPlaying) {
            await getWailsApp()?.AudioPause?.();
        } else {
            await getWailsApp()?.AudioResume?.();
        }
        return;
    }

    await resumeAudioContext();
    if (!localPlayer) return;
    if (!localPlayer.paused) {
        localPlayer.pause();
    } else {
        try { await localPlayer.play(); } catch (e) { }
    }
}
export async function seekToStart() { seek(0); }
