// uxmusic/src/renderer/js/player.js

import { elements, state } from './state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
import { updatePlayingIndicators } from './ui-manager.js';
import { updateLrcEditorControls } from './lrc-editor.js';
import { resolveArtworkPath } from './ui/utils.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let audioContext;
let mainPlayerNode;
let gainNode;
let baseGain = 1.0;
let eqBands = [];
let preampGainNode;


let localPlayer;
let currentSongType = 'local';

let onSongEndedCallback = () => {};
let onNextSongCallback = () => {};
let onPrevSongCallback = () => {};
let lastVolume = 0.5;

let isSeeking = false;
let wasPlayingBeforeSeek = false;

let analyser;
let dataArray;
let visualizerFrameId;

let currentVisualizerBars = null;
let observedTarget = null;
let lastHeights = new Array(6).fill(4);

let lastFrameTime = 0;

let progressUpdateInterval = null; // 時間表示用のタイマー
let progressFrameId = null; // シークバー用のフレームID
let visualizerObserver = null;
let isVisualizerVisible = false;
let isEcoModeEnabled = true;


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
        if (!isSeeking && elements.progressBar) {
             elements.progressBar.value = seekTime;
             elements.currentTimeEl.textContent = formatTime(seekTime);
        }
        updateLrcEditorControls(isPlaying(), seekTime, duration);
    }
}

/**
 * シークバーの位置を滑らかに更新するためのアニメーションループ
 */
function updateProgressBarLoop() {
    if (!isPlaying() || isSeeking) {
        progressFrameId = null;
        return;
    }
    const currentTime = getCurrentTime();
    const duration = getDuration();
    elements.progressBar.value = currentTime;
    updateLrcEditorControls(true, currentTime, duration);
    progressFrameId = requestAnimationFrame(updateProgressBarLoop);
}


async function createAudioContext(sinkId = 'default') {
    if (audioContext) {
        if (audioContext.state !== 'closed') {
             try {
                 await audioContext.close();
             } catch (e) {
                 console.error("Error closing previous AudioContext:", e);
             }
        }
    }
    try {
        const contextOptions = {};
        if (sinkId && sinkId !== 'default' && typeof AudioContext.prototype.setSinkId === 'function') {
             audioContext = new (window.AudioContext || window.webkitAudioContext)();
             try {
                 await audioContext.setSinkId(sinkId);
                 console.log(`AudioContext sinkId set to: ${sinkId}`);
             } catch (err) {
                 console.error(`Failed to set sinkId '${sinkId}', falling back to default. Error:`, err);
                 await audioContext.close();
                 audioContext = new (window.AudioContext || window.webkitAudioContext)();
             }
        } else {
             audioContext = new (window.AudioContext || window.webkitAudioContext)();
             console.log(`AudioContext created with default sinkId.`);
        }
        return audioContext;
    } catch (e) {
        console.error('Failed to create AudioContext:', e);
        try {
            audioContext = new (window.AudioContext || window.webkitAudioContext)();
            return audioContext;
        } catch (fallbackError) {
             console.error('Fallback AudioContext creation failed:', fallbackError);
             return null;
        }
    }
}

function connectAudioGraph() {
    if (!audioContext || !localPlayer || audioContext.state === 'closed') {
         console.warn("Cannot connect audio graph: AudioContext not ready or closed, or player not ready.");
         return;
    }
    try {
        if (mainPlayerNode) {
            try {
                 mainPlayerNode.disconnect();
            } catch (e) {
                 // Ignore error
            }
        }

        mainPlayerNode = audioContext.createMediaElementSource(localPlayer);
        preampGainNode = audioContext.createGain();

        const frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
        eqBands = frequencies.map((freq, i) => {
            const filter = audioContext.createBiquadFilter();
            if (i === 0) filter.type = 'lowshelf';
            else if (i === frequencies.length - 1) filter.type = 'highshelf';
            else { filter.type = 'peaking'; filter.Q.value = 1.41; }
            filter.frequency.value = freq;
            filter.gain.value = 0;
            return filter;
        });

        // --- 接続順序修正箇所 (変更なし) ---
        gainNode = audioContext.createGain();   // Gain Nodeを作成
        analyser = audioContext.createAnalyser(); // Analyser Nodeを作成
        analyser.fftSize = 256;
        analyser.smoothingTimeConstant = 0.8;
        analyser.minDecibels = -80;
        analyser.maxDecibels = -10;
        dataArray = new Uint8Array(analyser.frequencyBinCount);

        mainPlayerNode.connect(preampGainNode); // Source -> Preamp
        let lastNode = preampGainNode;
        for (const band of eqBands) {          // Preamp -> EQ Bands
            lastNode.connect(band);
            lastNode = band;
        }
        lastNode.connect(gainNode);             // Last EQ Band -> Gain
        gainNode.connect(analyser);             // Gain -> Analyser
        analyser.connect(audioContext.destination); // Analyser -> Destination
        // --- 接続順序修正箇所 (変更なし) ---

        console.log("Web Audio graph connected successfully.");

    } catch (e) {
        console.error('Failed to connect Web Audio graph:', e);
    }
}


