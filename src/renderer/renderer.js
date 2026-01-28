// src/renderer/renderer.js
import './js/core/env-setup.js';
import { state, elements, initElements } from './js/core/state.js';
import { initEventListeners } from './js/core/init-listeners.js';
import { initUI } from './js/ui/ui.js';
import { initSettings } from './js/utils/init-settings.js';
import { initNavigation, showView } from './js/core/navigation.js';
import { initPlayer } from './js/features/player.js';
import { updateAudioDevices, updatePlayCountDisplay, addSongsToLibrary } from './js/ui/ui-manager.js';
import { restoreSavedSinkId } from './js/features/audio-graph.js';
import { loadAllComponents } from './js/ui/component-loader.js';
import { initIPC } from './js/core/ipc.js';
import { initModal } from './js/ui/modal.js';
import { initDebugCommands } from './js/utils/debug-commands.js';
import { initNormalizeView } from './js/features/normalize-view.js';
import { initEqualizer } from './js/ui/equalizer.js';
import { initQuiz } from './js/features/quiz.js';
// ▼▼▼ 修正: playNextSong, playPrevSong を適切にインポート ▼▼▼
import { playNextSong, playPrevSong } from './js/features/playback-manager.js';
import { initLazyLoader, observeNewImages } from './js/utils/lazy-loader.js';
import { musicApi } from './js/core/bridge.js';
import { checkWails } from './js/core/wails-check.js';

window.onerror = function (msg, url, line, col, error) {
    console.error(`[Global Error] ${msg} at ${url}:${line}:${col}`, error);
    return false;
};

window.onunhandledrejection = function (event) {
    console.error('[Unhandled Rejection]', event.reason);
};

const electronAPI = window.electronAPI;

window.artworkLoadTimes = [];
window.observeNewArtworks = (container) => observeNewImages(container || document);

