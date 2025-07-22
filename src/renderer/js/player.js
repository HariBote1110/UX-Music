import { elements } from './state.js';
const { ipcRenderer } = require('electron');

let audioContext;
let mainPlayerNode;
let gainNode;
let baseGain = 1.0; // ノーマライザーによって決定される基準音量を保持する変数

let localPlayer;
let ytPlayer;
let ytPlayerPromise = null;
let currentSongType = 'local';
let timeUpdateInterval;

let onSongEndedCallback = () => {};
let onNextSongCallback = () => {};
let onPrevSongCallback = () => {};

// ★★★ ここからが修正箇所です ★★★
/**
 * 現在の基準音量(baseGain)とマスター音量(スライダー)を組み合わせて最終的な音量を適用する
 */
export function applyMasterVolume() {
    if (!gainNode) return;
    const masterVolume = parseFloat(elements.volumeSlider.value); // 0.0 to 1.0
    const volumeMultiplier = masterVolume * 2; // スライダーの値を0%〜200%の倍率に変換
    gainNode.gain.value = baseGain * volumeMultiplier;
}
// ★★★ ここまでが修正箇所です ★★★

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

    localPlayer.addEventListener('ended', onSongEndedCallback);
    localPlayer.addEventListener('timeupdate', () => updateUiTime(localPlayer.currentTime, localPlayer.duration));
    localPlayer.addEventListener('play', () => {
        elements.playPauseBtn.textContent = '⏸';
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        if (audioContext && audioContext.state === 'suspended') {
            audioContext.resume();
        }
    });
    localPlayer.addEventListener('pause', () => {
        elements.playPauseBtn.textContent = '▶';
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
    });

    elements.playPauseBtn.addEventListener('click', togglePlayPause);
    elements.progressBar.addEventListener('input', seek);
    elements.volumeSlider.addEventListener('input', setVolume); // setVolumeを再度有効化
    elements.audioOutputSelect.addEventListener('change', async (event) => {
        try {
            if (audioContext && typeof audioContext.setSinkId === 'function') {
                await audioContext.setSinkId(event.target.value);
            } else {
                await localPlayer.setSinkId(event.target.value);
            }
            ipcRenderer.send('save-audio-output-id', event.target.value);
        } catch (error) { console.error('Failed to set audio output device:', error); }
    });

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
            baseGain = Math.pow(10, gainDb / 20); // デシベルをリニア値に変換してbaseGainに設定
            console.log(`[ノーマライザー適用] ${song.path.split(/[/\\]/).pop()}: 元音量 ${savedLoudness.toFixed(2)} LUFS -> 補正 ${gainDb.toFixed(2)} dB`);
        } else {
            baseGain = 1.0; // 解析データがない場合は基準音量を1.0 (補正なし) にリセット
        }
        applyMasterVolume(); // 新しい基準音量と現在のスライダー位置で音量を再適用
    }

    if ('mediaSession' in navigator) {
        const artworkSrc = song.artwork || '';
        navigator.mediaSession.metadata = new MediaMetadata({
            title: song.title || '不明なタイトル',
            artist: song.artist || '不明なアーティスト',
            album: song.album || '',
            artwork: artworkSrc ? [{ src: artworkSrc }] : []
        });
    }

    const settings = await ipcRenderer.invoke('get-settings');
    const mode = settings.youtubePlaybackMode || 'download';
    const isFromYouTube = song.sourceURL || song.type === 'youtube';
    const hasLocalFile = song.type === 'local' && song.path;

    if (mode === 'stream' && isFromYouTube) {
        currentSongType = 'youtube';
        elements.audioOutputSelect.disabled = true;
        const streamPath = song.sourceURL || song.path;
        playYoutube({ ...song, path: streamPath });
    } else if (hasLocalFile) {
        currentSongType = 'local';
        elements.audioOutputSelect.disabled = false;
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
    clearInterval(timeUpdateInterval);
}

function playLocal(song) {
    if (!song || !song.path) return;
    localPlayer.src = `file://${song.path.replace(/\\/g, '/')}`;
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
            if (state === YT.PlayerState.PLAYING) player.pauseVideo();
            else player.playVideo();
        }
    } else {
        if (localPlayer.paused) localPlayer.play();
        else localPlayer.pause();
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

// ★★★ ここからが修正箇所です (setVolumeを復活・修正) ★★★
/**
 * 音量スライダーが動かされたときに呼ばれる
 */
async function setVolume() {
    // 現在のスライダー位置に基づいてマスター音量を適用
    applyMasterVolume(); 
    
    // スライダーの位置を記憶するために設定を保存
    const volume = parseFloat(elements.volumeSlider.value);
    ipcRenderer.send('save-settings', { volume: volume }); 
}
// ★★★ ここまでが修正箇所です ★★★

function onPlayerStateChange(event) {
    const state = event.data;
    if (state === YT.PlayerState.PLAYING) {
        elements.playPauseBtn.textContent = '⏸';
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        timeUpdateInterval = setInterval(async () => {
            const player = await getYouTubePlayer();
            if (player && typeof player.getCurrentTime === 'function') {
                updateUiTime(player.getCurrentTime(), player.getDuration());
            }
        }, 500);
    } else {
        elements.playPauseBtn.textContent = '▶';
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