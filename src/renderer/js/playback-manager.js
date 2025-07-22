import { state, elements, PLAYBACK_MODES } from './state.js';
import { play as playSongInPlayer, stop as stopSongInPlayer } from './player.js';
import { updateNowPlayingView, renderCurrentView } from './ui-manager.js';
const { ipcRenderer } = require('electron');

export async function playSong(index, sourceList = null) {
    // 1. 新しいリストから再生が開始された場合、再生キューを完全にリセットして再構築する
    if (sourceList) {
        state.originalQueueSource = [...sourceList];
        
        if (state.isShuffled) {
            // シャッフルが有効な場合：選択した曲を先頭にして、残りをシャッフルしたキューを新しく作成
            const songToStartWith = sourceList[index];
            let newShuffledQueue = sourceList.filter(s => s.path !== songToStartWith.path);
            
            // Fisher-Yates shuffle
            for (let i = newShuffledQueue.length - 1; i > 0; i--) {
                const j = Math.floor(Math.random() * (i + 1));
                [newShuffledQueue[i], newShuffledQueue[j]] = [newShuffledQueue[j], newShuffledQueue[i]];
            }
            
            newShuffledQueue.unshift(songToStartWith);
            state.playbackQueue = newShuffledQueue;
            index = 0; // 選択した曲が新しいキューの先頭になる
        } else {
            // シャッフルが無効な場合：そのまま再生キューとして設定
            state.playbackQueue = [...sourceList];
        }
    }

    // 2. 再生処理
    const songList = state.playbackQueue;
    if (!songList || index < 0 || index >= songList.length) {
        stopSongInPlayer();
        updateNowPlayingView(null);
        return;
    }

    const songToPlay = songList[index];

    // ★★★ ここからが修正箇所です ★★★
    // 再生カウントを記録し、ラウドネス解析をリクエストする
    ipcRenderer.send('song-finished', songToPlay.path);
    if (songToPlay.type === 'local') { // ローカルファイルのみ解析対象
        ipcRenderer.send('request-loudness-analysis', songToPlay.path);
    }
    // ★★★ ここまでが修正箇所です ★★★

    state.currentSongIndex = index;
    
    updateNowPlayingView(songToPlay);
    renderCurrentView();
    await playSongInPlayer(songToPlay);
}

export function playNextSong() {
    if (state.playbackQueue.length === 0) return;

    if (state.playbackMode === PLAYBACK_MODES.LOOP_ONE) {
        playSong(state.currentSongIndex);
        return;
    }

    let nextIndex = state.currentSongIndex + 1;

    if (nextIndex >= state.playbackQueue.length) {
        if (state.playbackMode === PLAYBACK_MODES.LOOP_ALL) {
            nextIndex = 0;
        } else {
            stopSongInPlayer();
            updateNowPlayingView(null);
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
        // シャッフルをONにする
        const newShuffledQueue = [...state.originalQueueSource];
        
        // 現在再生中の曲を先頭に持ってくる
        const currentIndexInOriginal = newShuffledQueue.findIndex(s => s.path === currentSong?.path);
        if (currentIndexInOriginal > -1) {
            newShuffledQueue.splice(currentIndexInOriginal, 1);
        }

        // 残りをシャッフル
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
        // シャッフルをOFFにする
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