// uxmusic/src/renderer/js/playback-manager.js

import { state, elements, PLAYBACK_MODES } from './state.js';
import { play as playSongInPlayer, stop as stopSongInPlayer } from './player.js';
import { updatePlayingIndicators, renderCurrentView } from './ui-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { updateNowPlayingView } from './ui/now-playing.js';
import { loadLyricsForSong } from './lyrics-manager.js';
const electronAPI = window.electronAPI;

function handleSkip() {
    if (state.analysedQueue.enabled && state.currentSongIndex > -1) {
        const skippedSong = state.playbackQueue[state.currentSongIndex];
        const player = document.getElementById('main-player');
        if (skippedSong && player && player.currentTime > 0 && player.duration > 0) {
            electronAPI.send('song-skipped', { song: skippedSong, currentTime: player.currentTime });
        }
    }
}

/**
 * 起動時に保存された再生設定を読み込んで適用する
 */
export async function initPlaybackSettings() {
    console.log('[Debug:Playback] initPlaybackSettings を開始します。');
    const settings = await electronAPI.invoke('get-settings');

    if (settings.isShuffled !== undefined) {
        state.isShuffled = settings.isShuffled;
        elements.shuffleBtn.classList.toggle('active', state.isShuffled);
        console.log(`[Debug:Playback] シャッフル設定を復元: ${state.isShuffled}`);
    }

    if (settings.playbackMode !== undefined) {
        state.playbackMode = settings.playbackMode;
        elements.loopBtn.classList.toggle('active', state.playbackMode !== PLAYBACK_MODES.NORMAL);
        elements.loopBtn.classList.toggle('loop-one', state.playbackMode === PLAYBACK_MODES.LOOP_ONE);
        console.log(`[Debug:Playback] ループモードを復元: ${state.playbackMode}`);
    }
}

export async function playSong(index, sourceList = null, forcePlay = false) {
    const targetQueue = sourceList || state.playbackQueue;
    const songToPlay = targetQueue[index];

    console.log(`[Debug:Playback] playSong 開始 - index: ${index}, 曲名: ${songToPlay?.title}`);

    if (sourceList) {
        handleSkip();
    }

    state.songWaitingForAnalysis = null;

    if (sourceList) {
        state.originalQueueSource = [...sourceList];
        if (state.isShuffled) {
            const songToStartWith = sourceList[index];
            let newShuffledQueue = sourceList.filter(s => s.id !== songToStartWith.id);
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
        console.warn('[Debug:Playback] 再生対象が見つかりません。停止します。');
        stopSongInPlayer();
        updateNowPlayingView(null);
        return;
    }

    let songToPlayActual = songList[index];

    if (songToPlayActual.type === 'local' && songToPlayActual.id) {
        const librarySong = state.library.find(s => s.id === songToPlayActual.id);
        if (librarySong) {
            Object.assign(songToPlayActual, librarySong);
            state.playbackQueue[index] = songToPlayActual;
        }
    }

    if (songToPlayActual.type === 'local' && (songToPlayActual.bpm === undefined || songToPlayActual.bpm === null)) {
        electronAPI.send('request-bpm-analysis', songToPlayActual);
    }

    if (songToPlayActual.type === 'local' && !forcePlay) {
        const savedLoudness = await electronAPI.invoke('get-loudness-value', songToPlayActual.path);
        if (typeof savedLoudness !== 'number') {
            state.songWaitingForAnalysis = { index, sourceList: state.playbackQueue };
            showNotification(`「${songToPlayActual.title}」の再生準備中です...`);
            electronAPI.send('request-loudness-analysis', songToPlayActual.path);
            return;
        }
    }

    hideNotification();
    loadLyricsForSong(songToPlayActual);

    electronAPI.send('playback-started', songToPlayActual);
    state.currentSongIndex = index;

    console.log('[Debug:Playback] UI更新関数(updateNowPlayingView, updatePlayingIndicators)を呼び出します。');
    updateNowPlayingView(songToPlayActual);
    updatePlayingIndicators();

    await playSongInPlayer(songToPlayActual);
}

export function playNextSong() {
    handleSkip();
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
            updatePlayingIndicators();
            electronAPI.send('playback-stopped');
            return;
        }
    }
    playSong(nextIndex);
}

export function playPrevSong() {
    handleSkip();
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
    electronAPI.send('save-settings', { isShuffled: state.isShuffled });

    const currentSong = state.playbackQueue[state.currentSongIndex];

    if (state.isShuffled) {
        const newShuffledQueue = [...state.originalQueueSource];

        const currentIndexInOriginal = newShuffledQueue.findIndex(s => s.id === currentSong?.id);
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
        state.currentSongIndex = currentSong ? state.playbackQueue.findIndex(s => s.id === currentSong.id) : -1;
    }
    updatePlayingIndicators();
}

export function toggleLoopMode() {
    const modes = Object.values(PLAYBACK_MODES);
    const currentIndex = modes.indexOf(state.playbackMode);
    const nextIndex = (currentIndex + 1) % modes.length;
    state.playbackMode = modes[nextIndex];

    elements.loopBtn.classList.toggle('active', state.playbackMode !== PLAYBACK_MODES.NORMAL);
    elements.loopBtn.classList.toggle('loop-one', state.playbackMode === PLAYBACK_MODES.LOOP_ONE);
    electronAPI.send('save-settings', { playbackMode: state.playbackMode });
}