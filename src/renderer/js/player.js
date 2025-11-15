// uxmusic/src/renderer/js/player.js

import { elements, state } from './state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
import { updatePlayingIndicators } from './ui-manager.js';
import { updateLrcEditorControls } from './lrc-editor.js';
// ▼▼▼ 修正箇所 ▼▼▼
// import { resolveArtworkPath } from './ui/utils.js'; // 不要になった
import { setEqualizerColorFromArtwork } from './ui/utils.js';
// ▲▲▲ 修正箇所 ▲▲▲
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
// ▼▼▼ 修正箇所 ▼▼▼
import {
    initAudioGraph,
    resumeAudioContext,
    setBaseGain,
    applyEqualizerSettings, // re-export のため
    setAudioOutput as setAudioOutputDevice, // re-export のため
    analyser, // re-export のため
    dataArray // re-export のため
} from './audio-graph.js';
// ▲▲▲ 修正箇所 ▲▲▲
const { ipcRenderer } = require('electron');
const path = require('path');

// ▼▼▼ 削除 (audio-graph.js へ移動) ▼▼▼
// let audioContext;
// let mainPlayerNode;
// let gainNode;
// let baseGain = 1.0;
// let eqBands = [];
// let preampGainNode;
// ▲▲▲ 削除 ▲▲▲

let localPlayer;
let currentSongType = 'local';

let onSongEndedCallback = () => {};
let onNextSongCallback = () => {};
let onPrevSongCallback = () => {};

// ▼▼▼ 削除 (audio-graph.js へ移動) ▼▼▼
// export let analyser;
// export let dataArray;
// ▲▲▲ 削除 ▲▲▲


/**
 * 現在の再生時間を取得する
 * @returns {number} 再生時間 (秒)
 */
export function getCurrentTime() {
    return localPlayer ? localPlayer.currentTime : 0;
}

/**
 * 曲の総再生時間を取得する
 * @returns {number} 総再生時間 (秒)
 */
export function getDuration() {
    return localPlayer && Number.isFinite(localPlayer.duration) ? localPlayer.duration : 0;
}

/**
 * 現在再生中かどうかを取得する
 * @returns {boolean} 再生中なら true
 */
export function isPlaying() {
    return localPlayer && !localPlayer.paused && !localPlayer.ended && localPlayer.readyState > 2;
}


/**
 * 指定した時間にシークする
 * @param {number} time - シーク先の時間 (秒)
 */
export function seek(time) {
    if (localPlayer && !isNaN(time)) {
        const duration = getDuration();
        const seekTime = Math.max(0, Math.min(time, duration));
        localPlayer.currentTime = seekTime;
        
        updateSeekUI(seekTime);
    }
}

// ▼▼▼ 削除 (audio-graph.js へ移動) ▼▼▼
// async function createAudioContext(sinkId = 'default') { ... }
// function connectAudioGraph() { ... }
// export async function resumeAudioContext() { ... }
// ▲▲▲ 削除 ▲▲▲

// ▼▼▼ 削除 (audio-graph.js へ移動) ▼▼▼
// export function applyMasterVolume() { ... }
// export function applyEqualizerSettings(settings) { ... }
// ▲▲▲ 削除 ▲▲▲

/**
 * オーディオ出力デバイスを変更する
 * (audio-graph.js のラッパー)
 * @param {string} deviceId 
 */
export async function setAudioOutput(deviceId) {
    // playerElement を渡して audio-graph の関数を呼ぶ
    await setAudioOutputDevice(deviceId, localPlayer);
}

// visualizer.js と audio-graph.js からインポートした関数を
// 他のファイル（visualizer.js, player-ui.js, equalizer.js）向けに再エクスポート
export {
    // visualizer
    toggleVisualizerEcoMode,
    setVisualizerFpsLimit,
    setVisualizerTarget,
    disconnectVisualizerObserver,
    // audio-graph
    resumeAudioContext,
    applyEqualizerSettings,
    analyser,
    dataArray,
    // utils
    setEqualizerColorFromArtwork
};


