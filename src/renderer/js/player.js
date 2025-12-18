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
    activateAudioGraph, // ▼▼▼ 変更: 新しい関数 ▼▼▼
    analyser,
    dataArray
} from './audio-graph.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let localPlayer; // 現在DOMに表示されているアクティブなプレイヤー要素
let currentSongType = 'local';

let savedCallbacks = {
    onSongEnded: () => {},
    onNextSong: () => {},
    onPrevSong: () => {}
};

// ヘルパー: 現在のプレイヤーからプロパティを取得
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

// ▼▼▼ イベントリスナーのアタッチ関数 ▼▼▼
function attachPlayerListeners(player) {
    // 既存のリスナーを重複登録しないよう、あるいは新要素なので新規登録
    // 古い要素のリスナー解除はGC任せでOK

    player.onended = () => {
        const finishedSong = state.playbackQueue[state.currentSongIndex];
        if (state.analysedQueue.enabled && finishedSong) ipcRenderer.send('song-finished', finishedSong);
        if (typeof savedCallbacks.onSongEnded === 'function') savedCallbacks.onSongEnded();
        updateLrcEditorControls(false, getDuration(), getDuration());
    };
    player.ontimeupdate = () => {
        const currentTime = player.currentTime;
        updateSyncedLyrics(currentTime);
    };
    player.onloadedmetadata = () => {
        updateMetadataUI();
        updateMediaSessionHandlers();
    };
    player.onplay = () => {
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

export async function initPlayer(playerElement, callbacks, sinkId = null) {
    localPlayer = playerElement; // 初期要素
    savedCallbacks = { ...callbacks };
    
    // 初期化時はデフォルト44.1k等のグラフを作っておく（必須ではないが）
    await initAudioGraph(localPlayer, sinkId);

    attachPlayerListeners(localPlayer);

    initPlayerControls(localPlayer, {
        onNextSong: savedCallbacks.onNextSong,
        onPrevSong: savedCallbacks.onPrevSong
    });
}

// MediaSession関連 (省略: 変更なし)
function updateMediaSessionState(state) {
    if ('mediaSession' in navigator) navigator.mediaSession.playbackState = state;
}
function updateMediaSessionHandlers() {
    if ('mediaSession' in navigator) {
        try {
            navigator.mediaSession.setActionHandler('play', () => togglePlayPause());
            navigator.mediaSession.setActionHandler('pause', () => togglePlayPause());
            navigator.mediaSession.setActionHandler('stop', () => stop());
            navigator.mediaSession.setActionHandler('previoustrack', () => { if(savedCallbacks.onPrevSong) savedCallbacks.onPrevSong(); });
            navigator.mediaSession.setActionHandler('nexttrack', () => { if(savedCallbacks.onNextSong) savedCallbacks.onNextSong(); });
            navigator.mediaSession.setActionHandler('seekto', (details) => { if (details.seekTime !== undefined) seek(details.seekTime); });
        } catch (e) {}
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
             try { const dataUrl = await ipcRenderer.invoke('get-artwork-as-data-url', src); if (dataUrl) src = dataUrl; else src = null; } catch (error) { src = null; }
        }
        if (src) {
            let type = 'image/png';
            if (src.startsWith('data:image/jpeg')) type = 'image/jpeg';
            else if (src.startsWith('data:image/webp')) type = 'image/webp';
            ['96x96', '128x128', '256x256', '384x384', '512x512'].forEach(size => artwork.push({ src, sizes: size, type }));
        }
    }
    if (artwork.length === 0) artwork.push({ src: './assets/default_artwork.png', sizes: '512x512', type: 'image/png' });
    navigator.mediaSession.metadata = new MediaMetadata({ title: song.title || 'Unknown', artist: song.artist || 'Unknown', album: song.album || '', artwork });
}

export async function play(song) {
    await stop(); // 既存再生の停止
    if (!song) return;

    const settings = await ipcRenderer.invoke('get-settings');
    const TARGET_LOUDNESS = settings?.targetLoudness ?? -18.0;
    const savedLoudness = await ipcRenderer.invoke('get-loudness-value', song.path);
    let newBaseGain = 1.0;
    if (typeof savedLoudness === 'number' && Number.isFinite(savedLoudness)) {
        const gainDb = TARGET_LOUDNESS - savedLoudness;
        newBaseGain = Math.pow(10, gainDb / 20);
    }
    setBaseGain(newBaseGain);
    setMediaSessionMetadata(song).catch(e=>{});

    if (song.path) {
        currentSongType = 'local';
        await playLocal(song);
    }
}

export async function stop() {
    if (!localPlayer) return;
    localPlayer.pause();
    // srcを空にするとロードが走るが、キャッシュしている場合は保持したい？
    // いや、停止時は止めるだけで良い。srcクリアは次の再生時でOK。
    // ただしUIリセットのためイベント発火等は必要
    stopVisualizerLoop();
    resetPlaybackUI(); 
    ipcRenderer.send('playback-stopped');
    updateMediaSessionState('none');
}

async function playLocal(song) {
    const rate = song.sampleRate || 44100;
    
    // ▼▼▼ 高速化: GraphとAudio要素をプールから取得 ▼▼▼
    const graph = await activateAudioGraph(rate);
    const newPlayer = graph.audioElement;

    // DOM上の要素を入れ替え（もし違えば）
    if (localPlayer !== newPlayer) {
        console.log(`[Player] Swapping player element for ${rate}Hz.`);
        
        // 旧プレイヤーの後始末（停止）
        if (localPlayer) {
            localPlayer.pause();
            localPlayer.removeAttribute('src'); // メモリ解放促進
        }

        // DOM置換
        // 親要素（#main-content内や隠しコンテナ）にあるはず
        const container = document.getElementById('player-container') || document.body; // 適切なコンテナへ
        // 既存の main-player IDを持つ要素を探して置換
        const oldEl = document.getElementById('main-player');
        
        // 新プレイヤーの設定
        newPlayer.id = 'main-player';
        // 属性コピーが必要ならここで行う（volumeなど）
        newPlayer.volume = localPlayer ? localPlayer.volume : 1.0;

        if (oldEl) {
            oldEl.replaceWith(newPlayer);
        } else {
            // 見つからない場合はAppend（初回など）
            // UI上の場所依存だが、基本は非表示Audioならどこでも良い
            newPlayer.style.display = 'none'; 
            document.body.appendChild(newPlayer);
        }

        localPlayer = newPlayer;
        attachPlayerListeners(localPlayer);
        
        // コントロール再初期化（シークバーなどのイベントリスナー再紐付け）
        initPlayerControls(localPlayer, {
            onNextSong: savedCallbacks.onNextSong,
            onPrevSong: savedCallbacks.onPrevSong
        });
    }
    // ▲▲▲ 高速化ここまで ▲▲▲

    const safePath = encodeURI(song.path.replace(/\\/g, '/')).replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;
    
    try {
        const playPromise = localPlayer.play();
        console.log(`Playing: ${song.title} (${rate}Hz)`);
        if (playPromise !== undefined) {
            playPromise.catch(error => {
                if (error.name !== 'AbortError') {
                    console.error(`Playback failed:`, error);
                    savedCallbacks.onSongEnded();
                }
            });
        }
    } catch (error) {
        console.error(`Playback setup failed:`, error);
    }
}

export async function togglePlayPause() {
    await resumeAudioContext();
    if (!localPlayer) return;
    if (!localPlayer.paused) {
        localPlayer.pause();
    } else {
         try { await localPlayer.play(); } catch (e) {}
    }
}
export async function seekToStart() { seek(0); }