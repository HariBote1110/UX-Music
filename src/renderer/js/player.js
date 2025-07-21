// src/renderer/js/player.js (全体を置き換え)

let localPlayer;
let ytPlayer;
let ytPlayerPromise = null;
let currentSongType = 'local';
let timeUpdateInterval;

let elements = {};
let ipc;
let onSongEndedCallback = () => {};
let onNextSongCallback = () => {};
let onPrevSongCallback = () => {};

// --- 初期化 ---
export function initPlayer(playerElement, uiElements, appState, ipcRenderer, callbacks) {
    localPlayer = playerElement;
    elements = uiElements;
    ipc = ipcRenderer;
    onSongEndedCallback = callbacks.onSongEnded;
    onNextSongCallback = callbacks.onNextSong;
    onPrevSongCallback = callbacks.onPrevSong;

    localPlayer.addEventListener('ended', onSongEndedCallback);
    localPlayer.addEventListener('timeupdate', () => updateUiTime(localPlayer.currentTime, localPlayer.duration));
    localPlayer.addEventListener('play', () => {
        elements.playPauseBtn.textContent = '⏸';
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
    });
    localPlayer.addEventListener('pause', () => {
        elements.playPauseBtn.textContent = '▶';
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
    });

    elements.playPauseBtn.addEventListener('click', togglePlayPause);
    elements.progressBar.addEventListener('input', seek);
    elements.volumeSlider.addEventListener('input', setVolume);
    elements.audioOutputSelect.addEventListener('change', async (event) => {
        try {
            await localPlayer.setSinkId(event.target.value);
            ipc.send('save-audio-output-id', event.target.value);
        } catch (error) { console.error('Failed to set audio output device:', error); }
    });

    // Media Session API のハンドラを設定
    if ('mediaSession' in navigator) {
        navigator.mediaSession.setActionHandler('play', togglePlayPause);
        navigator.mediaSession.setActionHandler('pause', togglePlayPause);
        navigator.mediaSession.setActionHandler('nexttrack', onNextSongCallback);
        navigator.mediaSession.setActionHandler('previoustrack', onPrevSongCallback);
    }
}

// --- YouTubeプレーヤーを確実に取得するための関数 ---
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

// --- 公開メソッド ---
export async function play(song) {
    await stop();
    if (!song) {
        if ('mediaSession' in navigator) {
            navigator.mediaSession.metadata = null;
            navigator.mediaSession.playbackState = 'none';
        }
        return;
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

    const settings = await ipc.invoke('get-settings');
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

// --- 再生ロジック ---
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

// --- 共通コントロール ---
// ★★★ togglePlayPause関数をエクスポート ★★★
export async function togglePlayPause() {
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

async function setVolume() {
    const volume = parseFloat(elements.volumeSlider.value);
    const newVolume = parseFloat(elements.volumeSlider.value);
    if (currentSongType === 'youtube') {
        const player = await getYouTubePlayer();
        if (player && typeof player.setVolume === 'function') player.setVolume(volume * 100);
    } else {
        localPlayer.volume = volume;
    }
    ipc.send('save-settings', { volume: newVolume }); 
}

// --- イベントハンドラとヘルパー関数 ---
function onPlayerReady(event) {
    setVolume();
}
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