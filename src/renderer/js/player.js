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
    analyser,
    dataArray
} from './audio-graph.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let localPlayer;
let currentSongType = 'local';

let onSongEndedCallback = () => {};
let onNextSongCallback = () => {};
let onPrevSongCallback = () => {};

export function getCurrentTime() {
    return localPlayer ? localPlayer.currentTime : 0;
}

export function getDuration() {
    return localPlayer && Number.isFinite(localPlayer.duration) ? localPlayer.duration : 0;
}

export function isPlaying() {
    return localPlayer && !localPlayer.paused && !localPlayer.ended && localPlayer.readyState > 2;
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

export async function initPlayer(playerElement, callbacks, sinkId = null) {
    localPlayer = playerElement;
    onSongEndedCallback = callbacks.onSongEnded;
    onNextSongCallback = callbacks.onNextSong;
    onPrevSongCallback = callbacks.onPrevSong;
    
    const finalSinkId = sinkId || (await ipcRenderer.invoke('get-settings'))?.audioOutputId || 'default';
    
    await initAudioGraph(localPlayer, finalSinkId);
    
    elements.playPauseBtn.classList.remove('playing');

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
        updateMediaSessionHandlers();
    });
    localPlayer.addEventListener('play', () => {
        updatePlaybackStateUI(true);
        resumeAudioContext();
        updatePlayingIndicators();
        startVisualizerLoop();
        updateMediaSessionState('playing');
    });
    localPlayer.addEventListener('pause', () => {
        updatePlaybackStateUI(false);
        stopVisualizerLoop();
        updateMediaSessionState('paused');
    });

    initPlayerControls(localPlayer, {
        onNextSong: onNextSongCallback,
        onPrevSong: onPrevSongCallback
    });
}

function updateMediaSessionState(state) {
    if ('mediaSession' in navigator) {
        navigator.mediaSession.playbackState = state;
    }
}

function updateMediaSessionHandlers() {
    if ('mediaSession' in navigator) {
        try {
            navigator.mediaSession.setActionHandler('play', () => { togglePlayPause(); });
            navigator.mediaSession.setActionHandler('pause', () => { togglePlayPause(); });
            navigator.mediaSession.setActionHandler('stop', () => { stop(); });
            navigator.mediaSession.setActionHandler('previoustrack', () => { 
                if(onPrevSongCallback) onPrevSongCallback(); 
            });
            navigator.mediaSession.setActionHandler('nexttrack', () => { 
                if(onNextSongCallback) onNextSongCallback(); 
            });
            navigator.mediaSession.setActionHandler('seekto', (details) => { 
                if (details.seekTime !== undefined) seek(details.seekTime); 
            });
        } catch (e) {
            console.warn('Media Session actions setup failed:', e);
        }
    }
}

// --- ▼▼▼ MediaSession用アートワーク設定処理 ▼▼▼ ---
async function setMediaSessionMetadata(song) {
    if (!('mediaSession' in navigator)) return;

    const artwork = [];
    const album = state.albums.get(song.albumKey);
    let artworkSource = song.artwork || (album ? album.artwork : null);
    
    if (typeof artworkSource === 'object' && artworkSource !== null) {
         artworkSource = artworkSource.full || artworkSource.thumbnail;
    }

    if (typeof artworkSource === 'string' && artworkSource) {
        let src = artworkSource;
        
        // http/https/dataスキーム以外（ローカルファイル）は全てDataURLに変換する
        if (!src.startsWith('http') && !src.startsWith('https') && !src.startsWith('data:') && !src.startsWith('blob:')) {
             try {
                // メインプロセスでファイルを読み込み、Base64のData URLとして取得
                const dataUrl = await ipcRenderer.invoke('get-artwork-as-data-url', src);
                if (dataUrl) {
                    src = dataUrl;
                } else {
                    src = null; // 取得失敗時はデフォルトへ
                }
             } catch (error) {
                 console.error("Failed to convert artwork to Data URL:", error);
                 src = null;
             }
        }

        if (src) {
            // MIMEタイプ推定 (DataURLなら既に含まれているが、念のため拡張子もチェック)
            let type = 'image/png';
            if (src.startsWith('data:image/jpeg')) type = 'image/jpeg';
            else if (src.startsWith('data:image/webp')) type = 'image/webp';
            
            // 複数のサイズ定義を作成してOSに渡す
            const sizes = ['96x96', '128x128', '256x256', '384x384', '512x512'];
            sizes.forEach(size => {
                artwork.push({ src, sizes: size, type });
            });
        }
    }

    // アートワークがない、または読み込みに失敗した場合はデフォルト画像
    if (artwork.length === 0) {
        artwork.push({ src: './assets/default_artwork.png', sizes: '512x512', type: 'image/png' });
    }

    navigator.mediaSession.metadata = new MediaMetadata({
        title: song.title || 'Unknown Title',
        artist: song.artist || 'Unknown Artist',
        album: song.album || '',
        artwork: artwork
    });
}
// --- ▲▲▲ ここまで ▲▲▲ ---


export async function play(song) {
    await stop();
    if (!song) {
        elements.playPauseBtn.classList.remove('playing');
        if ('mediaSession' in navigator) { 
            navigator.mediaSession.metadata = null; 
            navigator.mediaSession.playbackState = 'none'; 
        }
        return;
    }

    const settings = await ipcRenderer.invoke('get-settings');
    const TARGET_LOUDNESS = settings?.targetLoudness ?? -18.0;

    const savedLoudness = await ipcRenderer.invoke('get-loudness-value', song.path);
    let newBaseGain = 1.0;
    if (typeof savedLoudness === 'number' && Number.isFinite(savedLoudness)) {
        const gainDb = TARGET_LOUDNESS - savedLoudness;
        newBaseGain = Math.pow(10, gainDb / 20);
    }
    setBaseGain(newBaseGain);

    // --- 再生開始と並行してメタデータを設定 ---
    setMediaSessionMetadata(song).catch(err => console.error("Metadata update failed:", err));

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
    updateMediaSessionState('none');
}

async function playLocal(song) {
    if (!localPlayer) { console.error("Player element not found."); return; }
    
    // ローカル再生用のパス構築（fileプロトコルはvideoタグでは有効だがMediaSessionでは無効）
    // URLエンコードと#のエスケープ処理
    const safePath = encodeURI(song.path.replace(/\\/g, '/')).replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;
    
    try {
        await resumeAudioContext();
        const playPromise = localPlayer.play(); 

        console.log(`Playing: ${song.title}`);

        if (playPromise !== undefined) {
            playPromise.then(() => {
                setTimeout(() => {
                    // Gorilla Pause/Resume Hack for AudioContext sync issues
                    if (isPlaying()) { 
                        localPlayer.pause(); 
                        setTimeout(() => {
                            localPlayer.play().catch(e => {
                                console.error("Gorilla resume failed:", e);
                            });
                        }, 1);
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

export async function togglePlayPause() {
    await resumeAudioContext();
    if (!localPlayer) return;
    if (localPlayer.src && !localPlayer.paused) {
        localPlayer.pause();
    } else if (localPlayer.src) {
         try { await localPlayer.play(); }
         catch (error) { if (error.name !== 'AbortError') console.error("Toggle play failed:", error); }
    } else if (state.playbackQueue.length > 0 && state.currentSongIndex >= 0) {
        playSong(state.currentSongIndex);
    }
}

export async function seekToStart() { seek(0); }