import { elements, state } from './state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
import { updatePlayingIndicators } from './ui-manager.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let audioContext;
let mainPlayerNode;
let gainNode;
let baseGain = 1.0;

let localPlayer;
// ▼▼▼ 削除されてしまっていた変数を元に戻します ▼▼▼
let currentSongType = 'local';
let timeUpdateInterval;
// ▲▲▲ 修正はここまで ▲▲▲

let onSongEndedCallback = () => {};
let onNextSongCallback = () => {};
let onPrevSongCallback = () => {};
let lastVolume = 0.5;

let isSeeking = false;
let wasPlayingBeforeSeek = false;
let animationFrameId = null;

let analyser;
let dataArray;
let visualizerFrameId;

let currentVisualizerBars = null;
let observedTarget = null;
let lastHeights = new Array(6).fill(4);

// FPS制限用
let visualizerFpsLimit = 0; 
let frameInterval = 0;
let lastFrameTime = 0;

// エコモード用
let progressUpdateInterval = null; 
let visualizerObserver = null; 
let isVisualizerVisible = false; 
let isEcoModeEnabled = true;

/**
 * ビジュアライザーのエコモード（Intersection Observerによる表示監視）を切り替える
 * @param {boolean} enabled
 */
export function toggleVisualizerEcoMode(enabled) {
    isEcoModeEnabled = enabled;
    console.log(`[Visualizer] Eco Mode ${enabled ? 'ENABLED' : 'DISABLED'}.`);
    if (enabled) {
        if (observedTarget) setupVisualizerObserver(observedTarget);
    } else {
        disconnectVisualizerObserver();
        isVisualizerVisible = true; // エコモードOFF時は常に表示されているとみなす
    }
}

/**
 * 指定された要素が表示されているかを監視するIntersectionObserverをセットアップ
 * @param {HTMLElement} targetElement
 */
function setupVisualizerObserver(targetElement) {
    disconnectVisualizerObserver(); // 既存のObserverは解除
    if (!isEcoModeEnabled || !targetElement) return;

    const options = {
        root: document.getElementById('music-list'), // スクロールコンテナ
        threshold: 0.1 // 10%以上表示されたらコールバックを実行
    };

    visualizerObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            isVisualizerVisible = entry.isIntersecting;
            if (!isVisualizerVisible && currentVisualizerBars) {
                // 非表示になったら即座にバーをリセット
                lastHeights.fill(4);
                currentVisualizerBars.forEach(bar => {
                    if (bar.style.height !== '4px') bar.style.height = '4px';
                });
            }
        });
    }, options);

    visualizerObserver.observe(targetElement);
}

/**
 * IntersectionObserverの監視を解除する
 */
export function disconnectVisualizerObserver() {
    if (visualizerObserver) {
        visualizerObserver.disconnect();
        visualizerObserver = null;
    }
}


export function setVisualizerFpsLimit(fps) {
    const newFps = parseInt(fps, 10);
    if (isNaN(newFps) || newFps <= 0) {
        visualizerFpsLimit = 0;
        frameInterval = 0;
        console.log('[Visualizer] FPS limit removed.');
    } else {
        visualizerFpsLimit = newFps;
        frameInterval = 1000 / newFps;
        console.log(`[Visualizer] FPS limit set to ${newFps} FPS (interval: ${frameInterval.toFixed(2)}ms).`);
    }
}

async function resumeAudioContext() {
    if (audioContext && audioContext.state === 'suspended') {
        try {
            await audioContext.resume();
        } catch (e) { console.error('Failed to resume AudioContext:', e); }
    }
}

function setPlayPauseIcon(iconName) {
    const playPauseIcon = elements.playPauseBtn.querySelector('img');
    if (playPauseIcon) {
        playPauseIcon.src = `./assets/icons/${iconName}.svg`;
    }
}

function updateVolumeIcon() {
    const volume = parseFloat(elements.volumeSlider.value);
    const volumeIcon = document.getElementById('volume-icon');
    if (volume === 0) {
        volumeIcon.src = './assets/icons/mute.svg';
    } else if (volume < 0.5) {
        volumeIcon.src = './assets/icons/small_sound.svg';
    } else {
        volumeIcon.src = './assets/icons/bigger_sound.svg';
    }
}

function toggleMute() {
    const currentVolume = parseFloat(elements.volumeSlider.value);
    if (currentVolume > 0) {
        lastVolume = currentVolume;
        elements.volumeSlider.value = 0;
    } else {
        elements.volumeSlider.value = lastVolume;
    }
    elements.volumeSlider.dispatchEvent(new Event('input'));
}

export function applyMasterVolume() {
    if (!gainNode) return;
    const masterVolume = parseFloat(elements.volumeSlider.value);
    gainNode.gain.value = baseGain * (masterVolume * 2);
}

export async function setAudioOutput(deviceId) {
    try {
        await resumeAudioContext();
        if (typeof localPlayer.setSinkId === 'function') {
            await localPlayer.setSinkId(deviceId);
            ipcRenderer.send('save-audio-output-id', deviceId);
            console.log(`オーディオ出力先を ${deviceId} に変更しました`);
        }
    } catch (error) {
        console.error('オーディオ出力先の変更に失敗しました:', error);
    }
}

