// uxmusic/src/renderer/js/playback-manager.js

import { state, elements, PLAYBACK_MODES } from '../core/state.js';
import { getCurrentTime, getDuration, play as playSongInPlayer, stop as stopSongInPlayer } from './player.js';
import { updatePlayingIndicators, renderQueueView } from '../ui/ui-manager.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { updateNowPlayingView } from '../ui/now-playing.js';
import { loadLyricsForSong } from './lyrics-manager.js';
import { resolveLocalPlaybackGain } from './playback-gain.js';
import { buildSkipEvent } from './playback-skip.js';
import { musicApi, isWailsMode } from '../core/bridge.js';
import { getSongById, getSongByPath } from '../core/library-model.js';
const electronAPI = window.electronAPI;
const pendingLoudnessRequests = new Set();

/** Overlapping playSong calls (queue clicks, skip spam) must not interleave awaits; last enqueued run still wins after prior runs finish. */
let playSongChain = Promise.resolve();

export function markLoudnessAnalysisCompleted(path) {
    if (typeof path !== 'string' || path.trim() === '') return;
    pendingLoudnessRequests.delete(path);
}

function handleSkip() {
    const event = buildSkipEvent({
        analysedQueueEnabled: state.analysedQueue.enabled,
        currentSongIndex: state.currentSongIndex,
        skippedSong: state.playbackQueue[state.currentSongIndex],
        currentTime: getCurrentTime(),
        duration: getDuration(),
    });
    if (event) {
        musicApi.songSkipped(event);
    }
}

/**
 * 起動時に保存された再生設定を読み込んで適用する
 */
export async function initPlaybackSettings() {
    console.log('[Debug:Playback] initPlaybackSettings を開始します。');
    const raw = await musicApi.getSettings();
    const settings = raw != null && typeof raw === 'object' ? raw : {};

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

export function playSong(index, sourceList = null, forcePlay = false) {
    const run = playSongChain.then(() => runPlaySongWork(index, sourceList, forcePlay));
    playSongChain = run.catch((err) => {
        console.warn('[Playback] playSong failed:', err);
    });
    return run;
}

async function runPlaySongWork(index, sourceList = null, forcePlay = false) {
    const targetQueue = sourceList || state.playbackQueue;
    const songToPlay = targetQueue[index];

    console.log(`[Debug:Playback] playSong 開始 - index: ${index}, 曲名: ${songToPlay?.title}`);
    if (!canStartPlayback(songToPlay)) {
        const localSong = await resolveRemotePlaybackDownload(songToPlay);
        if (!localSong) {
            return;
        }
        targetQueue[index] = localSong;
    }

    if (sourceList) {
        handleSkip();
    }

    state.songWaitingForAnalysis = null;

    if (sourceList) {
        state.originalQueueSource = sourceList;
        if (state.isShuffled) {
            const songToStartWith = sourceList[index];
            const newShuffledQueue = sourceList.filter(s => s.id !== songToStartWith.id);
            for (let i = newShuffledQueue.length - 1; i > 0; i--) {
                const j = Math.floor(Math.random() * (i + 1));
                [newShuffledQueue[i], newShuffledQueue[j]] = [newShuffledQueue[j], newShuffledQueue[i]];
            }
            newShuffledQueue.unshift(songToStartWith);
            state.playbackQueue = newShuffledQueue;
            index = 0;
        } else {
            state.playbackQueue = sourceList;
        }
    }

    const songList = state.playbackQueue;
    if (!songList || index < 0 || index >= songList.length) {
        console.warn('[Debug:Playback] 再生対象が見つかりません。停止します。');
        stopSongInPlayer();
        updateNowPlayingView(null);
        return;
    }

    const songToPlayActual = { ...songList[index] };
    if (!songToPlayActual.type && songToPlayActual.path) {
        songToPlayActual.type = 'local';
    }

    if (songToPlayActual.type === 'local' && songToPlayActual.id) {
        const librarySong = getSongById(songToPlayActual.id);
        if (librarySong) {
            Object.assign(songToPlayActual, librarySong);
            state.playbackQueue[index] = songToPlayActual;
        }
    }

    if (songToPlayActual.type === 'local' && (songToPlayActual.bpm === undefined || songToPlayActual.bpm === null)) {
        electronAPI.send('request-bpm-analysis', songToPlayActual);
    }

    let gainLinear = 1.0;
    if (songToPlayActual.type === 'local' && songToPlayActual.path) {
        const savedLoudnessRaw = await electronAPI.invoke('get-loudness-value', songToPlayActual.path);
        const settings = isWailsMode() ? await musicApi.getSettings() : null;
        const resolved = resolveLocalPlaybackGain({
            savedLoudnessRaw,
            targetLoudness: typeof settings?.targetLoudness === 'number' ? settings.targetLoudness : -18.0,
            forcePlay
        });
        gainLinear = resolved.gainLinear;

        if (resolved.shouldWaitForAnalysis) {
            state.songWaitingForAnalysis = { index, sourceList: state.playbackQueue, path: songToPlayActual.path };
            showNotification(`「${songToPlayActual.title}」の再生準備中です...`, false);
            if (!pendingLoudnessRequests.has(songToPlayActual.path)) {
                pendingLoudnessRequests.add(songToPlayActual.path);
                electronAPI.send('request-loudness-analysis', songToPlayActual.path);
            }
            renderQueueView();
            return;
        }
    }

    hideNotification();
    loadLyricsForSong(songToPlayActual);

    const prevIdx = state.currentSongIndex;
    const prevSong =
        prevIdx >= 0 && prevIdx < state.playbackQueue.length ? state.playbackQueue[prevIdx] : null;

    state.currentSongIndex = index;

    console.log('[Debug:Playback] UI更新関数(updateNowPlayingView, updatePlayingIndicators)を呼び出します。');
    updateNowPlayingView(songToPlayActual);
    updatePlayingIndicators();
    renderQueueView();

    const started = await playSongInPlayer(songToPlayActual, gainLinear);
    if (!started) {
        state.currentSongIndex = prevIdx;
        if (prevSong) {
            loadLyricsForSong(prevSong);
            updateNowPlayingView(prevSong);
        } else {
            loadLyricsForSong(null);
            updateNowPlayingView(null);
        }
        updatePlayingIndicators();
        renderQueueView();
        showNotification('再生を開始できませんでした。');
        hideNotification(4000);
        return;
    }

    musicApi.playbackStarted(songToPlayActual);
    prefetchUpcomingRemoteTracks(index);
}

export function canStartPlayback(song) {
    return song?.syncAvailability !== 'remote';
}

export async function resolveRemotePlaybackDownload(song, dependencies: any = {}) {
    if (song?.syncAvailability !== 'remote') {
        return song || null;
    }
    const sourceDeviceId = String(song.syncSourceDeviceId || '').trim();
    const sourceTrackId = String(song.syncSourceTrackId || '').trim();
    if (!sourceDeviceId || !sourceTrackId) {
        dependencies.notifyError?.('UX Sync: 取得元の曲情報が不足しています。');
        return null;
    }
    const downloadSyncTrack = dependencies.downloadSyncTrack || musicApi.downloadSyncTrack;
    const refreshLibrary = dependencies.refreshLibrary || musicApi.loadLibrary;
    const findLocalSong = dependencies.findLocalSong || ((result) => {
        const importedPath = result?.importedPaths?.[0];
        if (!importedPath) return null;
        return getSongByPath(importedPath) || { ...song, path: importedPath, syncAvailability: 'local', type: 'local' };
    });
    const notifyError = dependencies.notifyError || ((message) => {
        showNotification(`UX Sync: ${message}`);
        hideNotification(5000);
    });
    const notifyProgress = dependencies.notifyProgress || ((message) => {
        showNotification(message, false);
    });
    const clearProgress = dependencies.clearProgress || hideNotification;
    try {
        notifyProgress(`「${song.title || 'Remote track'}」を取得しています...`);
        const result = await downloadSyncTrack(sourceDeviceId, sourceTrackId);
        await refreshLibrary();
        const localSong = findLocalSong(result, song);
        if (!localSong) {
            notifyError('取得した曲をライブラリで見つけられませんでした。');
            return null;
        }
        clearProgress();
        return { ...localSong, syncAvailability: 'local' };
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error || '音源取得に失敗しました。');
        notifyError(message);
        return null;
    }
}