async function initApp() {
    console.log('App initializing...');

    try {
        await loadAllComponents();
        console.log('Components loaded.');
    } catch (e) {
        console.error('Failed to load components:', e);
    }

    try {
        initElements();
    } catch (e) {
        console.error('Failed to init elements:', e);
    }

    initLazyLoader(elements.mainContent);

    const safeInit = (fn, name) => {
        try { fn(); } catch (e) { console.error(`Failed to init ${name}:`, e); }
    };

    safeInit(initUI, 'UI');
    safeInit(initNavigation, 'Navigation');
    safeInit(initEventListeners, 'EventListeners');
    safeInit(initSettings, 'Settings');
    safeInit(initModal, 'Modal');
    safeInit(initDebugCommands, 'DebugCommands');
    safeInit(initNormalizeView, 'NormalizeView');
    safeInit(initQuiz, 'Quiz');
    safeInit(initEqualizer, 'Equalizer');

    const mainPlayer = document.getElementById('main-player');
    if (mainPlayer) {
        // ▼▼▼ 修正: player.js のコールバックで playback-manager の関数を呼ぶように変更 ▼▼▼
        // これにより、曲遷移時に state.currentSongIndex が正しく更新され、UIが同期されます。
        await initPlayer(mainPlayer, {
            onSongEnded: () => {
                console.log('[Renderer] 曲が終了しました。次を再生します。');
                playNextSong();
            },
            onNextSong: () => {
                console.log('[Renderer] 次へボタンが押されました。');
                playNextSong();
            },
            onPrevSong: () => {
                console.log('[Renderer] 前へボタンが押されました。');
                playPrevSong();
            }
        });
        // ▲▲▲ 修正完了 ▲▲▲
    }

    musicApi.onAppInfoResponse((info) => {
        const appVersionEl = document.getElementById('app-version');
        if (appVersionEl) appVersionEl.textContent = `v${info.version}`;
    });

    musicApi.onLoadLibrary(async (data) => {
        if (!state.artworksDir) state.artworksDir = await musicApi.getArtworksDir();
        addSongsToLibrary({ songs: data.songs || [], albums: data.albums || {} });

        const initialView = state.activeViewId || 'track-view';
        showView(initialView);

        musicApi.requestPlaylistsWithArtwork();
        const loadingOverlay = document.getElementById('loading-overlay');
        if (loadingOverlay) loadingOverlay.classList.add('hidden');
    });

    electronAPI.on('settings-loaded', (settings) => {
        if (typeof settings.volume === 'number') {
            if (elements.volumeSlider) elements.volumeSlider.value = settings.volume;
        }
        state.visualizerMode = settings.visualizerMode || 'active';

        // オーディオ出力デバイスの設定を復元
        if (settings.audioOutputId) {
            restoreSavedSinkId(settings.audioOutputId);
        }

        if (typeof settings.isShuffled === 'boolean') {
            state.isShuffled = settings.isShuffled;
            if (elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffled);
        }
        if (typeof settings.groupAlbumArt === 'boolean') {
            state.groupAlbumArt = settings.groupAlbumArt;
            if (state.activeViewId === 'track-view') showView('track-view');
        }
        if (settings.enableYouTube) {
            document.querySelectorAll('[data-feature="youtube"]').forEach(el => el.classList.remove('hidden'));
        }
    });

    musicApi.onPlayCountsUpdated((counts) => {
        state.playCounts = counts;
        Object.keys(counts).forEach(songPath => updatePlayCountDisplay(songPath, counts[songPath].count));
    });

    musicApi.onPlaylistsUpdated((playlists) => {
        state.playlists = playlists;
        if (state.activeViewId === 'playlist-view') showView('playlist-view');
    });

    musicApi.onForceReloadPlaylist(async (playlistName) => {
        if (state.currentDetailView.type === 'playlist' && state.currentDetailView.identifier === playlistName) {
            const updatedDetails = await musicApi.getPlaylistDetails(playlistName);
            state.currentlyViewedSongs = updatedDetails.songs;
            showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: updatedDetails });
        }
    });

    // ▼▼▼ 追加: スキャン完了時にライブラリを更新 ▼▼▼
    electronAPI.on('scan-complete', (newSongs) => {
        console.log(`[Renderer] スキャン完了: ${newSongs?.length || 0}曲が追加されました`);
        if (newSongs && newSongs.length > 0) {
            addSongsToLibrary({ songs: newSongs, albums: {} });
            // 通知を表示（ipc.js の showNotification をインポートできない場合は直接表示）
            const notification = document.getElementById('notification');
            if (notification) {
                notification.textContent = `${newSongs.length}曲がライブラリに追加されました`;
                notification.classList.add('visible');
                setTimeout(() => notification.classList.remove('visible'), 3000);
            }
        }
    });
    // ▲▲▲ 追加ここまで ▲▲▲

    musicApi.requestAppInfo();
    musicApi.requestInitialPlayCounts();

    try {
        const settings = await musicApi.getSettings();
        if (settings) {
            if (typeof settings.volume === 'number') {
                if (elements.volumeSlider) {
                    elements.volumeSlider.value = settings.volume;
                    // UIの数値表示などの更新が必要ならここで行う
                }
            }
            if (settings.audioOutputId) {
                restoreSavedSinkId(settings.audioOutputId);
            }

            if (typeof settings.groupAlbumArt === 'boolean') {
                state.groupAlbumArt = settings.groupAlbumArt;
            }
            if (typeof settings.isShuffled === 'boolean') {
                state.isShuffled = settings.isShuffled;
                if (elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffled);
            }
        }

        if (settings.libraryPath) {
            musicApi.loadLibrary();
        } else {
            const loadingOverlay = document.getElementById('loading-overlay');
            if (loadingOverlay) loadingOverlay.classList.add('hidden');
        }
    } catch (e) {
        console.error('Failed to load settings or library:', e);
        const loadingOverlay = document.getElementById('loading-overlay');
        if (loadingOverlay) loadingOverlay.classList.add('hidden');
    }

    electronAPI.send('app-ready');

    try {
        updateAudioDevices();
    } catch (e) {
        console.error('Failed to update audio devices:', e);
    }

    console.log('[Renderer] Initializing IPC listeners...');
    initIPC({
        onFlacIndexProgress: (progress) => {
            const container = document.getElementById('flac-index-progress-container');
            const bar = document.getElementById('flac-index-progress-bar');
            const status = document.getElementById('flac-index-status');
            if (container && bar && status) {
                container.classList.remove('hidden');
                const percent = (progress.current / progress.total) * 100;
                bar.style.width = `${percent}%`;
                status.textContent = `解析中: ${progress.current} / ${progress.total} (${progress.path})`;
            }
        },
        onFlacIndexComplete: (total) => {
            const status = document.getElementById('flac-index-status');
            if (status) {
                status.textContent = `完了: ${total}個のファイルを解析しました。`;
                status.style.color = '#28a745';
            }
            setTimeout(() => {
                const container = document.getElementById('flac-index-progress-container');
                if (container) container.classList.add('hidden');
            }, 5000);
        }
    });
}

// 冗長で property 名が間違っていた古いヘルパー関数を削除
// 今後は playback-manager.js 内のロジックが使用されます。

initApp()
    .then(() => checkWails())
    .catch(err => console.error('App initialization failed:', err));