function draw(timestamp) {
    if (localPlayer && !localPlayer.paused) {
        visualizerFrameId = requestAnimationFrame(draw);
    } else {
        visualizerFrameId = null;
        return;
    }

    if (isEcoModeEnabled && !isVisualizerVisible) {
        return;
    }

    if (visualizerFpsLimit > 0) {
        const elapsed = timestamp - lastFrameTime;
        if (elapsed < frameInterval) {
            return;
        }
        lastFrameTime = timestamp - (elapsed % frameInterval);
    }

    if (currentVisualizerBars && analyser) {
        analyser.getByteFrequencyData(dataArray);
        const bufferLength = analyser.frequencyBinCount;
        const barIndices = [
            Math.floor(bufferLength * 0.05), Math.floor(bufferLength * 0.15),
            Math.floor(bufferLength * 0.30), Math.floor(bufferLength * 0.50),
            Math.floor(bufferLength * 0.70), Math.floor(bufferLength * 0.90),
        ];

        const heights = barIndices.map((dataIndex, i) => {
            const value = dataArray[dataIndex] / 255;
            const scaledValue = Math.pow(value, 2.5);
            const multiplier = i === 0 ? 1.5 : 1 - (Math.abs(i - 2.5) * 0.15);
            const targetHeight = (scaledValue * multiplier * 16) + 4;
            const newHeight = lastHeights[i] * 0.4 + targetHeight * 0.6;
            lastHeights[i] = newHeight;
            return newHeight;
        });

        currentVisualizerBars.forEach((bar, index) => {
            bar.style.height = `${heights[index]}px`;
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

export function initPlayer(playerElement, callbacks) {
    localPlayer = playerElement;
    onSongEndedCallback = callbacks.onSongEnded;
    onNextSongCallback = callbacks.onNextSong;
    onPrevSongCallback = callbacks.onPrevSong;

    try {
        audioContext = new (window.AudioContext || window.webkitAudioContext)();
        mainPlayerNode = audioContext.createMediaElementSource(localPlayer);
        gainNode = audioContext.createGain();
        analyser = audioContext.createAnalyser();
        analyser.fftSize = 32;
        dataArray = new Uint8Array(analyser.frequencyBinCount);
        mainPlayerNode.connect(gainNode).connect(analyser).connect(audioContext.destination);
    } catch (e) {
        console.error('Web Audio APIの初期化に失敗しました。', e);
    }

    setPlayPauseIcon('stop');

    localPlayer.addEventListener('ended', onSongEndedCallback);
    localPlayer.addEventListener('timeupdate', () => updateSyncedLyrics(localPlayer.currentTime));

    localPlayer.addEventListener('play', () => {
        setPlayPauseIcon('pause');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        resumeAudioContext();
        updatePlayingIndicators();
        
        if (progressUpdateInterval) clearInterval(progressUpdateInterval);
        progressUpdateInterval = setInterval(() => {
            if (!isSeeking) {
                updateUiTime(localPlayer.currentTime, localPlayer.duration);
            }
        }, 1000);
        
        if (!visualizerFrameId) {
            visualizerFrameId = requestAnimationFrame(draw);
        }
    });

    localPlayer.addEventListener('pause', () => {
        if (!isSeeking) setPlayPauseIcon('play');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        
        if (progressUpdateInterval) clearInterval(progressUpdateInterval);
        
        if (visualizerFrameId) {
            cancelAnimationFrame(visualizerFrameId);
            visualizerFrameId = null;
        }
        if (currentVisualizerBars) {
            lastHeights.fill(4);
            currentVisualizerBars.forEach(bar => bar.style.height = '4px');
        }
    });

    elements.playPauseBtn.addEventListener('click', togglePlayPause);
    elements.progressBar.addEventListener('mousedown', () => {
        isSeeking = true;
        wasPlayingBeforeSeek = !localPlayer.paused;
        if (wasPlayingBeforeSeek) localPlayer.pause();
    });
    elements.progressBar.addEventListener('mouseup', () => {
        seek();
        isSeeking = false;
        if (wasPlayingBeforeSeek) {
            localPlayer.play();
            wasPlayingBeforeSeek = false;
        }
    });
    elements.progressBar.addEventListener('input', () => {
        if (isSeeking) {
            const time = parseFloat(elements.progressBar.value);
            elements.currentTimeEl.textContent = formatTime(time);
        }
    });
    elements.volumeSlider.addEventListener('input', () => {
        applyMasterVolume();
        updateVolumeIcon();
        ipcRenderer.send('save-settings', { volume: parseFloat(elements.volumeSlider.value) });
    });
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
    return new Promise((resolve) => {
        const processImage = () => {
            const canvas = document.createElement('canvas');
            const context = canvas.getContext('2d', { willReadFrequently: true });
            const width = canvas.width = img.naturalWidth || img.width;
            const height = canvas.height = img.naturalHeight || img.height;

            img.crossOrigin = "Anonymous";
            context.drawImage(img, 0, 0);

            try {
                const imageData = context.getImageData(0, 0, width, height);
                const data = imageData.data;
                const colorCount = {};
                
                const step = 4 * 5;
                for (let i = 0; i < data.length; i += step) {
                    const r = Math.round(data[i] / 32) * 32;
                    const g = Math.round(data[i + 1] / 32) * 32;
                    const b = Math.round(data[i + 2] / 32) * 32;
                    const key = `${r},${g},${b}`;
                    colorCount[key] = (colorCount[key] || 0) + 1;
                }

                const sortedColors = Object.keys(colorCount).sort((a, b) => colorCount[b] - colorCount[a]);

                if (sortedColors.length >= 2) {
                    resolve([ `rgb(${sortedColors[0]})`, `rgb(${sortedColors[1]})` ]);
                } else if (sortedColors.length === 1) {
                    resolve([ `rgb(${sortedColors[0]})`, `rgb(${sortedColors[0]})` ]);
                } else {
                    resolve(null);
                }

            } catch (e) {
                console.error("Canvasからの色抽出に失敗:", e);
                resolve(null);
            }
        };

        if (!img.complete) {
            img.onload = processImage;
            img.onerror = () => resolve(null);
        } else {
            processImage();
        }
    });
}

export async function setEqualizerColorFromArtwork(imageElement) {
    const setDefaultColors = () => {
        document.documentElement.style.setProperty('--eq-color-1', 'var(--highlight-pink)');
        document.documentElement.style.setProperty('--eq-color-2', 'var(--highlight-blue)');
    };

    if (imageElement && imageElement.src && !imageElement.src.endsWith('default_artwork.png')) {
        const colors = await getColorsFromArtwork(imageElement);
        if (colors) {
            document.documentElement.style.setProperty('--eq-color-1', colors[0]);
            document.documentElement.style.setProperty('--eq-color-2', colors[1]);
        } else {
            setDefaultColors();
        }
    } else {
        setDefaultColors();
    }
}

export async function play(song) {
    if (state.preferredDeviceId) {
        await setAudioOutput(state.preferredDeviceId);
        state.preferredDeviceId = null;
    }

    await stop();
    if (!song) {
        setPlayPauseIcon('stop'); 
        if ('mediaSession' in navigator) {
            navigator.mediaSession.metadata = null;
            navigator.mediaSession.playbackState = 'none';
        }
        return;
    }
    
    const settings = await ipcRenderer.invoke('get-settings');
    const TARGET_LOUDNESS = settings.targetLoudness || -23.0;

    if (gainNode) {
        const savedLoudness = await ipcRenderer.invoke('get-loudness-value', song.path);
        if (typeof savedLoudness === 'number') {
            const gainDb = TARGET_LOUDNESS - savedLoudness;
            baseGain = Math.pow(10, gainDb / 20);
        } else {
            baseGain = 1.0;
        }
        applyMasterVolume();
    }

    if ('mediaSession' in navigator) {
        let artworkSrc = '';
        if (song.artwork && typeof song.artwork === 'object') {
            artworkSrc = await ipcRenderer.invoke('get-artwork-as-data-url', song.artwork.full);
        } else if (song.artwork) {
            artworkSrc = await ipcRenderer.invoke('get-artwork-as-data-url', song.artwork);
        }
        navigator.mediaSession.metadata = new MediaMetadata({
            title: song.title || '不明なタイトル',
            artist: song.artist || '不明なアーティスト',
            album: song.album || '',
            artwork: artworkSrc ? [{ src: artworkSrc }] : []
        });
    }

    const mode = settings.youtubePlaybackMode || 'download';
    
    if (song.type === 'youtube' && mode === 'stream') {
        currentSongType = 'youtube';
        elements.deviceSelectButton.disabled = true;
    } else if (song.path) {
        currentSongType = 'local';
        elements.deviceSelectButton.disabled = false;
        playLocal(song);
    }
}

export async function stop() {
    localPlayer.pause();
    setPlayPauseIcon('play'); 
    clearInterval(progressUpdateInterval);
}

async function playLocal(song) {
    const safePath = song.path.replace(/\\/g, '/').replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;
    try {
        await resumeAudioContext();
        localPlayer.load();
        await localPlayer.play();
    } catch (error) {
        if (error.name !== 'AbortError') console.error("オーディオの再生に失敗しました:", error);
    }
}

export async function togglePlayPause() {
    await resumeAudioContext();
    if (localPlayer.src && !localPlayer.paused) {
        localPlayer.pause();
    } else if (localPlayer.src) {
        localPlayer.play();
    }
}

export async function seekToStart() {
    localPlayer.currentTime = 0;
}

async function seek() {
    const time = parseFloat(elements.progressBar.value);
    localPlayer.currentTime = time;
}

function updateUiTime(current, duration) {
    if (isNaN(duration) || duration <= 0) return;
    elements.currentTimeEl.textContent = formatTime(current);
    elements.totalDurationEl.textContent = formatTime(duration);
    elements.progressBar.value = current;
    elements.progressBar.max = duration;
}

function formatTime(seconds) {
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}