async function reinitPlayer(sinkId) {
    const wasPlaying = isPlaying();
    const currentTime = getCurrentTime();
    const currentSrc = localPlayer ? localPlayer.src : null;
    
    // 既存のプレイヤーをクリーンアップ
    if (localPlayer && localPlayer.parentNode) {
        localPlayer.pause();
        localPlayer.removeAttribute('src');
        localPlayer.load();
        localPlayer.parentNode.removeChild(localPlayer);
    }
    
    // 新しいプレイヤーを作成
    const newPlayer = document.createElement('video');
    newPlayer.id = 'main-player';
    newPlayer.playsInline = true;
    document.body.appendChild(newPlayer);
    
    // 新しいプレイヤーで initPlayer を実行
    await initPlayer(newPlayer, {
        onSongEnded: onSongEndedCallback,
        onNextSong: onNextSongCallback,
        onPrevSong: onPrevSongCallback
    }, sinkId);
    
    // 状態を復元
    if (currentSrc) {
        localPlayer.src = currentSrc;
        localPlayer.load();
        localPlayer.addEventListener('loadedmetadata', () => {
             seek(currentTime);
             if (wasPlaying) {
                 localPlayer.play().catch(e => console.error("Playback resumption failed after reinit:", e));
             }
        }, { once: true });
        localPlayer.addEventListener('error', (e) => {
             console.error("Error during player reinitialization or playback:", e);
         });
    }
}

export async function initPlayer(playerElement, callbacks, sinkId = null) {
    localPlayer = playerElement;
    onSongEndedCallback = callbacks.onSongEnded;
    onNextSongCallback = callbacks.onNextSong;
    onPrevSongCallback = callbacks.onPrevSong;
    
    const finalSinkId = sinkId || (await ipcRenderer.invoke('get-settings'))?.audioOutputId || 'default';
    
    // ▼▼▼ 修正箇所 ▼▼▼
    // AudioContext とオーディオグラフの初期化を audio-graph.js に委譲
    await initAudioGraph(localPlayer, finalSinkId);
    // ▲▲▲ 修正箇所 ▲▲▲
    
    elements.playPauseBtn.classList.remove('playing'); // 初期状態

    // <video> 要素のコアイベント
    localPlayer.addEventListener('ended', () => {
        const finishedSong = state.playbackQueue[state.currentSongIndex];
        if (state.analysedQueue.enabled && finishedSong) ipcRenderer.send('song-finished', finishedSong);
        if (typeof onSongEndedCallback === 'function') onSongEndedCallback();
        updateLrcEditorControls(false, getDuration(), getDuration());
    });
    localPlayer.addEventListener('timeupdate', () => {
        const currentTime = getCurrentTime();
        updateSyncedLyrics(currentTime);
    });
    localPlayer.addEventListener('loadedmetadata', () => {
        updateMetadataUI();
    });
    localPlayer.addEventListener('play', () => {
        updatePlaybackStateUI(true);
        resumeAudioContext(); // audio-graph からインポートした関数
        updatePlayingIndicators();
        startVisualizerLoop();
    });
    localPlayer.addEventListener('pause', () => {
        updatePlaybackStateUI(false);
        stopVisualizerLoop();
    });

    // UIコントロールの初期化
    initPlayerControls(localPlayer, {
        onNextSong: onNextSongCallback,
        onPrevSong: onPrevSongCallback
    });
}

// ▼▼▼ 削除 (utils.js へ移動済み) ▼▼▼
// async function getColorsFromArtwork(img) { ... }
// ▲▲▲ 削除 ▲▲▲

