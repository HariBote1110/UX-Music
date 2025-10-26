import { initUI, addSongsToLibrary, updatePlayCountDisplay, renderCurrentView } from './js/ui-manager.js'; // renderCurrentView を追加
import { initNavigation, showView } from './js/navigation.js';
import { initIPC } from './js/ipc.js';
import { initModal } from './js/modal.js';
import { initPlayer, applyMasterVolume } from './js/player.js';
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
                applyMasterVolume();
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
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            Object.keys(counts).forEach(songPath => updatePlayCountDisplay(songPath, counts[songPath].count));
        },
        onYoutubeLinkProcessed: (song) => {
            showNotification(`「${song.title}」が追加されました。`, 3000);
            addSongsToLibrary({ songs: [song] });
        },
        onScanComplete: (songs) => {
            addSongsToLibrary({ songs });
            showNotification(`${songs.length}曲のインポートが完了しました。`, 3000);
        },
        onPlaylistsUpdated: (playlists) => {
            state.playlists = playlists;
            // Only re-render if the playlist view is currently active
            if (state.activeViewId === 'playlist-view') {
                 renderCurrentView(); // Use renderCurrentView for consistency
            }
        },
        onForceReloadPlaylist: (playlistName) => {
            // Check if the currently viewed detail is the playlist that needs reloading
            if (state.currentDetailView.type === 'playlist' && state.currentDetailView.identifier === playlistName) {
                showView('playlist-detail-view', {
                    type: 'playlist',
                    identifier: playlistName,
                    // Re-fetch data if needed, or rely on state updates triggered elsewhere
                    // For simplicity, re-rendering might use existing state if it's updated by 'playlists-updated'
                 });
                 // Potentially need to re-fetch playlist details here if state isn't auto-updated
                 ipcRenderer.invoke('get-playlist-details', playlistName).then(details => {
                     state.currentlyViewedSongs = details.songs; // Update the viewed songs
                     renderCurrentView(); // Re-render with potentially updated song list
                 });
            } else if (state.currentDetailView.type === 'situation' && state.currentDetailView.identifier === playlistName) {
                 // Handle reloading situation playlists if necessary (might need different logic)
                 renderCurrentView();
            }
        },
         onForceReloadLibrary: () => {
             // Reload the entire application state related to library
             state.library = [];
             state.albums.clear();
             state.artists.clear();
             // Potentially clear playlists derived from library?
             ipcRenderer.send('request-initial-library'); // Re-request library data
             showView('track-view'); // Go back to track view
         },
         onShowLoading: (text) => {
             elements.loadingOverlay.querySelector('.loading-text').textContent = text || '読み込み中...';
             elements.loadingOverlay.classList.remove('hidden');
         },
         onHideLoading: () => {
             elements.loadingOverlay.classList.add('hidden');
         },
         onShowError: (message) => {
             showNotification(`エラー: ${message}`, 5000); // Show error as notification
         },
        onPlaylistImportProgress: (progress) => {
            showNotification(`プレイリストインポート中: ${progress.current} / ${progress.total} (${progress.title})`);
        },
        onPlaylistImportFinished: () => {
            hideNotification();
            showNotification('プレイリストのインポートが完了しました。', 3000);
        },
        onScanProgress: (progress) => {
             elements.loadingOverlay.querySelector('.loading-text').textContent = `ライブラリをスキャン中... (${progress.current}/${progress.total})`;
             elements.loadingOverlay.classList.remove('hidden'); // Ensure loading is visible
         },
        // --- ▼▼▼ ここからが修正箇所です ▼▼▼ ---
        onSongsDeleted: (deletedSongIds) => {
            console.log(`[IPC] Received songs-deleted event for IDs:`, deletedSongIds);
            const deletedSet = new Set(deletedSongIds);

            // 1. Remove from main library
            state.library = state.library.filter(song => !deletedSet.has(song.id));

            // 2. Remove from currently viewed songs if necessary
            state.currentlyViewedSongs = state.currentlyViewedSongs.filter(song => !deletedSet.has(song.id));

            // 3. Remove from album map entries
            for (const album of state.albums.values()) {
                album.songs = album.songs.filter(song => !deletedSet.has(song.id));
            }
            // Optionally remove empty albums
            // for (const [key, album] of state.albums.entries()) {
            //     if (album.songs.length === 0) {
            //         state.albums.delete(key);
            //     }
            // }


            // 4. Remove from artist map entries (similar logic)
             for (const artist of state.artists.values()) {
                 artist.songs = artist.songs.filter(song => !deletedSet.has(song.id));
             }
             // Optionally remove empty artists


            // 5. Update playback queue if deleted songs are present
            const currentSong = state.playbackQueue[state.currentSongIndex];
            state.playbackQueue = state.playbackQueue.filter(song => !deletedSet.has(song.id));
            state.originalQueueSource = state.originalQueueSource.filter(song => !deletedSet.has(song.id));

            // Adjust current index if needed
            if (currentSong && deletedSet.has(currentSong.id)) {
                 // If the currently playing song was deleted, stop playback and reset index
                 stopPlayer(); // Assuming you have a stop function in player.js
                 updateNowPlayingView(null);
                 state.currentSongIndex = -1;
            } else if (currentSong) {
                 // If the playing song wasn't deleted, find its new index
                 state.currentSongIndex = state.playbackQueue.findIndex(song => song.id === currentSong.id);
            } else {
                 state.currentSongIndex = -1; // Ensure index is reset if queue becomes empty
            }


            // 6. Re-render the current view
            renderCurrentView();

            showNotification(`${deletedSongIds.length}曲を削除しました。`);
            hideNotification(3000);
        }
        // --- ▲▲▲ ここまでが修正箇所です ▲▲▲ ---
    });

    ipcRenderer.send('request-app-info');
});