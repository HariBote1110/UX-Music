import { initUI, addSongsToLibrary, renderCurrentView, updateAudioDevices, updatePlayCountDisplay } from './js/ui-manager.js';
import { initNavigation, showPlaylist, showView } from './js/navigation.js';
import { initIPC } from './js/ipc.js';
import { initModal, showModal } from './js/modal.js';
import { initPlayer, togglePlayPause, applyMasterVolume, seekToStart, setVisualizerFpsLimit } from './js/player.js';
import { state, elements, initElements, PLAYBACK_MODES } from './js/state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './js/playback-manager.js';
import { showNotification, hideNotification } from './js/ui/notification.js';
import { initDebugCommands } from './js/debug-commands.js';
import { updateTextOverflowForSelector } from './js/ui/utils.js';
import { initLazyLoader, observeNewImages } from './js/lazy-loader.js';
import { updateNowPlayingView } from './js/ui/now-playing.js';
import { initNormalizeView } from './js/normalize-view.js';
const { ipcRenderer } = require('electron');
const path = require('path');

performance.mark('renderer-script-start');

const startTime = performance.now();
const logPerf = (message) => {
    console.log(`[PERF][Renderer] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};
logPerf("Script execution started.");

window.artworkLoadTimes = [];

window.observeNewArtworks = (container) => {
    observeNewImages(container || document);
};

window.addEventListener('DOMContentLoaded', () => {
    performance.mark('dom-content-loaded');
    logPerf("'DOMContentLoaded' event fired. Initializing modules...");

    initElements();
    initLazyLoader(elements.mainContent);

    // --- アイドル状態検出 ---
    let inactivityTimer;
    const INACTIVITY_TIMEOUT_MS = 1 * 60 * 1000;

    function resetInactivityTimer() {
        clearTimeout(inactivityTimer);
        if (document.body.classList.contains('app-inactive')) {
            console.log('[Performance] App is now ACTIVE.');
        }
        document.body.classList.remove('app-inactive');

        inactivityTimer = setTimeout(() => {
            document.body.classList.add('app-inactive');
            console.log(`[Performance] App entered INACTIVE mode after ${INACTIVITY_TIMEOUT_MS / 1000 / 60} minutes of inactivity.`);
        }, INACTIVITY_TIMEOUT_MS);
    }

    ['mousemove', 'mousedown', 'keydown', 'touchstart', 'scroll'].forEach(event => {
        document.addEventListener(event, resetInactivityTimer, true);
    });
    resetInactivityTimer();
    
    ipcRenderer.on('log-message', (event, { level, args }) => {
        const style = 'color: cyan; font-weight: bold;';
        console[level](`%c[Main]%c`, style, '', ...args);
    });
    
    function initResizer() {
        const resizer = document.getElementById('resizer');
        const rightSidebar = document.querySelector('.right-sidebar');
        if (!resizer || !rightSidebar) return;
        let startX, startWidth;
        const doDrag = (e) => {
            const newWidth = startWidth - (e.clientX - startX);
            const minWidth = 240;
            const maxWidth = 600;
            if (newWidth > minWidth && newWidth < maxWidth) {
                rightSidebar.style.width = newWidth + 'px';
            }
        };
        const stopDrag = () => {
            document.documentElement.removeEventListener('mousemove', doDrag, false);
            document.documentElement.removeEventListener('mouseup', stopDrag, false);
        };
        resizer.addEventListener('mousedown', (e) => {
            e.preventDefault();
            startX = e.clientX;
            startWidth = parseInt(document.defaultView.getComputedStyle(rightSidebar).width, 10);
            document.documentElement.addEventListener('mousemove', doDrag, false);
            document.documentElement.addEventListener('mouseup', stopDrag, false);
        });
    }

    logPerf("Initializing UI...");
    initUI();
    logPerf("Initializing Player...");
    initPlayer(document.getElementById('main-player'), {
        onSongEnded: playNextSong,
        onNextSong: playNextSong,
        onPrevSong: playPrevSong
    });
    logPerf("Initializing Navigation...");
    initNavigation();
    logPerf("Initializing Modal...");
    initModal();
    logPerf("Initializing Debug Commands...");
    initDebugCommands();
    logPerf("Initializing Normalize View...");
    initNormalizeView();
    logPerf("Initializing IPC...");
    initIPC(ipcRenderer, {
        onLibraryLoaded: async (data) => {
            logPerf("Received 'load-library' event from main process.");
            performance.mark('library-loaded');
            if (!state.artworksDir) {
                state.artworksDir = await ipcRenderer.invoke('get-artworks-dir');
            }
            addSongsToLibrary({ songs: data.songs || [], albums: data.albums || {} });
            showView('track-view');
        },
        onSettingsLoaded: (settings) => {
            updateAudioDevices(settings.audioOutputId);
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

            if (settings.enableYouTube) {
                document.querySelectorAll('[data-feature="youtube"], #add-youtube-btn, #add-youtube-playlist-btn').forEach(el => {
                    el.classList.remove('hidden');
                });
            }
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            for (const songPath in counts) {
                if (counts.hasOwnProperty(songPath)) {
                    updatePlayCountDisplay(songPath, counts[songPath].count);
                }
            }
        },
        onYoutubeLinkProcessed: (song) => {
            showNotification(`「${song.title}」が追加されました。`);
            hideNotification(3000);
            addSongsToLibrary({ songs: [song] });
        },
        onPlaylistsUpdated: (playlists) => {
            state.playlists = playlists;
            if (state.activeViewId === 'playlist-view') {
                renderCurrentView();
            }
        },
        onForceReloadPlaylist: (playlistName) => {
            showPlaylist(playlistName);
        },
        onForceReloadLibrary: () => {
             ipcRenderer.send('request-initial-library');
        },
        onShowLoading: (text) => {
            showNotification(text || '処理中...');
        },
        onHideLoading: () => {
            hideNotification(500);
        },
        onShowError: (message) => {
            alert(message);
        },
        onScanProgress: (progress) => {
            const percentage = progress.total > 0 ? Math.round((progress.current / progress.total) * 100) : 0;
            showNotification(`ライブラリをインポート中... (${percentage}%)`);
        },
        onScanComplete: (songs) => {
            addSongsToLibrary({ songs });
            showNotification(`${songs.length}曲のインポートが完了しました。`);
            hideNotification(3000);
        },
        onPlaylistImportProgress: (progress) => {
            const text = `${progress.total}曲中 ${progress.current}曲目: ${progress.title}`;
            showNotification(text);
        },
        onPlaylistImportFinished: () => {
            showNotification('プレイリストのインポートが完了しました。');
            hideNotification(3000);
        }
    });
    logPerf("IPC initialized.");
    
    initResizer();

    if (navigator.mediaDevices && typeof navigator.mediaDevices.ondevicechange !== 'undefined') {
        navigator.mediaDevices.addEventListener('devicechange', () => updateAudioDevices());
    }
    
    ipcRenderer.on('navigate-back', () => {
        if (state.currentDetailView.type) {
            showView(state.activeListView);
        }
    });

    let swipeAccumulator = 0;
    let swipeTimeout;
    window.addEventListener('wheel', (e) => {
        if (Math.abs(e.deltaX) > Math.abs(e.deltaY) * 2) { 
            swipeAccumulator += e.deltaX;
            clearTimeout(swipeTimeout);
            swipeTimeout = setTimeout(() => {
                swipeAccumulator = 0;
            }, 200);

            if (swipeAccumulator > 50) {
                if (state.currentDetailView.type) {
                    showView(state.activeListView);
                }
                swipeAccumulator = 0;
            }
        }
    }, { passive: true });

    elements.nextBtn.addEventListener('click', playNextSong);
    elements.prevBtn.addEventListener('click', playPrevSong);
    elements.shuffleBtn.addEventListener('click', toggleShuffle);
    elements.loopBtn.addEventListener('click', toggleLoopMode);

    const libraryActionsBtn = document.getElementById('library-actions-btn');
    const libraryActionsPopup = document.getElementById('library-actions-popup');
    
    libraryActionsBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        libraryActionsPopup.classList.toggle('hidden');
    });

    document.getElementById('add-network-folder-btn').addEventListener('click', () => {
        libraryActionsPopup.classList.add('hidden');
        showModal({
            title: 'ネットワークフォルダのパス',
            placeholder: '\\\\ServerName\\ShareName',
            onOk: (path) => {
                ipcRenderer.send('start-scan-paths', [path]);
            }
        });
    });

    document.getElementById('add-youtube-btn').addEventListener('click', () => {
        libraryActionsPopup.classList.add('hidden');
        showModal({
            title: 'YouTubeのリンク',
            placeholder: 'https://www.youtube.com/watch?v=...',
            onOk: (url) => ipcRenderer.send('add-youtube-link', url)
        });
    });
    
    document.getElementById('add-youtube-playlist-btn').addEventListener('click', () => {
        libraryActionsPopup.classList.add('hidden');
        showModal({
            title: 'YouTubeプレイリストのリンク',
            placeholder: 'https://www.youtube.com/playlist?list=...',
            onOk: (url) => ipcRenderer.send('import-youtube-playlist', url)
        });
    });

    document.getElementById('set-library-btn').addEventListener('click', () => {
        libraryActionsPopup.classList.add('hidden');
        ipcRenderer.send('set-library-path');
    });
    
    elements.dropZone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); elements.dropZone.classList.add('drag-over'); });
    elements.dropZone.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); elements.dropZone.classList.remove('drag-over'); });
    elements.dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        e.stopPropagation();
        elements.dropZone.classList.remove('drag-over');
        const allPaths = Array.from(e.dataTransfer.files).map(f => f.path);
        if (allPaths.length === 0) return;
        const lyricsExtensions = ['.lrc', '.txt'];
        const lyricsPaths = allPaths.filter(p => lyricsExtensions.includes(path.extname(p).toLowerCase()));
        const musicPaths = allPaths.filter(p => !lyricsExtensions.includes(path.extname(p).toLowerCase()));
        if (musicPaths.length > 0) {
            showNotification('インポート準備中...');
            ipcRenderer.send('start-scan-paths', musicPaths);
        }
        if (lyricsPaths.length > 0) {
            ipcRenderer.send('handle-lyrics-drop', lyricsPaths);
        }
    });

    const youtubeQualityGroup = document.getElementById('youtube-quality-group');

    function updateQualityGroupState() {
        const youtubeModeRadios = document.querySelectorAll('input[name="youtube-mode"]');
        if (!youtubeModeRadios.length) return;
        const selectedMode = document.querySelector('input[name="youtube-mode"]:checked').value;
        if (selectedMode === 'stream') {
            youtubeQualityGroup.classList.add('disabled');
            document.querySelectorAll('input[name="youtube-quality"]').forEach(radio => radio.disabled = true);
        } else {
            youtubeQualityGroup.classList.remove('disabled');
            document.querySelectorAll('input[name="youtube-quality"]').forEach(radio => radio.disabled = false);
        }
    }

    elements.openSettingsBtn.addEventListener('click', async () => {
        const settings = await ipcRenderer.invoke('get-settings');
        
        const currentYoutubeMode = settings.youtubePlaybackMode || 'download';
        const youtubeModeRadio = document.querySelector(`input[name="youtube-mode"][value="${currentYoutubeMode}"]`);
        if (youtubeModeRadio) youtubeModeRadio.checked = true;
        
        const currentQuality = settings.youtubeDownloadQuality || 'full';
        const qualityRadio = document.querySelector(`input[name="youtube-quality"][value="${currentQuality}"]`);
        if (qualityRadio) qualityRadio.checked = true;
        
        updateQualityGroupState();
        
        const currentImportMode = settings.importMode || 'balanced';
        const importModeRadio = document.querySelector(`input[name="import-mode"][value="${currentImportMode}"]`);
        if (importModeRadio) importModeRadio.checked = true;
        
        const currentVisualizerMode = settings.visualizerMode || 'active';
        const visualizerModeRadio = document.querySelector(`input[name="visualizer-mode"][value="${currentVisualizerMode}"]`);
        if(visualizerModeRadio) visualizerModeRadio.checked = true;

        const easterEggsEnabled = settings.enableEasterEggs !== false;
        const easterEggsCheckbox = document.querySelector('input[name="enable-easter-eggs"]');
        if(easterEggsCheckbox) easterEggsCheckbox.checked = easterEggsEnabled;
        
        elements.settingsModalOverlay.classList.remove('hidden');
    });
    
    document.querySelectorAll('input[name="youtube-mode"]').forEach(radio => {
        radio.addEventListener('change', updateQualityGroupState);
    });

    elements.settingsOkBtn.addEventListener('click', () => {
        const selectedYoutubeMode = document.querySelector('input[name="youtube-mode"]:checked').value;
        const selectedQuality = document.querySelector('input[name="youtube-quality"]:checked').value;
        const selectedImportMode = document.querySelector('input[name="import-mode"]:checked').value;
        const selectedVisualizerMode = document.querySelector('input[name="visualizer-mode"]:checked').value;
        const enableEasterEggs = document.querySelector('input[name="enable-easter-eggs"]').checked;

        ipcRenderer.send('save-settings', {
            youtubePlaybackMode: selectedYoutubeMode,
            youtubeDownloadQuality: selectedQuality,
            importMode: selectedImportMode,
            visualizerMode: selectedVisualizerMode,
            enableEasterEggs: enableEasterEggs,
        });
        
        state.visualizerMode = selectedVisualizerMode;
        
        elements.settingsModalOverlay.classList.add('hidden');
    });
    
    let userPreferredVisualizerMode = 'active';

    elements.lightFlightModeBtn.addEventListener('click', () => {
        state.isLightFlightMode = !state.isLightFlightMode;
        document.body.classList.toggle('light-flight-mode', state.isLightFlightMode);
        elements.lightFlightModeBtn.classList.toggle('active', state.isLightFlightMode);

        if (state.isLightFlightMode) {
            userPreferredVisualizerMode = state.visualizerMode;
            state.visualizerMode = 'static';
            state.userPreferredVisualizerFps = state.visualizerFpsLimit;
            setVisualizerFpsLimit(30);
            showNotification('✈️ Light FlightモードがONになりました。');
        } else {
            state.visualizerMode = userPreferredVisualizerMode;
            setVisualizerFpsLimit(state.userPreferredVisualizerFps);
            showNotification('✈️ Light FlightモードがOFFになりました。');
        }
        hideNotification(2000);
        
        renderCurrentView();
        updateNowPlayingView(state.playbackQueue[state.currentSongIndex]);
    });
    
    elements.deviceSelectButton.addEventListener('click', (e) => {
        e.stopPropagation();
        updateAudioDevices();
        elements.devicePopup.classList.toggle('active');
    });

    window.addEventListener('click', (e) => {
        if (elements.devicePopup && elements.devicePopup.classList.contains('active')) {
            elements.devicePopup.classList.remove('active');
        }
        if (libraryActionsPopup && !libraryActionsPopup.classList.contains('hidden') && !libraryActionsPopup.contains(e.target) && e.target !== libraryActionsBtn) {
            libraryActionsPopup.classList.add('hidden');
        }
    });
    
    let resizeTimer;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            updateTextOverflowForSelector('.marquee-wrapper');
        }, 250);
    });

    window.addEventListener('keydown', async (e) => {
        if (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA') return;
        
        const isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
        const modifierKey = isMac ? e.metaKey : e.ctrlKey;

        if (e.code === 'Space' && !modifierKey) {
            e.preventDefault();
            togglePlayPause();
        } else if (e.code === 'Digit0' && !modifierKey) {
            e.preventDefault();
            seekToStart();
        } else if (e.code === 'Escape') {
            if (state.selectedSongIds.size > 0) {
                e.preventDefault();
                state.selectedSongIds.clear();
                document.querySelectorAll('.song-item.selected').forEach(item => {
                    item.classList.remove('selected');
                });
            }
        } else if (modifierKey && e.key.toLowerCase() === 'a') {
            e.preventDefault();
            if (state.currentlyViewedSongs && state.currentlyViewedSongs.length > 0) {
                const allIds = new Set(state.currentlyViewedSongs.map(s => s.id));
                const allSelected = state.selectedSongIds.size === allIds.size;

                if (allSelected) {
                    state.selectedSongIds.clear();
                } else {
                    state.selectedSongIds = new Set(allIds);
                }
                
                document.querySelectorAll('.song-item').forEach(item => {
                    const songId = item.dataset.songId;
                    if (state.selectedSongIds.has(songId)) {
                        item.classList.add('selected');
                    } else {
                        item.classList.remove('selected');
                    }
                });
            }
        } else if (modifierKey && e.key.toLowerCase() === 'c') {
            e.preventDefault();
            if (state.selectedSongIds.size > 0) {
                state.copiedSongIds = [...state.selectedSongIds];
                showNotification(`${state.copiedSongIds.length}曲をコピーしました。`);
                hideNotification(2000);
            }
        } else if (modifierKey && e.key.toLowerCase() === 'v') {
            e.preventDefault();
            if (state.copiedSongIds.length > 0 && (state.currentDetailView.type === 'playlist' || state.currentDetailView.type === 'situation')) {
                const playlistName = state.currentDetailView.identifier;
                
                const result = await ipcRenderer.invoke('add-songs-to-playlist', {
                    playlistName: playlistName,
                    songIds: state.copiedSongIds
                });

                if (result.success) {
                    showNotification(`${result.addedCount}曲を「${playlistName}」に追加しました。`);
                    hideNotification(3000);
                    showPlaylist(playlistName);
                } else {
                    showNotification(`追加に失敗しました: ${result.message}`, 3000);
                }
            }
        }
    });

    document.getElementById('manage-devices-btn').addEventListener('click', async () => {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const audioDevices = devices.filter(d => d.kind === 'audiooutput');
        const settings = await ipcRenderer.invoke('get-settings');
        const hiddenDevices = settings.hiddenDeviceIds || [];
        
        const listEl = document.getElementById('devices-list');
        listEl.innerHTML = '';

        audioDevices.forEach(device => {
            const isHidden = hiddenDevices.includes(device.deviceId);
            const label = document.createElement('label');
            label.innerHTML = `
                <input type="checkbox" data-device-id="${device.deviceId}" ${!isHidden ? 'checked' : ''}>
                <span>${device.label || `スピーカー ${audioDevices.indexOf(device) + 1}`}</span>
            `;
            listEl.appendChild(label);
        });

        document.getElementById('devices-modal-overlay').classList.remove('hidden');
    });

    document.getElementById('devices-ok-btn').addEventListener('click', () => {
        const hiddenDeviceIds = [];
        document.querySelectorAll('#devices-list input[type="checkbox"]').forEach(checkbox => {
            if (!checkbox.checked) {
                hiddenDeviceIds.push(checkbox.dataset.deviceId);
            }
        });
        ipcRenderer.send('save-settings', { hiddenDeviceIds });
        document.getElementById('devices-modal-overlay').classList.add('hidden');
        updateAudioDevices();
    });

    ipcRenderer.on('app-info-response', (event, info) => {
        console.log(
            `%c[UX Music] Version: ${info.version} | OS: ${info.platform} ${info.arch} (Release: ${info.release})`,
            'color: #1DB954; font-weight: bold; font-size: 1.1em;'
        );
        const versionSpan = document.getElementById('app-version');
        if (versionSpan) {
            versionSpan.textContent = `v${info.version}`;
        }
    });
    ipcRenderer.send('request-app-info');
    
    logPerf("All initializations and event listeners set up.");
});

window.addEventListener('load', () => {
    performance.mark('window-load');
    logPerf("'window.onload' event fired. All resources are fully loaded.");
});

ipcRenderer.on('measure-performance', () => {
    console.log("--- RENDERER PERFORMANCE ANALYSIS ---");
    const measure = (name, start, end) => {
        try {
            const measurement = performance.measure(name, start, end);
            console.log(`[PERF] ${name}: ${measurement.duration.toFixed(2)}ms`);
        } catch (e) {
            console.warn(`[PERF] Could not measure '${name}'. Mark '${start}' or '${end}' not found.`);
        }
    };
    measure('Script Start to DOMContentLoaded', 'renderer-script-start', 'dom-content-loaded');
    measure('DOMContentLoaded to Initial Render End', 'dom-content-loaded', 'initial-render-end');
    if (window.artworkLoadTimes && window.artworkLoadTimes.length > 0) {
        const firstLoad = Math.min(...window.artworkLoadTimes);
        const lastLoad = Math.max(...window.artworkLoadTimes);
        const initialRenderEndMark = performance.getEntriesByName('initial-render-end')[0];
        if (initialRenderEndMark) {
            const initialRenderEndTime = initialRenderEndMark.startTime;
            console.log(`[PERF] Time to First Artwork Loaded: ${(firstLoad - initialRenderEndTime).toFixed(2)}ms`);
            console.log(`[PERF] Time to Last Artwork Loaded: ${(lastLoad - initialRenderEndTime).toFixed(2)}ms`);
            console.log(`[PERF] Total Artwork Loading Span: ${(lastLoad - firstLoad).toFixed(2)}ms`);
        }
    }
    measure('Initial Render End to Window Load', 'initial-render-end', 'window-load');
    measure('Full Renderer Process Time', 'renderer-script-start', 'window-load');
    console.log("-------------------------------------");
});