export function toggleVisualizerEcoMode(enabled) {
    isEcoModeEnabled = enabled;
    console.log(`[Visualizer] Eco Mode ${enabled ? 'ENABLED' : 'DISABLED'}.`);
    if (enabled) {
        if (observedTarget) setupVisualizerObserver(observedTarget);
    } else {
        disconnectVisualizerObserver();
        isVisualizerVisible = true;
        if (!visualizerFrameId && isPlaying()) {
            visualizerFrameId = requestAnimationFrame(draw);
        }
    }
}

function setupVisualizerObserver(targetElement) {
    disconnectVisualizerObserver();
    if (!isEcoModeEnabled || !targetElement) return;

    const options = {
        root: document.getElementById('music-list') || elements.mainContent,
        threshold: 0.1
    };

    visualizerObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            const wasVisible = isVisualizerVisible;
            isVisualizerVisible = entry.isIntersecting;

            if (!isVisualizerVisible && currentVisualizerBars) {
                lastHeights.fill(4);
                currentVisualizerBars.forEach(bar => {
                    if (bar.style.height !== '4px') bar.style.height = '4px';
                });
            } else if (isVisualizerVisible && !wasVisible && isPlaying() && !visualizerFrameId) {
                 visualizerFrameId = requestAnimationFrame(draw);
            }
        });
    }, options);

    if (visualizerObserver) {
        visualizerObserver.observe(targetElement);
    }
}

export function disconnectVisualizerObserver() {
    if (visualizerObserver) {
        visualizerObserver.disconnect();
        visualizerObserver = null;
    }
}

export function setVisualizerFpsLimit(fps) {
    const newFps = parseInt(fps, 10);
    if (isNaN(newFps) || newFps <= 0) {
        state.visualizerFpsLimit = 0;
        console.log('[Visualizer] FPS limit removed.');
    } else {
        state.visualizerFpsLimit = newFps;
        console.log(`[Visualizer] FPS limit set to ${newFps} FPS.`);
    }
}

// resumeAudioContext 関数は変更なし (drawループからも呼ばれる)
async function resumeAudioContext() {
    if (audioContext && audioContext.state === 'suspended') {
        try {
            await audioContext.resume();
            console.log("AudioContext resumed."); // 成功ログ
        } catch (e) {
            // resume が失敗してもエラーログは出さない (draw ループ内で頻繁に呼ばれるため)
            // console.error('Failed to resume AudioContext:', e);
        }
    }
}


function updateVolumeIcon() {
    const volume = parseFloat(elements.volumeSlider.value);
    const volumeIcon = document.getElementById('volume-icon');
    if (!volumeIcon) return;
    if (volume === 0) volumeIcon.src = './assets/icons/mute.svg';
    else if (volume < 0.5) volumeIcon.src = './assets/icons/small_sound.svg';
    else volumeIcon.src = './assets/icons/bigger_sound.svg';
}

function toggleMute() {
    const currentVolume = parseFloat(elements.volumeSlider.value);
    if (currentVolume > 0) {
        lastVolume = currentVolume;
        elements.volumeSlider.value = 0;
    } else {
        elements.volumeSlider.value = lastVolume > 0 ? lastVolume : 0.5;
    }
    elements.volumeSlider.dispatchEvent(new Event('input'));
}

export function applyMasterVolume() {
    if (!gainNode || !audioContext || audioContext.state === 'closed') return;
    const masterVolume = parseFloat(elements.volumeSlider.value);
    gainNode.gain.setValueAtTime(baseGain * masterVolume, audioContext.currentTime);
}

export function applyEqualizerSettings(settings) {
    if (!preampGainNode || eqBands.length === 0 || !audioContext || audioContext.state === 'closed') return;
    const preampValue = Math.pow(10, (settings.preamp || 0) / 20);
    preampGainNode.gain.setValueAtTime(preampValue, audioContext.currentTime);
    for (let i = 0; i < eqBands.length; i++) {
        if (settings.bands && typeof settings.bands[i] === 'number') {
            eqBands[i].gain.setValueAtTime(settings.bands[i], audioContext.currentTime);
        }
    }
}

