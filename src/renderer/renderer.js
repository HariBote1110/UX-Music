import { state, elements, initElements } from './js/state.js';
import { initEventListeners } from './js/init-listeners.js';
import { initUI } from './js/ui.js';
import { initSettings } from './js/init-settings.js';
import { initNavigation, showView } from './js/navigation.js';
import { initPlayer, play } from './js/player.js';
import { updateAudioDevices, updatePlayCountDisplay, addSongsToLibrary } from './js/ui-manager.js';
import { loadAllComponents } from './js/component-loader.js';
import { initIPC } from './js/ipc.js';
import { initModal } from './js/modal.js';
import { initDebugCommands } from './js/debug-commands.js';
import { initNormalizeView } from './js/normalize-view.js';
import { initEqualizer, renderEqualizer, applyCurrentSettings } from './js/ui/equalizer.js';
import { initQuiz } from './js/quiz.js';
import { playNextSong, playPrevSong } from './js/playback-manager.js';
import { initLazyLoader, observeNewImages } from './js/lazy-loader.js';

const { ipcRenderer } = require('electron');

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
        await initPlayer(mainPlayer, {
            onSongEnded: () => {
                const nextIndex = getNextSongIndex();
                if (nextIndex !== -1) play(state.playbackQueue[nextIndex]);
            },
            onNextSong: () => {
                 const nextIndex = getNextSongIndex();
                 if (nextIndex !== -1) play(state.playbackQueue[nextIndex]);
            },
            onPrevSong: () => {
                 const prevIndex = getPrevSongIndex();
                 if (prevIndex !== -1) play(state.playbackQueue[prevIndex]);
            }
        });
    }

    initIPC(ipcRenderer, {
        onAppInfoResponse: (info) => {
            const appVersionEl = document.getElementById('app-version');
            if (appVersionEl) appVersionEl.textContent = `v${info.version}`;
        },
        onLibraryLoaded: async (data) => {
            if (!state.artworksDir) state.artworksDir = await ipcRenderer.invoke('get-artworks-dir');
            addSongsToLibrary({ songs: data.songs || [], albums: data.albums || {} });
            
            const initialView = state.activeViewId || 'track-view';
            showView(initialView);
            
            ipcRenderer.send('request-playlists-with-artwork');
            const loadingOverlay = document.getElementById('loading-overlay');
            if(loadingOverlay) loadingOverlay.classList.add('hidden');
        },
        onSettingsLoaded: (settings) => {
            if (typeof settings.volume === 'number') {
                if(elements.volumeSlider) elements.volumeSlider.value = settings.volume;
                if(elements.volumeRange) elements.volumeRange.value = settings.volume;
            }
            state.visualizerMode = settings.visualizerMode || 'active';
            if (typeof settings.isShuffled === 'boolean') {
                state.isShuffle = settings.isShuffled;
                if(elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffle);
            }
            if (typeof settings.groupAlbumArt === 'boolean') {
                state.groupAlbumArt = settings.groupAlbumArt;
                // 設定画面からの通知で再描画が必要な場合
                if (state.activeViewId === 'track-view') showView('track-view');
            }
             if (settings.enableYouTube) {
                document.querySelectorAll('[data-feature="youtube"]').forEach(el => el.classList.remove('hidden'));
            }
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            Object.keys(counts).forEach(songPath => updatePlayCountDisplay(songPath, counts[songPath].count));
        },
        onPlaylistsUpdated: (playlists) => {
            state.playlists = playlists;
            if (state.activeViewId === 'playlist-view') showView('playlist-view');
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
    
    try {
        const settings = await ipcRenderer.invoke('get-settings');
        
        // ▼▼▼ 修正: 起動時に設定を即時反映 ▼▼▼
        if (settings) {
            if (typeof settings.groupAlbumArt === 'boolean') {
                state.groupAlbumArt = settings.groupAlbumArt;
            }
            if (typeof settings.isShuffled === 'boolean') {
                state.isShuffle = settings.isShuffled;
                if(elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffle);
            }
            // ... 他の設定も必要に応じて反映
        }
        // ▲▲▲ 修正完了 ▲▲▲

        if (settings.libraryPath) {
            ipcRenderer.send('load-library');
        } else {
            const loadingOverlay = document.getElementById('loading-overlay');
            if(loadingOverlay) loadingOverlay.classList.add('hidden');
        }
    } catch (e) {
        console.error('Failed to load settings or library:', e);
        const loadingOverlay = document.getElementById('loading-overlay');
        if(loadingOverlay) loadingOverlay.classList.add('hidden');
    }
    
    ipcRenderer.send('app-ready');

    try {
        updateAudioDevices();
    } catch(e) {
        console.error('Failed to update audio devices:', e);
    }
}

function getNextSongIndex() {
    if (state.playbackQueue.length === 0) return -1;
    if (state.isShuffle) {
        let nextIndex = Math.floor(Math.random() * state.playbackQueue.length);
        if (state.playbackQueue.length > 1 && nextIndex === state.currentSongIndex) {
            return getNextSongIndex();
        }
        return nextIndex;
    } else {
        if (state.loopMode === 'one') return state.currentSongIndex;
        let nextIndex = state.currentSongIndex + 1;
        if (nextIndex >= state.playbackQueue.length) {
             if (state.loopMode === 'all') return 0;
             else return -1; 
        }
        return nextIndex;
    }
}

function getPrevSongIndex() {
    if (state.playbackQueue.length === 0) return -1;
    if (state.isShuffle) {
         return Math.floor(Math.random() * state.playbackQueue.length);
    } else {
        let prevIndex = state.currentSongIndex - 1;
        if (prevIndex < 0) {
             if (state.loopMode === 'all') return state.playbackQueue.length - 1;
             else return 0;
        }
        return prevIndex;
    }
}

initApp().catch(err => console.error('App initialization failed:', err));