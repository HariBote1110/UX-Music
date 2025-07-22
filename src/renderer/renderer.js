import { initUI, renderCurrentView, showPlaylist, addSongsToLibrary, updateAudioDevices } from './js/ui-manager.js';
import { initIPC } from './js/ipc.js';
import { initNavigation } from './js/navigation.js';
import { initModal, showModal } from './js/modal.js';
import { initPlaylists } from './js/playlist.js';
import { initPlayer, togglePlayPause } from './js/player.js';
import { state, elements } from './js/state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './js/playback-manager.js';

const { ipcRenderer } = require('electron');

window.addEventListener('DOMContentLoaded', () => {
    
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

    // --- 各モジュールの初期化 ---
    initUI();
    initPlayer(document.getElementById('main-player'), {
        onSongEnded: playNextSong,
        onNextSong: playNextSong,
        onPrevSong: playPrevSong
    });
    initNavigation(renderCurrentView);
    initModal();
    initPlaylists();
    
    initIPC(ipcRenderer, {
        onLibraryLoaded: (songs) => {
            state.library = songs || [];
            addSongsToLibrary([]);
            renderCurrentView();
        },
        onSettingsLoaded: (settings) => {
            updateAudioDevices(settings.audioOutputId);
            if (typeof settings.volume === 'number') {
                document.getElementById('main-player').volume = settings.volume;
                elements.volumeSlider.value = settings.volume;
            }
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            renderCurrentView();
        },
        onYoutubeLinkProcessed: (song) => addSongsToLibrary([song]),
        onPlaylistsUpdated: (playlists) => {
            state.playlists = playlists;
            renderCurrentView();
        },
        onForceReloadPlaylist: (playlistName) => {
            showPlaylist(playlistName);
        },
        onForceReloadLibrary: () => {
             ipcRenderer.send('request-initial-library');
        },
        onShowLoading: (text) => {
            elements.loadingOverlay.querySelector('.loading-text').textContent = text || '処理中...';
            elements.loadingOverlay.classList.remove('hidden');
        },
        onHideLoading: () => {
            elements.loadingOverlay.classList.add('hidden');
        },
        onShowError: (message) => {
            alert(message);
        },
        onPlaylistImportProgress: (progress) => {
            const text = `${progress.total}曲中 ${progress.current}曲目: ${progress.title}`;
            elements.loadingOverlay.querySelector('.loading-text').textContent = text;
            if (elements.loadingOverlay.classList.contains('hidden')) {
                elements.loadingOverlay.classList.remove('hidden');
            }
        },
        onPlaylistImportFinished: () => {
            elements.loadingOverlay.classList.add('hidden');
        }
    });
    
    // --- グローバルイベントリスナーの設定 ---
    if (navigator.mediaDevices && typeof navigator.mediaDevices.ondevicechange !== 'undefined') {
        navigator.mediaDevices.addEventListener('devicechange', () => updateAudioDevices());
    }

    elements.nextBtn.addEventListener('click', playNextSong);
    elements.prevBtn.addEventListener('click', playPrevSong);
    elements.shuffleBtn.addEventListener('click', toggleShuffle);
    elements.loopBtn.addEventListener('click', toggleLoopMode);

    elements.addNetworkFolderBtn.addEventListener('click', () => {
        showModal({
            title: 'ネットワークフォルダのパス',
            placeholder: '\\\\ServerName\\ShareName',
            onOk: async (path) => {
                elements.loadingOverlay.classList.remove('hidden');
                try {
                    const songs = await ipcRenderer.invoke('scan-paths', [path]);
                    addSongsToLibrary(songs);
                } finally {
                    elements.loadingOverlay.classList.add('hidden');
                }
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
    elements.dropZone.addEventListener('drop', async (e) => {
        e.preventDefault();
        e.stopPropagation();
        elements.dropZone.classList.remove('drag-over');
        const paths = Array.from(e.dataTransfer.files).map(f => f.path);
        elements.loadingOverlay.classList.remove('hidden');
        try {
            const songs = await ipcRenderer.invoke('scan-paths', paths);
            addSongsToLibrary(songs);
        } finally {
            elements.loadingOverlay.classList.add('hidden');
        }
    });

    elements.openSettingsBtn.addEventListener('click', async () => {
        const settings = await ipcRenderer.invoke('get-settings');
        const currentMode = settings.youtubePlaybackMode || 'download';
        const currentQuality = settings.youtubeDownloadQuality || 'full';
        document.querySelector(`input[name="youtube-mode"][value="${currentMode}"]`).checked = true;
        document.querySelector(`input[name="youtube-quality"][value="${currentQuality}"]`).checked = true;
        elements.settingsModalOverlay.classList.remove('hidden');
    });
    elements.settingsOkBtn.addEventListener('click', () => elements.settingsModalOverlay.classList.add('hidden'));
    elements.youtubeModeRadios.forEach(radio => {
        radio.addEventListener('change', (event) => ipcRenderer.send('save-settings', { youtubePlaybackMode: event.target.value }));
    });
    elements.youtubeQualityRadios.forEach(radio => {
        radio.addEventListener('change', (event) => ipcRenderer.send('save-settings', { youtubeDownloadQuality: event.target.value }));
    });

    initResizer();
    
    window.addEventListener('keydown', (e) => {
        if (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA') return;
        if (e.code === 'Space') {
            e.preventDefault();
            togglePlayPause();
        }
    });
});