export async function setAudioOutput(deviceId) {
    ipcRenderer.send('save-settings', { audioOutputId: deviceId });
    await reinitPlayer(deviceId);
}

// draw 関数は変更なし (前回のゴリ押し修正済み)
function draw(timestamp) {
    if (!isPlaying()) {
        visualizerFrameId = null;
        return;
    }
    visualizerFrameId = requestAnimationFrame(draw);

    if (audioContext && audioContext.state === 'suspended') {
        resumeAudioContext();
        return;
    }

    if (isEcoModeEnabled && !isVisualizerVisible) return;
    if (state.isLightFlightMode || state.visualizerMode === 'static') return;

    if (state.visualizerFpsLimit > 0) {
        const frameInterval = 1000 / state.visualizerFpsLimit;
        const elapsed = timestamp - lastFrameTime;
        if (elapsed < frameInterval) return;
        lastFrameTime = timestamp - (elapsed % frameInterval);
    }

    if (currentVisualizerBars && analyser) {
        analyser.getByteFrequencyData(dataArray);
        const barIndices = [1, 3, 7, 15, 30, 60];
        const heights = barIndices.map((dataIndex, i) => {
            const value = dataArray[dataIndex] / 255;
            const scaledValue = Math.pow(value, 1.6);
            const multiplier = 1 + Math.sin((i / (barIndices.length - 1)) * Math.PI) * 0.5;
            const targetHeight = (scaledValue * multiplier * 20) + 4;
            const newHeight = lastHeights[i] * 0.5 + targetHeight * 0.5;
            lastHeights[i] = newHeight;
            return Math.min(20, Math.max(4, newHeight));
        });
        currentVisualizerBars.forEach((bar, index) => {
             const newHeightPx = `${heights[index]}px`;
             if (bar.style.height !== newHeightPx) {
                 bar.style.height = newHeightPx;
             }
        });
    }
}


export function setVisualizerTarget(targetElement) {
    document.querySelectorAll('.indicator-ready').forEach(item => {
        item.classList.remove('indicator-ready');
    });
    observedTarget = targetElement;
    if (targetElement) {
        const bars = targetElement.querySelectorAll('.playing-indicator-bar');
        if (bars.length > 0) {
            targetElement.classList.add('indicator-ready');
            currentVisualizerBars = bars;
            setupVisualizerObserver(targetElement);
        } else {
            currentVisualizerBars = null;
        }
    } else {
        currentVisualizerBars = null;
        disconnectVisualizerObserver();
    }
}

