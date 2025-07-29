import { elements } from './state.js';
import { updateSyncedLyrics } from './lyrics-manager.js';
const { ipcRenderer } = require('electron');
const path = require('path');

let audioContext;
let mainPlayerNode;
let gainNode;
let baseGain = 1.0;

let localPlayer;
let ytPlayer;
let ytPlayerPromise = null;
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

async function resumeAudioContext() {
    if (audioContext && audioContext.state === 'suspended') {
        try {
            await audioContext.resume();
            console.log('AudioContext resumed successfully.');
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
        
        startVisualizer();
    });

    localPlayer.addEventListener('pause', () => {
        if (!isSeeking) {
            setPlayPauseIcon('play');
        }
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        cancelAnimationFrame(animationFrameId);
        
        stopVisualizer();
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


export async function setEqualizerColorFromArtwork() {
    document.querySelectorAll('.song-item.indicator-ready').forEach(item => {
        item.classList.remove('indicator-ready');
    });

    const nowPlayingArtwork = document.querySelector('#now-playing-artwork-container img');
    
    // ▼▼▼ 変更点 ▼▼▼
    const setDefaultColors = () => {
        document.documentElement.style.setProperty('--eq-color-1', 'var(--highlight-pink)');
        document.documentElement.style.setProperty('--eq-color-2', 'var(--highlight-blue)');
    };
    // ▲▲▲ 変更点ここまで ▲▲▲

    if (nowPlayingArtwork && nowPlayingArtwork.src && !nowPlayingArtwork.src.endsWith('default_artwork.png')) {
        const colors = await getColorsFromArtwork(nowPlayingArtwork);
        
        if (colors) {
            document.documentElement.style.setProperty('--eq-color-1', colors[0]);
            document.documentElement.style.setProperty('--eq-color-2', colors[1]);
        } else {
            setDefaultColors();
        }
    } else {
        setDefaultColors();
    }
    
    const playingItem = document.querySelector('.song-item.playing');
    if (playingItem) {
        playingItem.classList.add('indicator-ready');
    }
}


function startVisualizer() {
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
    }

    const draw = () => {
        if (!analyser) return;
        analyser.getByteFrequencyData(dataArray);

        const playingItem = document.querySelector('.song-item.playing');
        if (playingItem) {
            const indicator = playingItem.querySelector('.playing-indicator');
            if (indicator) {
                const bars = indicator.querySelectorAll('.playing-indicator-bar');
                const bufferLength = analyser.frequencyBinCount;
                
                const heights = [
                    dataArray[Math.floor(bufferLength * 0.1)],
                    dataArray[Math.floor(bufferLength * 0.2)],
                    dataArray[Math.floor(bufferLength * 0.3)],
                    dataArray[Math.floor(bufferLength * 0.4)],
                    dataArray[Math.floor(bufferLength * 0.5)],
                    dataArray[Math.floor(bufferLength * 0.6)],
                ].map(val => (val / 255) * 16 + 4);

                bars.forEach((bar, index) => {
                    bar.style.height = `${heights[index]}px`;
                });
            }
        }
        visualizerFrameId = requestAnimationFrame(draw);
    };
    draw();
}

function stopVisualizer() {
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
    }
    document.querySelectorAll('.playing-indicator-bar').forEach(bar => {
        bar.style.height = '4px';
    });
}

function getYouTubePlayer(videoId) {
    if (ytPlayerPromise) {
        return ytPlayerPromise;
    }
    ytPlayerPromise = new Promise(resolve => {
        const createPlayer = () => {
            return new YT.Player('youtube-player-container', {
                height: '100%', width: '100%', videoId: videoId,
                playerVars: {
                    'autoplay': 1, 'controls': 0, 'fs': 0, 'iv_load_policy': 3, 'modestbranding': 1,
                    'origin': window.location.href, 'enablejsapi': 1,
                },
                events: {
                    'onReady': (event) => {
                        ytPlayer = event.target;
                        resolve(ytPlayer);
                    },
                    'onStateChange': onPlayerStateChange
                }
            });
        };

        if (window.YT && window.YT.Player) {
            if(ytPlayer) {
                resolve(ytPlayer);
            } else {
                createPlayer();
            }
        } else {
            window.onYouTubeIframeAPIReady = () => {
                createPlayer();
            };
            const tag = document.createElement('script');
            tag.src = "https://www.youtube.com/iframe_api";
            document.head.appendChild(tag);
        }
    });
    return ytPlayerPromise;
}

export async function play(song) {
    await stop();
    if (!song) {
        setPlayPauseIcon('stop'); 
        if ('mediaSession' in navigator) {
            navigator.mediaSession.metadata = null;
            navigator.mediaSession.playbackState = 'none';
        }
        return;
    }

    const TARGET_LOUDNESS = -23.0;

    if (gainNode) {
        const savedLoudness = await ipcRenderer.invoke('get-loudness-value', song.path);
        
        if (typeof savedLoudness === 'number') {
            const gainDb = TARGET_LOUDNESS - savedLoudness;
            baseGain = Math.pow(10, gainDb / 20);
            console.log(`[ノーマライザー適用] ${path.basename(song.path)}: 元音量 ${savedLoudness.toFixed(2)} LUFS -> 補正 ${gainDb.toFixed(2)} dB`);
        } else {
            baseGain = 1.0;
        }
        applyMasterVolume();
    }

    if ('mediaSession' in navigator) {
        let artworkSrc = '';
        if (song.artwork) {
            if (song.artwork.startsWith('http')) {
                artworkSrc = song.artwork;
            } else {
                artworkSrc = await ipcRenderer.invoke('get-artwork-as-data-url', song.artwork);
            }
        }
    
        navigator.mediaSession.metadata = new MediaMetadata({
            title: song.title || '不明なタイトル',
            artist: song.artist || '不明なアーティスト',
            album: song.album || '',
            artwork: artworkSrc ? [{ src: artworkSrc }] : []
        });
    }

    const settings = await ipcRenderer.invoke('get-settings');
    const mode = settings.youtubePlaybackMode || 'download';

    if (song.type === 'youtube' || (mode === 'stream' && song.sourceURL)) {
        currentSongType = 'youtube';
        elements.deviceSelectButton.disabled = true;
        const streamPath = song.sourceURL || song.path;
        playYoutube({ ...song, path: streamPath });
    } else if (song.type === 'local' && song.path) {
        currentSongType = 'local';
        elements.deviceSelectButton.disabled = false;
        playLocal(song);
    } else {
        alert(`この曲はダウンロードされていません。「設定」からストリーミングモードに切り替えてください。`);
    }
}

export async function stop() {
    if (currentSongType === 'youtube' && ytPlayer && typeof ytPlayer.pauseVideo === 'function') {
        ytPlayer.pauseVideo();
    } else {
        localPlayer.pause();
    }
    setPlayPauseIcon('play'); 
    clearInterval(timeUpdateInterval);
}

async function playLocal(song) {
    if (!song || !song.path) return;
    
    const safePath = song.path.replace(/\\/g, '/').replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;
    
    try {
        await resumeAudioContext();
        localPlayer.load();
        await localPlayer.play();
    } catch (error) {
        if (error.name !== 'AbortError') {
            console.error("オーディオの再生に失敗しました:", error);
        }
    }
}

async function playYoutube(song) {
    const videoId = getYoutubeVideoId(song.path);
    if (!videoId) return;
    const player = await getYouTubePlayer(videoId);
    if (player && typeof player.loadVideoById === 'function') {
        player.loadVideoById(videoId);
    }
}

export async function togglePlayPause() {
    await resumeAudioContext();

    if (currentSongType === 'youtube') {
        const player = await getYouTubePlayer();
        if (player && typeof player.getPlayerState === 'function') {
            const state = player.getPlayerState();
            if (state === YT.PlayerState.PLAYING) {
                player.pauseVideo();
            } else {
                player.playVideo();
            }
        }
    } else {
        if (localPlayer.src && !localPlayer.paused) {
             localPlayer.pause();
        } else if (localPlayer.src) {
             localPlayer.play();
        }
    }
}

export async function seekToStart() {
    if (currentSongType === 'youtube') {
        const player = await getYouTubePlayer();
        if (player && typeof player.seekTo === 'function') player.seekTo(0, true);
    } else {
        localPlayer.currentTime = 0;
    }
}

async function seek() {
    const time = parseFloat(elements.progressBar.value);
    if (currentSongType === 'youtube') {
        const player = await getYouTubePlayer();
        if (player && typeof player.seekTo === 'function') player.seekTo(time, true);
    } else {
        localPlayer.currentTime = time;
    }
}

function onPlayerStateChange(event) {
    const state = event.data;
    if (state === YT.PlayerState.PLAYING) {
        setPlayPauseIcon('pause');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        timeUpdateInterval = setInterval(async () => {
            const player = await getYouTubePlayer();
            if (player && typeof player.getCurrentTime === 'function') {
                const currentTime = player.getCurrentTime();
                updateUiTime(currentTime, player.getDuration());
                updateSyncedLyrics(currentTime);
            }
        }, 500);
    } else {
        setPlayPauseIcon('play');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        clearInterval(timeUpdateInterval);
    }
    if (state === YT.PlayerState.ENDED) onSongEndedCallback();
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
function getYoutubeVideoId(url) {
    if (typeof url !== 'string') return null;
    const regExp = /^.*(https?:\/\/)?(www\.)?(youtube\.com|youtu\.?be)\/.+$/;
    if(!regExp.test(url)) return null;
    const match = url.match(/(?:\/|v=)([\w-]{11}).*/);
    return match ? match[1] : null;
}