// uxmusic/src/renderer/js/playback-manager.js

import { state, elements, PLAYBACK_MODES } from '../core/state.js';
import {
    getCurrentTime,
    getDuration,
    play as playSongInPlayer,
    stop as stopSongInPlayer,
    playCurrent as playCurrentInPlayer,
    pauseCurrent as pauseCurrentInPlayer,
    seek as seekInPlayer,
    isPlaying as isPlayingInPlayer,
    playQueueEmbedItem,
    setGoQueueActive
} from './player.js';
import { updatePlayingIndicators, renderQueueView } from '../ui/ui-manager.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { updateNowPlayingView } from '../ui/now-playing.js';
import { loadLyricsForSong } from './lyrics-manager.js';
import { resolveLocalPlaybackGain } from './playback-gain.js';
import { buildSkipEvent } from './playback-skip.js';
import { musicApi, isWailsMode, getWailsApp } from '../core/bridge.js';
import { getSongById, getSongByPath } from '../core/library-model.js';
import {
    mapQueueSnapshotToQueueState,
    nextLoopMode,
    shouldRecordQueueAdvancedSkip,
    toGoLoopMode,
    type QueueStatePayload,
} from './queue-bridge.js';
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

    initRemotePlaySongListener();
    initRemoteCommandListener();
    initRemoteEmbedCommandListener();

    if (isWailsMode()) {
        await initGoQueueBridge();
    }
}

/**
 * Go の再生キュー（server/app_queue.go）への配線。
 * markdown/background-native-queue-plan.md Phase 1（フロントエンド
 * カットオーバー）。isWailsMode() のときだけ呼ばれる — 非 Wails の
 * ブラウザフォールバックは従来どおり JS 側キュー（本ファイルの
 * playNextSong 等のレガシー分岐）で完結する。
 */
async function initGoQueueBridge() {
    if (window.runtime && typeof window.runtime.EventsOn === 'function') {
        window.runtime.EventsOn('queue-state-changed', (payload: unknown) => {
            handleQueueStateChangedEvent(payload as QueueStatePayload);
        });
        window.runtime.EventsOn('queue-advanced', (payload: unknown) => {
            handleQueueAdvancedEvent(payload);
        });
        window.runtime.EventsOn('queue-play-embed', (payload: unknown) => {
            void handleQueuePlayEmbedEvent(payload);
        });
    }

    // Go 側のキューは（アプリ起動のたびに）空のシャッフル/ループ設定で
    // 生成される。永続化された設定（settings.isShuffled/playbackMode、
    // 上でこの関数の呼び出し元がすでに state へ復元済み）を種付けしておく
    // — Queue はアクティブ化前でもフラグだけは保持でき、後で最初の
    // QueueSet() が呼ばれたときにそのまま効く
    // （progress/native-play-queue.md のシャッフル/SetQueue 挙動を参照）。
    void getWailsApp()?.QueueSetShuffle?.(state.isShuffled);
    void getWailsApp()?.QueueSetLoopMode?.(toGoLoopMode(state.playbackMode));

    // Phase 2（WebView 駐機/復帰）では、Go のキューがアクティブなまま
    // SPA だけが再読み込みされる場面が出てくる。そのときにこの
    // QueueGetState() 呼び出しが UI 復元のシームになる。Phase 1 の
    // 通常起動では単に「まだ何も再生していない」状態が返るだけ。
    const initialQueueState = await getWailsApp()?.QueueGetState?.();
    if (initialQueueState) {
        handleQueueStateChangedEvent(initialQueueState as QueueStatePayload);
    }

    // Phase 2（WebView 駐機/復帰）本体。QueueGetState() の直後という順序が
    // 重要 — restoreFromPark() は保留インテント（queue-play-embed/
    // remote-play-song）を再生前に、まずキュー状態が正しく復元済みである
    // ことを前提にする（park.ts 参照）。initParkBridge() は次回の駐機に
    // 備えた app-visibility-changed の購読で、この呼び出しの成否とは独立。
    // park.ts からこのファイルの handleQueuePlayEmbedEvent/
    // handleRemotePlaySongEvent への参照と合わせて循環 import になるため、
    // トップレベルではなくここで動的 import する
    // （両者とも関数呼び出し内でしか使わないので実害はない）。
    const { initParkBridge, restoreFromPark } = await import('./park.js');
    initParkBridge();
    await restoreFromPark();
}