async function reinitPlayer(sinkId) {
    const wasPlaying = isPlaying();
    const currentTime = getCurrentTime();
    const currentSrc = localPlayer ? localPlayer.src : null;
    if (localPlayer && localPlayer.parentNode) {
        localPlayer.pause();
        localPlayer.removeAttribute('src');
        localPlayer.load();
        localPlayer.parentNode.removeChild(localPlayer);
    }
    const newPlayer = document.createElement('video');
    newPlayer.id = 'main-player';
    newPlayer.playsInline = true;
    document.body.appendChild(newPlayer);
    await initPlayer(newPlayer, {
        onSongEnded: onSongEndedCallback,
        onNextSong: onNextSongCallback,
        onPrevSong: onPrevSongCallback
    }, sinkId);
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
    await createAudioContext(finalSinkId);
    connectAudioGraph();
    elements.playPauseBtn.classList.remove('playing');
    localPlayer.addEventListener('ended', () => {
        if (progressFrameId) cancelAnimationFrame(progressFrameId);
        progressFrameId = null;
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
        const duration = getDuration();
        elements.totalDurationEl.textContent = formatTime(duration);
        elements.progressBar.max = duration;
        updateLrcEditorControls(isPlaying(), getCurrentTime(), duration);
    });
    localPlayer.addEventListener('play', () => {
        elements.playPauseBtn.classList.add('playing');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        resumeAudioContext(); // playイベントでもresumeを試みる
        updatePlayingIndicators();
        updateLrcEditorControls(true, getCurrentTime(), getDuration());
        if (progressUpdateInterval) clearInterval(progressUpdateInterval);
        progressUpdateInterval = setInterval(() => { if (!isSeeking) updateUiTime(getCurrentTime(), getDuration()); }, 1000);
        if (!progressFrameId) progressFrameId = requestAnimationFrame(updateProgressBarLoop);
        if (!visualizerFrameId) {
            lastHeights.fill(4);
            visualizerFrameId = requestAnimationFrame(draw);
        }
    });
    localPlayer.addEventListener('pause', () => {
        if (!isSeeking) elements.playPauseBtn.classList.remove('playing');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        updateLrcEditorControls(false, getCurrentTime(), getDuration());
        if (progressUpdateInterval) { clearInterval(progressUpdateInterval); progressUpdateInterval = null; }
        if (progressFrameId) { cancelAnimationFrame(progressFrameId); progressFrameId = null; }
        if (visualizerFrameId) {
            cancelAnimationFrame(visualizerFrameId);
            visualizerFrameId = null;
        }
        if (currentVisualizerBars) { lastHeights.fill(4); currentVisualizerBars.forEach(bar => bar.style.height = '4px'); }
    });
    elements.playPauseBtn.addEventListener('click', togglePlayPause);
    elements.progressBar.addEventListener('mousedown', () => { isSeeking = true; wasPlayingBeforeSeek = isPlaying(); if (wasPlayingBeforeSeek) localPlayer.pause(); });
    elements.progressBar.addEventListener('mouseup', () => { if (isSeeking) { seek(parseFloat(elements.progressBar.value)); isSeeking = false; if (wasPlayingBeforeSeek) { localPlayer.play().catch(e => console.error("Playback resumption after seek failed:", e)); wasPlayingBeforeSeek = false; } } });
    elements.progressBar.addEventListener('input', () => { if (isSeeking) { const time = parseFloat(elements.progressBar.value); elements.currentTimeEl.textContent = formatTime(time); updateLrcEditorControls(false, time, getDuration()); } });
    elements.volumeSlider.addEventListener('input', () => { applyMasterVolume(); updateVolumeIcon(); ipcRenderer.send('save-settings', { volume: parseFloat(elements.volumeSlider.value) }); });
    document.getElementById('volume-icon-btn').addEventListener('click', toggleMute);
    updateVolumeIcon();
    if ('mediaSession' in navigator) {
        navigator.mediaSession.setActionHandler('play', togglePlayPause);
        navigator.mediaSession.setActionHandler('pause', togglePlayPause);
        navigator.mediaSession.setActionHandler('nexttrack', onNextSongCallback);
        navigator.mediaSession.setActionHandler('previoustrack', onPrevSongCallback);
    }
}

async function getColorsFromArtwork(img) {
    if (!img.complete || img.naturalWidth === 0) {
        await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = reject; }).catch(e => { console.error("Image loading error for color extraction:", e); return null; });
        if (!img.complete) return null;
    }
    return new Promise((resolve) => {
        const canvas = document.createElement('canvas');
        const context = canvas.getContext('2d', { willReadFrequently: true });
        const width = canvas.width = img.naturalWidth || img.width;
        const height = canvas.height = img.naturalHeight || img.height;
        try {
            context.drawImage(img, 0, 0);
            const imageData = context.getImageData(0, 0, width, height);
            const data = imageData.data;
            const colorCount = {};
            const step = Math.max(4, Math.floor(data.length / (1000 * 4))) * 4;
            for (let i = 0; i < data.length; i += step) {
                const r = Math.round(data[i] / 32) * 32; const g = Math.round(data[i + 1] / 32) * 32; const b = Math.round(data[i + 2] / 32) * 32;
                const key = `${r},${g},${b}`; colorCount[key] = (colorCount[key] || 0) + 1;
            }
            const sortedColors = Object.keys(colorCount).sort((a, b) => colorCount[b] - colorCount[a]);
            if (sortedColors.length >= 2) resolve([ `rgb(${sortedColors[0]})`, `rgb(${sortedColors[1]})` ]);
            else if (sortedColors.length === 1) resolve([ `rgb(${sortedColors[0]})`, `rgb(${sortedColors[0]})` ]);
            else resolve(null);
        } catch (e) { console.error("Canvas color extraction failed (maybe CORS issue?):", e, img.src); resolve(null); }
    });
}

export async function setEqualizerColorFromArtwork(imageElement) {
    const setDefaultColors = () => { document.documentElement.style.setProperty('--eq-color-1', 'var(--highlight-pink)'); document.documentElement.style.setProperty('--eq-color-2', 'var(--highlight-blue)'); };
    if (state.isLightFlightMode) { setDefaultColors(); return; }
    if (imageElement && imageElement.src && !imageElement.src.endsWith('default_artwork.png')) {
        if (!imageElement.crossOrigin) imageElement.crossOrigin = "Anonymous";
        const colors = await getColorsFromArtwork(imageElement);
        if (colors) { document.documentElement.style.setProperty('--eq-color-1', colors[0]); document.documentElement.style.setProperty('--eq-color-2', colors[1]); }
        else setDefaultColors();
    } else setDefaultColors();
}

