// src/renderer/renderer.js
import './js/env-setup.js';
import { state, elements, initElements } from './js/state.js';
import { initEventListeners } from './js/init-listeners.js';
import { initUI } from './js/ui.js';
import { initSettings } from './js/init-settings.js';
import { initNavigation, showView } from './js/navigation.js';
import { initPlayer } from './js/player.js';
import { updateAudioDevices, updatePlayCountDisplay, addSongsToLibrary } from './js/ui-manager.js';
import { loadAllComponents } from './js/component-loader.js';
import { initIPC } from './js/ipc.js';
import { initModal } from './js/modal.js';
import { initDebugCommands } from './js/debug-commands.js';
import { initNormalizeView } from './js/normalize-view.js';
import { initEqualizer } from './js/ui/equalizer.js';
import { initQuiz } from './js/quiz.js';
// ▼▼▼ 修正: playNextSong, playPrevSong を適切にインポート ▼▼▼
import { playNextSong, playPrevSong } from './js/playback-manager.js';
import { initLazyLoader, observeNewImages } from './js/lazy-loader.js';
import { musicApi } from './js/bridge.js';
import { checkWails } from './js/wails-check.js';

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

    try {
        const settings = await musicApi.getSettings();
        if (settings) {
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
}

// 冗長で property 名が間違っていた古いヘルパー関数を削除
// 今後は playback-manager.js 内のロジックが使用されます。

initApp()
    .then(() => checkWails())
    .catch(err => console.error('App initialization failed:', err));