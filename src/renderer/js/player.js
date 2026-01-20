// src/renderer/js/player.js

import { elements, state } from './state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
import { updatePlayingIndicators } from './ui-manager.js';
import { updateLrcEditorControls } from './lrc-editor.js';
import { setEqualizerColorFromArtwork } from './ui/utils.js';
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
} from './player-ui.js';
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
import { musicApi } from './bridge.js';
const electronAPI = window.electronAPI;

let localPlayer;
let currentSongType = 'local';

let savedCallbacks = {
    onSongEnded: () => { },
    onNextSong: () => { },
    onPrevSong: () => { }
};

export function getCurrentTime() {
    return localPlayer ? localPlayer.currentTime : 0;
}
export function getDuration() {
    return localPlayer && Number.isFinite(localPlayer.duration) ? localPlayer.duration : 0;
}
export function isPlaying() {
    // 準備完了状態（readyState > 2）も加味して判定
    return localPlayer && !localPlayer.paused && !localPlayer.ended && localPlayer.readyState > 2;
}

// UI操作用の関数（常に最新の localPlayer を操作する）
export async function playCurrent() {
    if (localPlayer) {
        try {
            await localPlayer.play();
        } catch (e) {
            if (e.name !== 'AbortError') console.error("Playback failed:", e);
        }
    }
}
export function pauseCurrent() {
    if (localPlayer) localPlayer.pause();
}

export function seek(time) {
    if (localPlayer && !isNaN(time)) {
        const duration = getDuration();
        const seekTime = Math.max(0, Math.min(time, duration));
        localPlayer.currentTime = seekTime;
        updateSeekUI(seekTime);
    }
}
export async function setAudioOutput(deviceId) {
    await setAudioOutputDevice(deviceId, localPlayer);
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

    // onplay よりも確実な onplaying (データが届いて動き出した時) を使用
    player.onplaying = () => {
        console.log('[Player] onplaying event fired');
        updatePlaybackStateUI(true);
        resumeAudioContext();
        updatePlayingIndicators();
        startVisualizerLoop();
        updateMediaSessionState('playing');
    };

    player.onpause = () => {
        console.log('[Player] onpause event fired');
        updatePlaybackStateUI(false);
        stopVisualizerLoop();
        updateMediaSessionState('paused');
    };
}

export async function initPlayer(playerElement, callbacks, sinkId = null) {
    localPlayer = playerElement;
    savedCallbacks = { ...callbacks };

    await initAudioGraph(localPlayer, sinkId);
    attachPlayerListeners(localPlayer);

    // コントロールの初期化はアプリ起動時のこの1回のみ
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
    setBaseGain(newBaseGain);
    setMediaSessionMetadata(song).catch(() => { });

    if (song.path) {
        currentSongType = 'local';
        musicApi.playbackStarted(song);
        await playLocal(song);
    }
}

export async function stop() {
    if (!localPlayer) return;
    localPlayer.pause();
    stopVisualizerLoop();
    resetPlaybackUI();
    electronAPI.send('playback-stopped');
    updateMediaSessionState('none');
}

async function playLocal(song) {
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

        // initPlayerControls はここから削除しました (二重登録防止)
    }

    const safePath = encodeURI(song.path.replace(/\\/g, '/')).replace(/#/g, '%23');
    const isWails = window.go !== undefined;
    localPlayer.src = isWails ? `/safe-media/${song.path}` : `file://${safePath}`;

    try {
        await localPlayer.play();
    } catch (error) {
        if (error.name !== 'AbortError') {
            console.error(`Playback failed:`, error);
            savedCallbacks.onSongEnded();
        }
    }
}

export async function togglePlayPause() {
    await resumeAudioContext();
    if (!localPlayer) return;
    if (!localPlayer.paused) {
        localPlayer.pause();
    } else {
        try { await localPlayer.play(); } catch (e) { }
    }
}
export async function seekToStart() { seek(0); }