export async function play(song) {
    await stop();
    if (!song) {
        elements.playPauseBtn.classList.remove('playing');
        if ('mediaSession' in navigator) { navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = 'none'; }
        updateNowPlayingView(null);
        loadLyricsForSong(null);
        return;
    }

    const settings = await ipcRenderer.invoke('get-settings');
    const TARGET_LOUDNESS = settings?.targetLoudness ?? -18.0;

    if (gainNode) {
        const savedLoudness = await ipcRenderer.invoke('get-loudness-value', song.path);
        if (typeof savedLoudness === 'number' && Number.isFinite(savedLoudness)) {
            const gainDb = TARGET_LOUDNESS - savedLoudness; baseGain = Math.pow(10, gainDb / 20);
        } else baseGain = 1.0;
        applyMasterVolume();
    }

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
    if (progressUpdateInterval) { clearInterval(progressUpdateInterval); progressUpdateInterval = null; }
    if (progressFrameId) { cancelAnimationFrame(progressFrameId); progressFrameId = null; }
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
        visualizerFrameId = null;
    }
    elements.currentTimeEl.textContent = '0:00';
    elements.totalDurationEl.textContent = '0:00';
    elements.progressBar.value = 0;
    elements.progressBar.max = 0;
    updateLrcEditorControls(false, 0, 0);
    ipcRenderer.send('playback-stopped');
}

// --- ▼▼▼ ゴリ押し修正箇所 ▼▼▼ ---
async function playLocal(song) {
    if (!localPlayer) { console.error("Player element not found."); return; }
    const safePath = encodeURI(song.path.replace(/\\/g, '/')).replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;
    try {
        await resumeAudioContext(); // まず resume を試みる
        const playPromise = localPlayer.play(); // 再生を開始

        console.log(`Playing: ${song.title}`);

        // play() が成功したら、短い遅延後に一時停止してすぐ再開
        if (playPromise !== undefined) {
            playPromise.then(() => {
                // ほんの短い時間 (例: 50ms) 待つ
                setTimeout(() => {
                    if (isPlaying()) { // まだ再生中だったら
                        localPlayer.pause(); // 一時停止
                        // さらにごく短い時間 (例: 1ms) 待ってから再開
                        // (pause が完了するのを待つ意図だが、確実ではない)
                        setTimeout(() => {
                            localPlayer.play().catch(e => {
                                // 再開に失敗した場合のエラー処理 (必要なら)
                                console.error("Gorilla resume failed:", e);
                            });
                        }, 1);
                         console.log("Gorilla pause/resume triggered."); // ゴリ押し処理が実行されたログ
                    }
                }, 50); // 50ミリ秒後に実行
            }).catch(error => {
                // 最初の play() が失敗した場合のエラー処理はそのまま
                if (error.name !== 'AbortError') {
                    console.error(`Audio playback failed for ${song.path}:`, error);
                    // showNotification(`Error playing "${song.title}": ${error.message}`);
                    // hideNotification(5000);
                    onSongEndedCallback();
                }
            });
        }

    } catch (error) { // resumeAudioContext やその他の同期エラー
        if (error.name !== 'AbortError') {
             console.error(`Audio playback failed (initial setup) for ${song.path}:`, error);
             // showNotification(`Error playing "${song.title}": ${error.message}`);
             // hideNotification(5000);
             onSongEndedCallback();
        }
    }
}
// --- ▲▲▲ ゴリ押し修正箇所 ▲▲▲ ---

export async function togglePlayPause() {
    await resumeAudioContext(); // 念のためここでも呼ぶ
    if (!localPlayer) return;
    if (localPlayer.src && !localPlayer.paused) localPlayer.pause();
    else if (localPlayer.src) {
         try { await localPlayer.play(); }
         catch (error) { if (error.name !== 'AbortError') console.error("Toggle play failed:", error); }
    } else if (state.playbackQueue.length > 0 && state.currentSongIndex >= 0) playSong(state.currentSongIndex);
}

export async function seekToStart() { seek(0); }

function updateUiTime(current, duration) {
    if (isNaN(duration) || duration <= 0) { elements.currentTimeEl.textContent = '0:00'; elements.totalDurationEl.textContent = '0:00'; elements.progressBar.max = 0; return; };
    elements.currentTimeEl.textContent = formatTime(current);
    elements.totalDurationEl.textContent = formatTime(duration);
    if (elements.progressBar.max != duration) elements.progressBar.max = duration;
}

function formatTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '0:00';
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}