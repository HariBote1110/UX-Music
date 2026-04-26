// @ts-nocheck
// src/renderer/js/player.js

import { elements, state } from '../core/state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
import {
    notifyFullscreenTimeUpdate,
    notifyFullscreenPlayState,
} from './fullscreen-bridge.js';
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

let savedCallbacks = {
    onSongEnded: () => { },
    onNextSong: () => { },
    onPrevSong: () => { }
};

// 状態取得関数の変更
export function getCurrentTime() {
    if (isWails) return goState.currentTime;
    return localPlayer ? localPlayer.currentTime : 0;
}
export function getDuration() {
    if (isWails) return goState.duration;
    return localPlayer && Number.isFinite(localPlayer.duration) ? localPlayer.duration : 0;
}
export function isPlaying() {
    if (isWails) return goState.isPlaying;
    return localPlayer && !localPlayer.paused && !localPlayer.ended && localPlayer.readyState > 2;
}

// UI操作用の関数
export async function playCurrent() {
    if (isWails) {
        await getWailsApp()?.AudioResume?.();
        // ポーリングでUI更新されるのでここでは状態強制更新しない
    } else if (localPlayer) {
        try {
            await localPlayer.play();
        } catch (e) {
            if (e.name !== 'AbortError') console.error("Playback failed:", e);
        }
    }
}
export async function pauseCurrent() {
    if (isWails) {
        await getWailsApp()?.AudioPause?.();
    } else if (localPlayer) {
        localPlayer.pause();
    }
}

export async function seek(time) {
    const duration = getDuration();
    const seekTime = Math.max(0, Math.min(time, duration));

    if (isWails) {
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
        notifyFullscreenTimeUpdate(player.currentTime, player.duration ?? 0);
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
        notifyFullscreenPlayState(true);
    };

    player.onpause = () => {
        updatePlaybackStateUI(false);
        stopVisualizerLoop();
        updateMediaSessionState('paused');
        notifyFullscreenPlayState(false);
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
            if (typeof app?.AudioGetStatus === 'function') {
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
            if (dur > 0 && Math.abs(state.currentDuration - dur) > 0.5) {
                state.currentDuration = dur; // state.jsの更新はしていないが、UI更新用
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

        currentSongType = 'local';
        await playLocal({ ...song, path: filePath }, gainLinear);
        return true;
    } catch (err) {
        console.error('[Player] play failed:', err);
        return false;
    }
}

export async function stop() {
    if (isWails) {
        try {
            await WailsApp.AudioStop();
        } catch (err) {
            console.warn('[Player] AudioStop:', err);
        }
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
        if (error.name !== 'AbortError') {
            console.error(`Playback failed for ${song.title}:`, error, 'Path:', localPlayer.src);
            savedCallbacks.onSongEnded();
        }
    }
}

export async function togglePlayPause() {
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
