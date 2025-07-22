import { initUI, renderCurrentView, addSongsToLibrary, updateAudioDevices } from './js/ui-manager.js';
import { showPlaylist } from './js/ui/navigation.js';
import { initIPC } from './js/ipc.js';
import { initNavigation } from './js/navigation.js';
import { initModal, showModal } from './js/modal.js';
import { initPlaylists } from './js/playlist.js';
import { initPlayer, togglePlayPause, applyMasterVolume } from './js/player.js';
import { state, elements } from './js/state.js';
window.state = state;
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './js/playback-manager.js';
import { showNotification, hideNotification } from './js/ui/notification.js';

const { ipcRenderer } = require('electron');
const path = require('path'); // ★★★ この行を追加 ★★★

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
                elements.volumeSlider.value = settings.volume;
                applyMasterVolume();
            }
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            renderCurrentView();
        },
        onYoutubeLinkProcessed: (song) => {
            showNotification(`「${song.title}」が追加されました。`);
            hideNotification(3000);
            addSongsToLibrary([song]);
        },
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
            showNotification(text || '処理中...');
        },
        onHideLoading: () => {
            // hideNotification は完了メッセージ表示後などに個別で呼ぶので、ここでは何もしない
        },
        onShowError: (message) => {
            alert(message);
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
                showNotification('ライブラリをスキャン中...');
                try {
                    const songs = await ipcRenderer.invoke('scan-paths', [path]);
                    addSongsToLibrary(songs);
                    showNotification(`${songs.length}曲が追加されました。`);
                } finally {
                    hideNotification(3000);
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
        
        const files = Array.from(e.dataTransfer.files);
        const musicExtensions = ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.mp4'];
        const lyricsExtensions = ['.lrc', '.txt'];

        const musicFiles = files.filter(f => musicExtensions.includes(path.extname(f.name).toLowerCase()));
        const lyricsFiles = files.filter(f => lyricsExtensions.includes(path.extname(f.name).toLowerCase()));

        // 音楽ファイルの処理
        if (musicFiles.length > 0) {
            const musicPaths = musicFiles.map(f => f.path);
            showNotification('ライブラリをスキャン中...');
            try {
                const songs = await ipcRenderer.invoke('scan-paths', musicPaths);
                addSongsToLibrary(songs);
                showNotification(`${songs.length}曲が追加されました。`);
            } finally {
                hideNotification(3000);
            }
        }

        // 歌詞ファイルの処理
        if (lyricsFiles.length > 0) {
            const lyricsPaths = lyricsFiles.map(f => f.path);
            ipcRenderer.send('handle-lyrics-drop', lyricsPaths);
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