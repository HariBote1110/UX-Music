import { initUI, addSongsToLibrary, updatePlayCountDisplay } from './js/ui-manager.js';
import { initNavigation, showView } from './js/navigation.js';
import { initIPC } from './js/ipc.js';
import { initModal } from './js/modal.js';
// ▼▼▼ 修正箇所 ▼▼▼
import { initPlayer } from './js/player.js';
import { applyMasterVolume } from './js/audio-graph.js'; // player.js から audio-graph.js に変更
// ▲▲▲ 修正箇所 ▲▲▲
import { state, elements, initElements, PLAYBACK_MODES } from './js/state.js';
import { showNotification, hideNotification } from './js/ui/notification.js';
import { initDebugCommands } from './js/debug-commands.js';
import { initLazyLoader, observeNewImages } from './js/lazy-loader.js';
import { initNormalizeView } from './js/normalize-view.js';
import { initEqualizer, renderEqualizer, applyCurrentSettings } from './js/ui/equalizer.js';
import { initQuiz } from './js/quiz.js';
import { initEventListeners } from './js/init-listeners.js';
import { initSettings } from './js/init-settings.js';
import { playNextSong, playPrevSong } from './js/playback-manager.js';
import { showEditMetadataModal } from './js/edit-metadata.js'; // ★★★ 追加 ★★★
import { startLrcEditor } from './js/lrc-editor.js'; // ★★★ 追加 ★★★
const { ipcRenderer } = require('electron');

window.artworkLoadTimes = [];
window.observeNewArtworks = (container) => observeNewImages(container || document);

window.addEventListener('DOMContentLoaded', () => {
    initElements();
    initLazyLoader(elements.mainContent);

    initUI();
    initPlayer(document.getElementById('main-player'), {
        onSongEnded: playNextSong,
        onNextSong: playNextSong,
        onPrevSong: playPrevSong,
    });
    initEqualizer();
    initNavigation();
    initModal();
    initDebugCommands();
    initNormalizeView();
    initQuiz();
    initSettings();
    initEventListeners();

    initIPC(ipcRenderer, {
        onAppInfoResponse: (info) => {
            const appVersionEl = document.getElementById('app-version');
            if (appVersionEl) {
                appVersionEl.textContent = `v${info.version}`;
            }
        },
        onLibraryLoaded: async (data) => {
            if (!state.artworksDir) {
                state.artworksDir = await ipcRenderer.invoke('get-artworks-dir');
            }
            addSongsToLibrary({ songs: data.songs || [], albums: data.albums || {} });
            showView('track-view');
            ipcRenderer.send('request-playlists-with-artwork');
        },
        onSettingsLoaded: (settings) => {
            if (typeof settings.volume === 'number') {
                elements.volumeSlider.value = settings.volume;
                applyMasterVolume(); // audio-graph.js からインポートした関数
            }
            state.visualizerMode = settings.visualizerMode || 'active';
            if (typeof settings.isShuffled === 'boolean') {
                state.isShuffled = settings.isShuffled;
                elements.shuffleBtn.classList.toggle('active', state.isShuffled);
            }
            if (settings.playbackMode) {
                state.playbackMode = settings.playbackMode;
                elements.loopBtn.classList.toggle('active', state.playbackMode !== PLAYBACK_MODES.NORMAL);
                elements.loopBtn.classList.toggle('loop-one', state.playbackMode === PLAYBACK_MODES.LOOP_ONE);
            }
            if (typeof settings.groupAlbumArt === 'boolean') state.groupAlbumArt = settings.groupAlbumArt;
            if (settings.analysedQueue) {
                state.analysedQueue = settings.analysedQueue;
            }
            if (settings.equalizer) {
                state.equalizerSettings = { ...state.equalizerSettings, ...settings.equalizer };
                applyCurrentSettings();
                renderEqualizer();
            }
            if (settings.enableYouTube) {
                document.querySelectorAll('[data-feature="youtube"]').forEach(el => el.classList.remove('hidden'));
            }
            if (settings.quizUnlocked) {
                 const quizBtn = document.getElementById('quiz-view-btn');
                 if (quizBtn) quizBtn.classList.remove('hidden');
            }
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            Object.keys(counts).forEach(songPath => updatePlayCountDisplay(songPath, counts[songPath].count));
        },
        onYoutubeLinkProcessed: (song) => {
            showNotification(`「${song.title}」が追加されました。`);
            hideNotification(3000);
            addSongsToLibrary({ songs: [song] });
        },
        onScanComplete: (songs) => {
            addSongsToLibrary({ songs });
            showNotification(`${songs.length}曲のインポートが完了しました。`);
            hideNotification(3000);
        },
        onPlaylistsUpdated: (playlists) => {
            state.playlists = playlists;
            if (state.activeViewId === 'playlist-view') {
                showView('playlist-view');
            }
        },
        onShowLoading: (text) => {
            showNotification(text);
        },
        onHideLoading: () => {
            // No action needed for toast notifications
        },
        onScanProgress: (progress) => {
             showNotification(`ライブラリをスキャン中 (${progress.current} / ${progress.total})...`);
        },
        onShowError: (message) => {
             showNotification(`エラー: ${message}`);
             hideNotification(5000);
        },
        onPlaylistImportProgress: (progress) => {
             showNotification(`プレイリストインポート中: ${progress.title} (${progress.current}/${progress.total})`);
        },
        onPlaylistImportFinished: () => {
             showNotification('プレイリストのインポートが完了しました。');
             hideNotification(3000);
             ipcRenderer.send('request-playlists-with-artwork');
        },
        onForceReloadLibrary: () => {
            state.library = [];
            state.albums.clear();
            state.artists.clear();
            ipcRenderer.send('request-initial-library');
        },
        onForceReloadPlaylist: async (playlistName) => {
            if (state.currentDetailView.type === 'playlist' && state.currentDetailView.identifier === playlistName) {
                const updatedDetails = await ipcRenderer.invoke('get-playlist-details', playlistName);
                state.currentlyViewedSongs = updatedDetails.songs;
                showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: updatedDetails });
            }
        },
    });

    ipcRenderer.send('request-app-info');
});