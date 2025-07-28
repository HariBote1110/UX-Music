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

function setPlayPauseIcon(iconName) { // 'play', 'pause', 'stop'
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

// ▼▼▼ ここからが修正箇所です ▼▼▼
/**
 * オーディオの出力先デバイスを設定する
 * @param {string} deviceId - 設定するデバイスのID
 */
export async function setAudioOutput(deviceId) {
    try {
        if (audioContext && typeof audioContext.setSinkId === 'function') {
            await audioContext.setSinkId(deviceId);
        } else {
            // AudioContext APIが使えない場合のフォールバック
            await localPlayer.setSinkId(deviceId);
        }
        // 設定をメインプロセスに保存
        ipcRenderer.send('save-audio-output-id', deviceId);
        console.log(`オーディオ出力先を ${deviceId} に変更しました`);
    } catch (error) {
        console.error('オーディオ出力先の変更に失敗しました:', error);
    }
}
// ▲▲▲ ここまでが修正箇所です ▲▲▲

export function initPlayer(playerElement, callbacks) {
    localPlayer = playerElement;
    onSongEndedCallback = callbacks.onSongEnded;
    onNextSongCallback = callbacks.onNextSong;
    onPrevSongCallback = callbacks.onPrevSong;

    try {
        audioContext = new (window.AudioContext || window.webkitAudioContext)();
        gainNode = audioContext.createGain();
        mainPlayerNode = audioContext.createMediaElementSource(localPlayer);

        mainPlayerNode.connect(gainNode);
        gainNode.connect(audioContext.destination);
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
        if (audioContext && audioContext.state === 'suspended') {
            audioContext.resume();
        }
        if (animationFrameId) cancelAnimationFrame(animationFrameId);
        animationFrameId = requestAnimationFrame(smoothUpdateLoop);
    });

    localPlayer.addEventListener('pause', () => {
        if (!isSeeking) {
            setPlayPauseIcon('play');
        }
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        cancelAnimationFrame(animationFrameId);
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

    // ▼▼▼ この古いイベントリスナーは不要になったため削除します ▼▼▼
    // elements.audioOutputSelect.addEventListener('change', ...);

    if ('mediaSession' in navigator) {
        navigator.mediaSession.setActionHandler('play', togglePlayPause);
        navigator.mediaSession.setActionHandler('pause', togglePlayPause);
        navigator.mediaSession.setActionHandler('nexttrack', onNextSongCallback);
        navigator.mediaSession.setActionHandler('previoustrack', onPrevSongCallback);
    }
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
            console.log(`[ノーマライザー適用] ${song.path.split(/[/\\]/).pop()}: 元音量 ${savedLoudness.toFixed(2)} LUFS -> 補正 ${gainDb.toFixed(2)} dB`);
        } else {
            baseGain = 1.0;
        }
        applyMasterVolume();
    }

    if ('mediaSession' in navigator) {
        const artworkDir = await ipcRenderer.invoke('get-artworks-dir');
        let artworkSrc = song.artwork ? `file://${path.join(artworkDir, song.artwork)}` : '';
        if (song.artwork && song.artwork.startsWith('http')) {
            artworkSrc = song.artwork;
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

function playLocal(song) {
    if (!song || !song.path) return;
    
    const safePath = song.path.replace(/\\/g, '/').replace(/#/g, '%23');
    localPlayer.src = `file://${safePath}`;

    localPlayer.play().catch(e => {
        if (e.name !== 'AbortError') console.error("Play error:", e);
    });
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
    if (audioContext && audioContext.state === 'suspended') {
        await audioContext.resume();
    }

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