/**
 * Go 側 (server/app_remote.go の remoteCommandHandler, action: "play-song") が
 * emit する "remote-play-song" イベントを購読する。ペア済みクライアント
 * (Apple TV 等) からライブラリ楽曲 ID を指定した再生要求を受け取り、
 * ユーザーが曲をクリックした場合と同じ playSong() 経路へ合流させる
 * (ローカル曲はそのまま再生され、YouTube 由来の曲は公式埋め込み経由の
 * 再生 → LAN 中継へ自動的に進む)。Wails 環境以外 (ブラウザプレビュー等)
 * では window.runtime が存在しないため何もしない。
 */
function initRemotePlaySongListener() {
    if (!window.runtime || typeof window.runtime.EventsOn !== 'function') {
        return;
    }
    window.runtime.EventsOn('remote-play-song', (songId: unknown) => {
        handleRemotePlaySongEvent(songId);
    });
}

/**
 * "remote-play-song" イベントの本体処理。依存を注入できる形にして
 * ユニットテストから検証できるようにしている
 * (playback-manager.test.ts の describe('handleRemotePlaySongEvent', ...))。
 */
export function handleRemotePlaySongEvent(songId: unknown, deps: {
    findSong?: (id: string) => unknown;
    notifyNotFound?: () => void;
    playResolvedSong?: (song: unknown) => void;
    markRemoteInitiated?: () => void;
} = {}) {
    const findSong = deps.findSong ?? getSongById;
    const notifyNotFound = deps.notifyNotFound ?? (() => showNotification('指定された曲がライブラリに見つかりませんでした。'));
    const playResolvedSong = deps.playResolvedSong ?? ((song: unknown) => playSong(0, [song]));
    // PC自体のスピーカーを無音化するためのGo側フラグ (App.MarkNextPlaybackRemoteInitiated)
    // を立てる。次の1回のAudioPlay/AudioStartWebViewTapだけに効く一度きりの
    // マーカーなので、必ずplayResolvedSong（=playSong経由の再生開始）の前に呼ぶ。
    const markRemoteInitiated = deps.markRemoteInitiated ?? (() => getWailsApp()?.MarkNextPlaybackRemoteInitiated?.());

    if (typeof songId !== 'string' || songId.trim() === '') {
        return;
    }
    const song = findSong(songId);
    if (!song) {
        notifyNotFound();
        return;
    }
    markRemoteInitiated();
    playResolvedSong(song);
}

/**
 * Go 側 (server/app_remote.go の remoteCommandHandler, action: "next"/"prev")
 * が emit する "remote-command" イベントを購読する。next/prev はキュー管理が
 * レンダラー側 (このファイルの playNextSong/playPrevSong) にしかない概念な
 * ので、embed 再生中かどうかに関わらず常にこの経路で処理する — 遷移先の曲を
 * playSong() → play() へ渡す時点で、埋め込み/ローカルいずれの再生経路にも
 * 正しく再突入する。
 */
function initRemoteCommandListener() {
    if (!window.runtime || typeof window.runtime.EventsOn !== 'function') {
        return;
    }
    window.runtime.EventsOn('remote-command', (action: unknown) => {
        handleRemoteCommandEvent(action);
    });
}

export function handleRemoteCommandEvent(action: unknown, deps: {
    playNext?: () => void;
    playPrev?: () => void;
} = {}) {
    const playNext = deps.playNext ?? playNextSong;
    const playPrev = deps.playPrev ?? playPrevSong;

    switch (action) {
        case 'next':
            playNext();
            break;
        case 'prev':
            playPrev();
            break;
        default:
            break;
    }
}

/**
 * Go 側 (server/app_remote.go の remoteCommandHandler) が、YouTube 公式埋め込み
 * セッション中 (remoteRelay がアクティブ) に emit する "remote-embed-command"
 * イベントを購読する。toggle/play/pause/stop/seek をそのまま Go の
 * audio.Player へ流しても、実際に鳴っているのはレンダラー内の IFrame プレイ
 * ヤーなので届かない。player.ts の playCurrent/pauseCurrent/seek/stop は
 * isEmbedPlayerActive() を見て埋め込み/ローカルを自動判別する既存の実装な
 * ので、ここではそれらをそのまま呼び出すだけでよい。
 */
