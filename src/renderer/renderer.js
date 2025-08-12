// uxmusic/src/renderer/renderer.js

import { initUI, addSongsToLibrary, renderCurrentView, updateAudioDevices, updatePlayCountDisplay } from './js/ui-manager.js';
import { initNavigation, showPlaylist, showView } from './js/navigation.js';
import { initIPC } from './js/ipc.js';
import { initModal, showModal } from './js/modal.js';
import { initPlayer, togglePlayPause, applyMasterVolume, seekToStart } from './js/player.js';
import { state, elements, initElements } from './js/state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './js/playback-manager.js';
import { showNotification, hideNotification } from './js/ui/notification.js';
import { initDebugCommands } from './js/debug-commands.js';
import { updateTextOverflowForSelector } from './js/ui/utils.js';
import { initLazyLoader, observeNewImages } from './js/lazy-loader.js';
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

    const MARQUEE_SELECTOR = '.marquee-wrapper';
    
    ipcRenderer.on('log-message', (event, { level, args }) => {
        const style = 'color: cyan; font-weight: bold;';
        console[level](`%c[Main]%c`, style, '', ...args);
    });

    function initResizer() {
        const resizer = document.getElementById('resizer');
        const rightSidebar = document.querySelector('.right-sidebar');
        if (!resizer || !rightSidebar) return;
        let startX, startWidth;
        resizer.addEventListener('mousedown', function (e) {
            e.preventDefault();
            startX = e.clientX;
            startWidth = parseInt(document.defaultView.getComputedStyle(rightSidebar).width, 10);
            document.documentElement.addEventListener('mousemove', doDrag, false);
            document.documentElement.addEventListener('mouseup', stopDrag, false);
        });
        function doDrag(e) {
            const newWidth = startWidth - (e.clientX - startX);
            const minWidth = 240;
            const maxWidth = 600;
            if (newWidth > minWidth && newWidth < maxWidth) {
                rightSidebar.style.width = newWidth + 'px';
            }
        }
        function stopDrag() {
            document.documentElement.removeEventListener('mousemove', doDrag, false);
            document.documentElement.removeEventListener('mouseup', stopDrag, false);
        }
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
    
    if (navigator.mediaDevices && typeof navigator.mediaDevices.ondevicechange !== 'undefined') {
        navigator.mediaDevices.addEventListener('devicechange', () => updateAudioDevices());
    }
    
    ipcRenderer.on('navigate-back', () => {
        if (state.currentDetailView.type) {
            showView(state.activeListView);
        }
    });

    elements.nextBtn.addEventListener('click', playNextSong);
    elements.prevBtn.addEventListener('click', playPrevSong);
    elements.shuffleBtn.addEventListener('click', toggleShuffle);
    elements.loopBtn.addEventListener('click', toggleLoopMode);

    elements.addNetworkFolderBtn.addEventListener('click', () => {
        showModal({
            title: 'ネットワークフォルダのパス',
            placeholder: '\\\\ServerName\\ShareName',
            onOk: (path) => {
                ipcRenderer.send('start-scan-paths', [path]);
            }
        });
    });

    elements.addYoutubeBtn.addEventListener('click', () => {
        showModal({
            title: 'YouTubeのリンク',
            placeholder: 'https://www.youtube.com/watch?v=...',
            onOk: (url) => ipcRenderer.send('add-youtube-link', url)
        });
    });
    elements.addYoutubePlaylistBtn.addEventListener('click', () => {
        showModal({
            title: 'YouTubeプレイリストのリンク',
            placeholder: 'https://www.youtube.com/playlist?list=...',
            onOk: (url) => ipcRenderer.send('import-youtube-playlist', url)
        });
    });

    elements.setLibraryBtn.addEventListener('click', () => ipcRenderer.send('set-library-path'));
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

    // ▼▼▼ ここからが修正箇所です ▼▼▼
    const youtubeQualityGroup = document.getElementById('youtube-quality-group');

    function updateQualityGroupState() {
        const selectedMode = document.querySelector('input[name="youtube-mode"]:checked').value;
        if (selectedMode === 'stream') {
            youtubeQualityGroup.classList.add('disabled');
            elements.youtubeQualityRadios.forEach(radio => radio.disabled = true);
        } else {
            youtubeQualityGroup.classList.remove('disabled');
            elements.youtubeQualityRadios.forEach(radio => radio.disabled = false);
        }
    }

    elements.openSettingsBtn.addEventListener('click', async () => {
        const settings = await ipcRenderer.invoke('get-settings');
        const currentMode = settings.youtubePlaybackMode || 'download';
        const currentQuality = settings.youtubeDownloadQuality || 'full';
        document.querySelector(`input[name="youtube-mode"][value="${currentMode}"]`).checked = true;
        document.querySelector(`input[name="youtube-quality"][value="${currentQuality}"]`).checked = true;
        updateQualityGroupState(); // 初期状態を設定
        elements.settingsModalOverlay.classList.remove('hidden');
    });

    elements.youtubeModeRadios.forEach(radio => {
        radio.addEventListener('change', updateQualityGroupState);
    });
    // ▲▲▲ ここまでが修正箇所です ▲▲▲

    elements.settingsOkBtn.addEventListener('click', () => elements.settingsModalOverlay.classList.add('hidden'));

    initResizer();
    
    elements.deviceSelectButton.addEventListener('click', (e) => {
        e.stopPropagation();
        updateAudioDevices();
        elements.devicePopup.classList.toggle('active');
    });

    window.addEventListener('click', () => {
        if (elements.devicePopup.classList.contains('active')) {
            elements.devicePopup.classList.remove('active');
        }
    });
    
    let resizeTimer;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            updateTextOverflowForSelector('.marquee-wrapper');
        }, 250);
    });

    window.addEventListener('keydown', (e) => {
        if (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA') return;
        
        if (e.code === 'Space') {
            e.preventDefault();
            togglePlayPause();
        } else if (e.code === 'Digit0') {
            e.preventDefault();
            seekToStart();
        }
    });

    ipcRenderer.on('app-info-response', (event, info) => {
        console.log(
            `%c[UX Music] Version: ${info.version} | OS: ${info.platform} ${info.arch} (Release: ${info.release})`,
            'color: #1DB954; font-weight: bold; font-size: 1.1em;'
        );
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