export function remoteQueuePrefetchRefs(queue, currentIndex, limit = 3) {
    if (!Array.isArray(queue) || limit <= 0) {
        return [];
    }
    return queue
        .slice(currentIndex + 1)
        .filter(song => song?.syncAvailability === 'remote' && song.syncSourceDeviceId && song.syncSourceTrackId)
        .slice(0, limit)
        .map(song => ({
            sourceDeviceId: String(song.syncSourceDeviceId),
            sourceTrackId: String(song.syncSourceTrackId),
        }));
}

function prefetchUpcomingRemoteTracks(currentIndex) {
    const refs = remoteQueuePrefetchRefs(state.playbackQueue, currentIndex, 3);
    if (refs.length === 0 || !musicApi.prefetchSyncTracks) {
        return;
    }
    void musicApi.prefetchSyncTracks(refs).catch((error) => {
        console.warn('[UX Sync] remote prefetch failed:', error);
    });
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
            renderQueueView();
            if (!isWailsMode()) {
                electronAPI.send('playback-stopped');
            }
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
    musicApi.saveSettings({ isShuffled: state.isShuffled });

    const currentSong = state.playbackQueue[state.currentSongIndex];

    if (state.isShuffled) {
        const newShuffledQueue = Array.from(state.originalQueueSource || []);

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
        state.playbackQueue = state.originalQueueSource || [];
        state.currentSongIndex = currentSong ? state.playbackQueue.findIndex(s => s.id === currentSong.id) : -1;
    }
    updatePlayingIndicators();
    renderQueueView();
}

export function toggleLoopMode() {
    const modes = Object.values(PLAYBACK_MODES) as string[];
    const currentIndex = modes.indexOf(state.playbackMode);
    const nextIndex = (currentIndex + 1) % modes.length;
    state.playbackMode = modes[nextIndex];

    elements.loopBtn.classList.toggle('active', state.playbackMode !== PLAYBACK_MODES.NORMAL);
    elements.loopBtn.classList.toggle('loop-one', state.playbackMode === PLAYBACK_MODES.LOOP_ONE);
    musicApi.saveSettings({ playbackMode: state.playbackMode });
}