function initRemoteEmbedCommandListener() {
    if (!window.runtime || typeof window.runtime.EventsOn !== 'function') {
        return;
    }
    window.runtime.EventsOn('remote-embed-command', (payload: unknown) => {
        handleRemoteEmbedCommandEvent(payload);
    });
}

export function handleRemoteEmbedCommandEvent(payload: unknown, deps: {
    playCurrent?: () => void;
    pauseCurrent?: () => void;
    stop?: () => void;
    seek?: (time: number) => void;
    isPlaying?: () => boolean;
} = {}) {
    const doPlay = deps.playCurrent ?? playCurrentInPlayer;
    const doPause = deps.pauseCurrent ?? pauseCurrentInPlayer;
    const doStop = deps.stop ?? stopSongInPlayer;
    const doSeek = deps.seek ?? seekInPlayer;
    const checkIsPlaying = deps.isPlaying ?? isPlayingInPlayer;

    if (payload === null || typeof payload !== 'object') {
        return;
    }
    const { action, value } = payload as { action?: unknown; value?: unknown };

    switch (action) {
        case 'toggle':
            if (checkIsPlaying()) {
                doPause();
            } else {
                doPlay();
            }
            break;
        case 'play':
            doPlay();
            break;
        case 'pause':
            doPause();
            break;
        case 'stop':
            doStop();
            break;
        case 'seek':
            if (typeof value === 'number' && Number.isFinite(value)) {
                doSeek(value);
            }
            break;
        default:
            break;
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
    if (isWailsMode()) {
        // Go の再生キューへ全面委任する（markdown/background-native-queue-plan.md
        // Phase 1）。ローディング・シャッフル並び替え・再生開始・再生回数
        // 計上はすべて server/app_queue.go 側で完結し、結果は
        // "queue-state-changed"/"queue-advanced" イベント経由で戻ってくる
        // （initGoQueueBridge が購読している handleQueueStateChangedEvent/
        // handleQueueAdvancedEvent 参照）。forcePlay はラウドネス解析待ち
        // 用のJSレガシー概念で、Go 側は待ち合わせをしないため使わない。
        return runPlaySongWorkWails(index, sourceList);
    }

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

/**
 * playSong() の Wails 分岐の本体。sourceList が渡されたとき（曲一覧・
 * アルバム全曲再生などの「新しいキューを始める」操作）は QueueSet で
 * キューを丸ごと差し替え、渡されなかったとき（再生キューサイドバーの
 * 項目クリックのような「既存キュー内の移動」操作）は QueueJump で
 * その場ジャンプする。UX Sync のリモート曲だけは Go に判断させられない
 * （ローカルへのダウンロードが要る）ため、従来どおりここで先に解決する。
 */
export async function runPlaySongWorkWails(index, sourceList = null, deps: any = {}) {
    const getApp = deps.getApp ?? getWailsApp;
    const canStart = deps.canStartPlayback ?? canStartPlayback;
    const resolveDownload = deps.resolveRemotePlaybackDownload ?? resolveRemotePlaybackDownload;

    const targetQueue = sourceList || state.playbackQueue;
    const songToPlay = targetQueue[index];
    if (!songToPlay) {
        console.warn('[Debug:Playback][Wails] 再生対象が見つかりません。');
        return;
    }

    if (!canStart(songToPlay)) {
        const localSong = await resolveDownload(songToPlay);
        if (!localSong) {
            return;
        }
        targetQueue[index] = localSong;
    }

    const app = getApp();
    if (!app) {
        console.warn('[Debug:Playback][Wails] Wails app binding が見つかりません。');
        return;
    }

    if (sourceList) {
        await app.QueueSet(sourceList, index);
    } else {
        await app.QueueJump(index);
    }
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
    if (isWailsMode()) {
        // Go がループモード判定・末尾処理・再生開始をすべて行う
        // （pkg/playqueue.Queue.Advance）。結果は queue-state-changed/
        // queue-advanced 経由で戻ってくる。
        void getWailsApp()?.QueueNext?.();
        return;
    }

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
    if (isWailsMode()) {
        void getWailsApp()?.QueuePrev?.();
        return;
    }

    handleSkip();
    if (state.playbackQueue.length === 0) return;
    let prevIndex = state.currentSongIndex - 1;
    if (prevIndex < 0) {
        prevIndex = state.playbackQueue.length - 1;
    }
    playSong(prevIndex);
}

/** state.isShuffled/state.playbackMode を shuffle/loop ボタンの見た目に反映する。 */
function updateShuffleLoopButtonsUI(isShuffled: boolean, playbackMode: string) {
    elements.shuffleBtn.classList.toggle('active', isShuffled);
    elements.loopBtn.classList.toggle('active', playbackMode !== PLAYBACK_MODES.NORMAL);
    elements.loopBtn.classList.toggle('loop-one', playbackMode === PLAYBACK_MODES.LOOP_ONE);
}

export function toggleShuffle() {
    if (isWailsMode()) {
        const next = !state.isShuffled;
        // Goからの queue-state-changed で確定反映されるが、押した瞬間の
        // 手応えのためにここでも即時にボタンを更新しておく。
        updateShuffleLoopButtonsUI(next, state.playbackMode);
        musicApi.saveSettings({ isShuffled: next });
        void getWailsApp()?.QueueSetShuffle?.(next);
        return;
    }

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
    if (isWailsMode()) {
        const next = nextLoopMode(state.playbackMode);
        updateShuffleLoopButtonsUI(state.isShuffled, next);
        musicApi.saveSettings({ playbackMode: next });
        void getWailsApp()?.QueueSetLoopMode?.(toGoLoopMode(next));
        return;
    }

    const modes = Object.values(PLAYBACK_MODES) as string[];
    const currentIndex = modes.indexOf(state.playbackMode);
    const nextIndex = (currentIndex + 1) % modes.length;
    state.playbackMode = modes[nextIndex];

    elements.loopBtn.classList.toggle('active', state.playbackMode !== PLAYBACK_MODES.NORMAL);
    elements.loopBtn.classList.toggle('loop-one', state.playbackMode === PLAYBACK_MODES.LOOP_ONE);
    musicApi.saveSettings({ playbackMode: state.playbackMode });
}

/**
 * Go の "queue-state-changed" を state.playbackQueue/currentSongIndex/
 * isShuffled/playbackMode へ写像し、既存の UI 描画関数（ui-manager.ts の
 * updatePlayingIndicators/renderQueueView 等）をそのまま再利用して画面へ
 * 反映する。Go が唯一の真実源になったので、ここでは「表示するだけ」。
 */
export function handleQueueStateChangedEvent(payload: QueueStatePayload | null | undefined, deps: any = {}) {
    const findSong = deps.findSong ?? getSongById;
    const doUpdatePlayingIndicators = deps.updatePlayingIndicators ?? updatePlayingIndicators;
    const doRenderQueueView = deps.renderQueueView ?? renderQueueView;
    const doUpdateNowPlayingView = deps.updateNowPlayingView ?? updateNowPlayingView;
    const doLoadLyricsForSong = deps.loadLyricsForSong ?? loadLyricsForSong;
    const doPrefetchUpcomingRemoteTracks = deps.prefetchUpcomingRemoteTracks ?? prefetchUpcomingRemoteTracks;
    const doUpdateShuffleLoopButtons = deps.updateShuffleLoopButtons ?? updateShuffleLoopButtonsUI;

    const mapped = mapQueueSnapshotToQueueState(payload, findSong);

    state.playbackQueue = mapped.playbackQueue;
    state.currentSongIndex = mapped.currentSongIndex;
    state.isShuffled = mapped.isShuffled;
    state.playbackMode = mapped.playbackMode;

    setGoQueueActive(Boolean((payload as { active?: unknown } | null | undefined)?.active));

    doUpdateShuffleLoopButtons(mapped.isShuffled, mapped.playbackMode);
    doUpdatePlayingIndicators();
    doRenderQueueView();

    const currentSong = mapped.currentSongIndex >= 0 ? mapped.playbackQueue[mapped.currentSongIndex] : null;
    doUpdateNowPlayingView(currentSong);
    doLoadLyricsForSong(currentSong);
    doPrefetchUpcomingRemoteTracks(mapped.currentSongIndex);
}

/**
 * 駐機復帰時のジャケット欠落バグ（progress/webview-parking.md）対策。
 *
 * initGoQueueBridge() の QueueGetState() 呼び出しは、renderer.ts の
 * musicApi.loadLibrary() 応答（state.library への曲データ投入）を待たない
 * ため、通常の駐機復帰（Go 側のキューが再生中のまま SPA だけ再起動する
 * ケース）では hydrateQueueItem() の findSong(id) が全滅し、
 * artwork フィールドを持たないフォールバック Song で
 * state.playbackQueue が埋まってしまう。ライブラリ読み込み完了後に
 * 一度だけ QueueGetState() を再取得して handleQueueStateChangedEvent() を
 * 再適用することで、フォールバック Song をライブラリ由来の
 * （artwork を含む）本物の Song に置き換える。呼び出し元は
 * renderer.ts の musicApi.onLoadLibrary ハンドラ。
 */
export async function refreshQueueDisplayFromGoState(deps: {
    isWails?: () => boolean;
    getApp?: () => { QueueGetState?: () => Promise<unknown> } | null | undefined;
    apply?: (payload: QueueStatePayload | null | undefined) => void;
} = {}) {
    const wails = deps.isWails ?? isWailsMode;
    if (!wails()) return;

    const getApp = deps.getApp ?? getWailsApp;
    const apply = deps.apply ?? handleQueueStateChangedEvent;

    const payload = await getApp()?.QueueGetState?.();
    if (payload) {
        apply(payload as QueueStatePayload);
    }
}

/**
 * Go の "queue-advanced" ({previousId, reason}) を受けて analysed-queue の
 * スコアリングを行う。Go がキューを丸ごと動かすようになったことで、
 * レンダラーはもう「自然終了」と「ユーザースキップ」をplayer.tsの
 * イベント発火元だけでは区別できない（server/app_queue.go 参照）ため、
 * reason で明示的に振り分ける。
 */
export function handleQueueAdvancedEvent(payload: unknown, deps: any = {}) {
    if (!payload || typeof payload !== 'object') return;
    const { previousId, reason } = payload as { previousId?: unknown; reason?: unknown };
    if (typeof previousId !== 'string' || previousId.trim() === '') return;

    const analysedQueueEnabled = deps.analysedQueueEnabled ?? state.analysedQueue.enabled;
    if (!analysedQueueEnabled) return;

    const findSong = deps.findSong ?? getSongById;
    const song = findSong(previousId);
    if (!song) return;

    const doSongFinished = deps.songFinished ?? musicApi.songFinished;
    const doSongSkipped = deps.songSkipped ?? musicApi.songSkipped;
    const doGetCurrentTime = deps.getCurrentTime ?? getCurrentTime;
    const doGetDuration = deps.getDuration ?? getDuration;

    if (reason === 'finished') {
        doSongFinished(song);
    } else if (reason === 'user') {
        const currentTime = doGetCurrentTime();
        const duration = doGetDuration();
        if (shouldRecordQueueAdvancedSkip(currentTime, duration)) {
            doSongSkipped({ song, currentTime });
        }
    }
}

/**
 * Go の "queue-play-embed"（server/app_queue.go の startQueueItem embed
 * 経路）を受けて、YouTube 公式再生をレンダラー側で開始する。経路判定
 * （ローカル/ストリーム/embed）はすでに Go 側で完了しているので、ここでは
 * 無条件に embed 再生へ入る。埋め込み経路の再生回数計上はここが唯一の
 * 起点（Go の startQueueItem は embed のときだけ IncrementPlayCount を
 * 呼ばない — 二重計上防止、progress/native-play-queue.md 参照）。
 */
export async function handleQueuePlayEmbedEvent(payload: unknown, deps: any = {}) {
    if (!payload || typeof payload !== 'object') return;

    const findSong = deps.findSong ?? getSongById;
    const doPlayEmbedItem = deps.playEmbedItem ?? playQueueEmbedItem;
    const doPlaybackStarted = deps.playbackStarted ?? musicApi.playbackStarted;
    const doLoadLyricsForSong = deps.loadLyricsForSong ?? loadLyricsForSong;

    const raw = payload as { id?: unknown; type?: unknown; path?: unknown; title?: unknown; artist?: unknown; album?: unknown };
    const id = typeof raw.id === 'string' ? raw.id : '';
    const song = (id ? findSong(id) : null) ?? {
        id,
        type: 'youtube',
        path: typeof raw.path === 'string' ? raw.path : '',
        title: typeof raw.title === 'string' ? raw.title : '',
        artist: typeof raw.artist === 'string' ? raw.artist : '',
        album: typeof raw.album === 'string' ? raw.album : '',
    };

    doLoadLyricsForSong(song);
    const started = await doPlayEmbedItem(song);
    if (started) {
        doPlaybackStarted(song);
    }
}
