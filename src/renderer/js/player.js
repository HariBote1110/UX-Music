// uxmusic/src/renderer/js/player.js

import { elements, state } from './state.js'; // `state` を追加
import { updateSyncedLyrics } from './lyrics-manager.js';
import { updatePlayingIndicators } from './ui-manager.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let audioContext;
let mainPlayerNode;
let gainNode;
let baseGain = 1.0;

let localPlayer;
let currentSongType = 'local';
let timeUpdateInterval;

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

async function resumeAudioContext() {
    if (audioContext && audioContext.state === 'suspended') {
        try {
            await audioContext.resume();
        } catch (e) {
            console.error('Failed to resume AudioContext:', e);
        }
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
    const volumeMultiplier = masterVolume * 2;
    gainNode.gain.value = baseGain * volumeMultiplier;
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
        analyser.fftSize = 64;
        const bufferLength = analyser.frequencyBinCount;
        dataArray = new Uint8Array(bufferLength);

        mainPlayerNode.connect(gainNode);
        gainNode.connect(analyser);
        analyser.connect(audioContext.destination);

    } catch (e) {
        console.error('Web Audio APIの初期化に失敗しました。', e);
    }

    setPlayPauseIcon('stop');

    const smoothUpdateLoop = () => {
        if (!isSeeking) {
            updateUiTime(localPlayer.currentTime, localPlayer.duration);
        }
        animationFrameId = requestAnimationFrame(smoothUpdateLoop);
    };

    localPlayer.addEventListener('ended', onSongEndedCallback);
    
    localPlayer.addEventListener('timeupdate', () => {
        updateSyncedLyrics(localPlayer.currentTime);
    });
    
    localPlayer.addEventListener('play', () => {
        setPlayPauseIcon('pause');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        resumeAudioContext();
        if (animationFrameId) cancelAnimationFrame(animationFrameId);
        animationFrameId = requestAnimationFrame(smoothUpdateLoop);
        
        updatePlayingIndicators();
        startVisualizer();
    });

    localPlayer.addEventListener('pause', () => {
        if (!isSeeking) {
            setPlayPauseIcon('play');
        }
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        cancelAnimationFrame(animationFrameId);
        
        pauseVisualizer();
    });

    elements.playPauseBtn.addEventListener('click', togglePlayPause);
    
    elements.progressBar.addEventListener('mousedown', () => {
        isSeeking = true;
        wasPlayingBeforeSeek = !localPlayer.paused;
        if (wasPlayingBeforeSeek) {
            localPlayer.pause();
        }
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
        const time = parseFloat(elements.progressBar.value);
        elements.currentTimeEl.textContent = formatTime(time);
    });
    
    elements.volumeSlider.addEventListener('input', () => {
        applyMasterVolume();
        updateVolumeIcon();
        const volume = parseFloat(elements.volumeSlider.value);
        ipcRenderer.send('save-settings', { volume: volume });
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

function getColorsFromArtwork(img) {
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


function startVisualizer() {
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
    }
    visualizerFrameId = requestAnimationFrame(draw);
}

export function setVisualizerTarget(targetElement) {
    document.querySelectorAll('.indicator-ready').forEach(item => {
        item.classList.remove('indicator-ready');
    });

    if (targetElement) {
        const bars = targetElement.querySelectorAll('.playing-indicator-bar');
        if (bars.length > 0) {
            targetElement.classList.add('indicator-ready');
            currentVisualizerBars = bars;
        } else {
             currentVisualizerBars = null;
        }
    } else {
        currentVisualizerBars = null;
    }
}

function draw() {
    if (currentVisualizerBars && analyser) {
        analyser.getByteFrequencyData(dataArray);
        const bufferLength = analyser.frequencyBinCount;
        
        const heights = [
            dataArray[Math.floor(bufferLength * 0.1)],
            dataArray[Math.floor(bufferLength * 0.25)],
            dataArray[Math.floor(bufferLength * 0.4)],
            dataArray[Math.floor(bufferLength * 0.55)],
            dataArray[Math.floor(bufferLength * 0.7)],
            dataArray[Math.floor(bufferLength * 0.85)],
        ].map(val => (val / 255) * 16 + 4);

        currentVisualizerBars.forEach((bar, index) => {
            bar.style.height = `${heights[index]}px`;
        });
    }
    visualizerFrameId = requestAnimationFrame(draw);
}

function pauseVisualizer() {
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
        visualizerFrameId = null;
    }
    if (currentVisualizerBars) {
        currentVisualizerBars.forEach(bar => {
            bar.style.height = '4px';
        });
    }
}

function stopVisualizer() {
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
        visualizerFrameId = null;
    }
    setVisualizerTarget(null);
    document.querySelectorAll('.playing-indicator-bar').forEach(bar => {
        bar.style.height = '4px';
    });
}

export async function play(song) {
    // ★★★ ここからが修正箇所です ★★★
    // ユーザーが設定したデバイスが保存されていれば、このタイミングで適用する
    if (state.preferredDeviceId) {
        await setAudioOutput(state.preferredDeviceId);
        state.preferredDeviceId = null; // 一度適用したらクリアする
    }
    // ★★★ ここまでが修正箇所です ★★★

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
    clearInterval(timeUpdateInterval);
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