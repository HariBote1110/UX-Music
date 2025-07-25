import { state, elements, PLAYBACK_MODES } from './state.js';
import { play as playSongInPlayer, stop as stopSongInPlayer } from './player.js';
import { renderCurrentView } from './ui-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { updateNowPlayingView } from './ui/now-playing.js';
import { loadLyricsForSong } from './lyrics-manager.js';
const { ipcRenderer } = require('electron');

export async function playSong(index, sourceList = null, forcePlay = false) {
    // ★★★ 追加: 再生処理の開始時に、常に解析待ち状態をクリアする ★★★
    state.songWaitingForAnalysis = null;

    if (sourceList) {
        state.originalQueueSource = [...sourceList];
        if (state.isShuffled) {
            const songToStartWith = sourceList[index];
            let newShuffledQueue = sourceList.filter(s => s.path !== songToStartWith.path);
            for (let i = newShuffledQueue.length - 1; i > 0; i--) {
                const j = Math.floor(Math.random() * (i + 1));
                [newShuffledQueue[i], newShuffledQueue[j]] = [newShuffledQueue[j], newShuffledQueue[i]];
            }
            newShuffledQueue.unshift(songToStartWith);
            state.playbackQueue = newShuffledQueue;
            index = 0;
        } else {
            state.playbackQueue = [...sourceList];
        }
    }

    const songList = state.playbackQueue;
    if (!songList || index < 0 || index >= songList.length) {
        stopSongInPlayer();
        updateNowPlayingView(null);
        return;
    }
    const songToPlay = songList[index];

    if (songToPlay.type === 'local' && !forcePlay) {
        const savedLoudness = await ipcRenderer.invoke('get-loudness-value', songToPlay.path);
        if (typeof savedLoudness !== 'number') {
            state.songWaitingForAnalysis = { index, sourceList: state.playbackQueue };
            showNotification(`「${songToPlay.title}」の再生準備中です...`);
            ipcRenderer.send('request-loudness-analysis', songToPlay.path);
            return;
        }
    }
    
    hideNotification();
    
    loadLyricsForSong(songToPlay);
    
    ipcRenderer.send('song-finished', { songPath: songToPlay.path, duration: songToPlay.duration });
    state.currentSongIndex = index;
    
    updateNowPlayingView(songToPlay);
    renderCurrentView();
    await playSongInPlayer(songToPlay);
}

export function playNextSong() {
    if (state.playbackQueue.length === 0) return;

    if (state.playbackMode === PLAYBACK_MODES.LOOP_ONE) {
        playSong(state.currentSongIndex, null, true);
        return;
    }

    let nextIndex = state.currentSongIndex + 1;

    if (nextIndex >= state.playbackQueue.length) {
        if (state.playbackMode === PLAYBACK_MODES.LOOP_ALL) {
            nextIndex = 0;
        } else {
            stopSongInPlayer();
            updateNowPlayingView(null);
            loadLyricsForSong(null);
            state.currentSongIndex = -1;
            renderCurrentView();
            return;
        }
    }
    playSong(nextIndex);
}

export function playPrevSong() {
    if (state.playbackQueue.length === 0) return;
    let prevIndex = state.currentSongIndex - 1;
    if (prevIndex < 0) {
        prevIndex = state.playbackQueue.length - 1;
    }
    playSong(prevIndex);
}

export function toggleShuffle() {
    state.isShuffled = !state.isShuffled;
    elements.shuffleBtn.classList.toggle('active', state.isShuffled);

    const currentSong = state.playbackQueue[state.currentSongIndex];

    if (state.isShuffled) {
        const newShuffledQueue = [...state.originalQueueSource];
        
        const currentIndexInOriginal = newShuffledQueue.findIndex(s => s.path === currentSong?.path);
        if (currentIndexInOriginal > -1) {
            newShuffledQueue.splice(currentIndexInOriginal, 1);
        }

        for (let i = newShuffledQueue.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [newShuffledQueue[i], newShuffledQueue[j]] = [newShuffledQueue[j], newShuffledQueue[i]];
        }

        if (currentSong) {
            newShuffledQueue.unshift(currentSong);
        }

        state.playbackQueue = newShuffledQueue;
        state.currentSongIndex = currentSong ? 0 : -1;

    } else {
        state.playbackQueue = [...state.originalQueueSource];
        state.currentSongIndex = currentSong ? state.playbackQueue.findIndex(s => s.path === currentSong.path) : -1;
    }
    renderCurrentView();
}


export function toggleLoopMode() {
    const modes = Object.values(PLAYBACK_MODES);
    const currentIndex = modes.indexOf(state.playbackMode);
    const nextIndex = (currentIndex + 1) % modes.length;
    state.playbackMode = modes[nextIndex];

    elements.loopBtn.classList.toggle('active', state.playbackMode !== PLAYBACK_MODES.NORMAL);
    elements.loopBtn.classList.toggle('loop-one', state.playbackMode === PLAYBACK_MODES.LOOP_ONE);
}