export async function play(song) {
    await stop();
    if (!song) {
        elements.playPauseBtn.classList.remove('playing');
        if ('mediaSession' in navigator) { navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = 'none'; }
        // updateNowPlayingView(null); // ui-manager.js に移管されているはず (もし残っていたら削除)
        // loadLyricsForSong(null); // lyrics-manager.js に移管されているはず (もし残っていたら削除)
        return;
    }

    const settings = await ipcRenderer.invoke('get-settings');
    const TARGET_LOUDNESS = settings?.targetLoudness ?? -18.0;

    // ▼▼▼ 修正箇所 ▼▼▼
    // ラウドネス正規化
    const savedLoudness = await ipcRenderer.invoke('get-loudness-value', song.path);
    let newBaseGain = 1.0;
    if (typeof savedLoudness === 'number' && Number.isFinite(savedLoudness)) {
        const gainDb = TARGET_LOUDNESS - savedLoudness;
        newBaseGain = Math.pow(10, gainDb / 20);
    }
    // audio-graph.js にゲインを設定
    setBaseGain(newBaseGain);
    // ▲▲▲ 修正箇所 ▲▲▲

    // メディアセッション
    if ('mediaSession' in navigator) {
        let artworkSrc = '';
        const album = state.albums.get(song.albumKey);
        const artworkData = song.artwork || (album ? album.artwork : null);
        const artworkFileName = artworkData ? (artworkData.thumbnail || artworkData.full || artworkData) : null;

        if (artworkFileName && typeof artworkFileName === 'string') {
             try {
                artworkSrc = await ipcRenderer.invoke('get-artwork-as-data-url', artworkFileName);
             } catch (error) {
                 console.error("Failed to get artwork as data URL for Media Session:", error);
                 artworkSrc = '';
             }
        }

        navigator.mediaSession.metadata = new MediaMetadata({
            title: song.title || 'Unknown Title',
            artist: song.artist || 'Unknown Artist',
            album: song.album || '',
            artwork: artworkSrc ? [{ src: artworkSrc, sizes: '100x100', type: 'image/webp' }] : []
        });
        console.log("Media session metadata set.");
    }

    // 再生
    const mode = settings?.youtubePlaybackMode || 'download';
    if (song.type === 'youtube' && mode === 'stream') {
        currentSongType = 'youtube'; elements.deviceSelectButton.disabled = true;
        console.error("YouTube streaming playback is not yet implemented in player.js");
    } else if (song.path) {
        currentSongType = 'local'; elements.deviceSelectButton.disabled = false;
        await playLocal(song);
    } else console.error("Cannot play song: Invalid song type or missing path", song);
}

export async function stop() {
    if (!localPlayer) return;
    localPlayer.pause();
    localPlayer.removeAttribute('src');
    localPlayer.load();
    elements.playPauseBtn.classList.remove('playing');
    
    stopVisualizerLoop();
    resetPlaybackUI(); 

    ipcRenderer.send('playback-stopped');
}

// --- ▼▼▼ ゴリ押し修正箇所 ▼▼▼ ---
async function playLocal(song) {
    if (!localPlayer) { console.error("Player element not found."); return; }
    const safePath = encodeURI(song.path.replace(/\\/g, '/')).replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;
    try {
        await resumeAudioContext(); // audio-graph からインポートした関数
        const playPromise = localPlayer.play(); 

        console.log(`Playing: ${song.title}`);

        if (playPromise !== undefined) {
            playPromise.then(() => {
                setTimeout(() => {
                    if (isPlaying()) { 
                        localPlayer.pause(); 
                        setTimeout(() => {
                            localPlayer.play().catch(e => {
                                console.error("Gorilla resume failed:", e);
                            });
                        }, 1);
                         console.log("Gorilla pause/resume triggered.");
                    }
                }, 50); 
            }).catch(error => {
                if (error.name !== 'AbortError') {
                    console.error(`Audio playback failed for ${song.path}:`, error);
                    onSongEndedCallback();
                }
            });
        }

    } catch (error) { 
        if (error.name !== 'AbortError') {
             console.error(`Audio playback failed (initial setup) for ${song.path}:`, error);
             onSongEndedCallback();
        }
    }
}
// --- ▲▲▲ ゴリ押し修正箇所 ▲▲▲ ---

export async function togglePlayPause() {
    await resumeAudioContext(); // audio-graph からインポートした関数
    if (!localPlayer) return;
    if (localPlayer.src && !localPlayer.paused) localPlayer.pause();
    else if (localPlayer.src) {
         try { await localPlayer.play(); }
         catch (error) { if (error.name !== 'AbortError') console.error("Toggle play failed:", error); }
    } else if (state.playbackQueue.length > 0 && state.currentSongIndex >= 0) {
        playSong(state.currentSongIndex);
    }
}

export async function seekToStart() { seek(0); }