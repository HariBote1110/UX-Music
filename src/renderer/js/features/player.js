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
    analyser,
    dataArray
} from './audio-graph.js';
import { musicApi } from '../core/bridge.js';
const electronAPI = window.electronAPI;

let localPlayer; // Web用（Go環境ではnullまたは未使用）
let currentSongType = 'local';
let isWails = false; // Wails環境フラグ

// Goバックエンドの状態キャッシュ
let goState = {
    currentTime: 0,
    duration: 0,
    isPlaying: false,
    isPaused: false
};
let pollingInterval = null;
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
        await window.go.main.App.AudioResume();
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
        await window.go.main.App.AudioPause();
    } else if (localPlayer) {
        localPlayer.pause();
    }
}

export async function seek(time) {
    const duration = getDuration();
    const seekTime = Math.max(0, Math.min(time, duration));

    if (isWails) {
        await window.go.main.App.AudioSeek(seekTime);
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
        await window.go.main.App.AudioSetDevice(deviceId);
        await window.go.main.App.SaveSettings({ audioOutputId: deviceId });
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

// Goバックエンドの状態をポーリングする関数
function startGoStatePolling() {
    if (pollingInterval) clearInterval(pollingInterval);

    pollingInterval = setInterval(async () => {
        if (goPollInFlight) return;
        if (!window.go || !window.go.main || !window.go.main.App) return;

        goPollInFlight = true;
        try {
            const [pos, dur, playing, paused] = await Promise.all([
                window.go.main.App.AudioGetPosition(),
                window.go.main.App.AudioGetDuration(),
                window.go.main.App.AudioIsPlaying(),
                window.go.main.App.AudioIsPaused()
            ]);

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
    }, 200);
}

export async function initPlayer(playerElement, callbacks, sinkId = null) {
    savedCallbacks = { ...callbacks };
    isWails = typeof window.go !== 'undefined';

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
}

function updateMediaSessionState(state) {
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = state;
}
function updateMediaSessionHandlers() {
    if ('mediaSession' in navigator) {
        try {
            navigator.mediaSession.setActionHandler('play', () => togglePlayPause());
            navigator.mediaSession.setActionHandler('pause', () => togglePlayPause());
            navigator.mediaSession.setActionHandler('stop', () => stop());
            navigator.mediaSession.setActionHandler('previoustrack', () => { if (savedCallbacks.onPrevSong) savedCallbacks.onPrevSong(); });
            navigator.mediaSession.setActionHandler('nexttrack', () => { if (savedCallbacks.onNextSong) savedCallbacks.onNextSong(); });
            navigator.mediaSession.setActionHandler('seekto', (details) => { if (details.seekTime !== undefined) seek(details.seekTime); });
        } catch (e) { }
    }
}
async function setMediaSessionMetadata(song) {
    if (!('mediaSession' in navigator)) return;
    const artwork = [];
    const album = state.albums.get(song.albumKey);
    let artworkSource = song.artwork || (album ? album.artwork : null);
    if (typeof artworkSource === 'object' && artworkSource !== null) artworkSource = artworkSource.full || artworkSource.thumbnail;

    if (typeof artworkSource === 'string' && artworkSource) {
        let src = artworkSource;
        if (!src.startsWith('http') && !src.startsWith('https') && !src.startsWith('data:') && !src.startsWith('blob:')) {
            try { const dataUrl = await electronAPI.invoke('get-artwork-as-data-url', artworkSource); if (dataUrl) src = dataUrl; } catch (error) { }
        }
        ['96x96', '128x128', '256x256', '384x384', '512x512'].forEach(size => artwork.push({ src, sizes: size, type: 'image/png' }));
    }
    if (artwork.length === 0) artwork.push({ src: './assets/default_artwork.png', sizes: '512x512', type: 'image/png' });
    navigator.mediaSession.metadata = new MediaMetadata({ title: song.title || 'Unknown', artist: song.artist || 'Unknown', album: song.album || '', artwork });
}

export async function play(song) {
    await stop();
    if (!song) return;

    const settings = await electronAPI.invoke('get-settings');
    const TARGET_LOUDNESS = settings?.targetLoudness ?? -18.0;
    const savedLoudness = await electronAPI.invoke('get-loudness-value', song.path);
    let newBaseGain = 1.0;
    if (typeof savedLoudness === 'number' && Number.isFinite(savedLoudness)) {
        const gainDb = TARGET_LOUDNESS - savedLoudness;
        newBaseGain = Math.pow(10, gainDb / 20);
    }

    if (isWails) {
        // Go側でボリューム制御を行う（baseGain * masterVolume）
        // 現状の簡易実装ではAPIがないため、後でAudioPlayer側でBaseGain対応が必要かも
        // とりあえずVolume設定だけ呼んでおく（UIのSlider値は反映されないので注意）
        // TODO: BaseGainとMasterVolumeを統合
    } else {
        setBaseGain(newBaseGain);
    }

    setMediaSessionMetadata(song).catch(() => { });

    if (song.path) {
        currentSongType = 'local';
        await playLocal(song);
    }
}

export async function stop() {
    if (isWails) {
        await window.go.main.App.AudioStop();
        goState.isPlaying = false;
        goState.isPaused = false;
        goState.currentTime = 0;
    } else if (localPlayer) {
        localPlayer.pause();
    }
    stopVisualizerLoop();
    resetPlaybackUI();
    electronAPI.send('playback-stopped');
    updateMediaSessionState('none');
}

async function playLocal(song) {
    if (isWails) {
        console.log(`[Player] Playing with Go Backend: ${song.path}`);
        try {
            await window.go.main.App.AudioPlay(song.path);
            // Volume適用（初期値）
            const volume = parseFloat(elements.volumeSlider.value);
            await window.go.main.App.AudioSetVolume(volume);

            updatePlayingIndicators();
            updatePlaybackStateUI(true);
            updateMediaSessionState('playing');
        } catch (e) {
            console.error('[Player] Go AudioPlay failed:', e);
            savedCallbacks.onSongEnded(); // エラー時は次の曲へ
        }
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
    const safePath = encodeURI(normalizedPath).replace(/#/g, '%23');
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
            await window.go.main.App.AudioPause();
        } else {
            await window.go.main.App.AudioResume();
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
