import { initUI, renderCurrentView, addSongsToLibrary, updateAudioDevices } from './js/ui-manager.js';
import { initNavigation, showPlaylist, showMainView } from './js/navigation.js';
import { initIPC } from './js/ipc.js';
import { initModal, showModal } from './js/modal.js';
import { initPlaylists } from './js/playlist.js';
import { initPlayer, togglePlayPause, applyMasterVolume, seekToStart } from './js/player.js';
import { state, elements } from './js/state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './js/playback-manager.js';
import { showNotification, hideNotification } from './js/ui/notification.js';
import { initDebugCommands } from './js/debug-commands.js';
import { updateTextOverflowForSelector } from './js/ui/utils.js';

const { ipcRenderer } = require('electron');
const path = require('path');

window.addEventListener('DOMContentLoaded', () => {

    const MARQUEE_SELECTOR = '.marquee-wrapper';
    
    // メインプロセスからのログを受け取ってコンソールに表示
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
    initDebugCommands();
    
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
            addSongsToLibrary(songs);
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
    
    // --- グローバルイベントリスナーの設定 ---
    if (navigator.mediaDevices && typeof navigator.mediaDevices.ondevicechange !== 'undefined') {
        navigator.mediaDevices.addEventListener('devicechange', () => updateAudioDevices());
    }
    
    ipcRenderer.on('navigate-back', () => {
        if (state.currentDetailView.type) {
            showMainView(state.activeListView);
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
    
    // ▼▼▼ ここからが修正箇所です ▼▼▼
    elements.deviceSelectButton.addEventListener('click', (e) => {
        e.stopPropagation();
        // ポップアップを開く前に、必ずデバイスリストを更新する
        updateAudioDevices();
        elements.devicePopup.classList.toggle('active');
    });
    // ▲▲▲ ここまでが修正箇所です ▲▲▲

    // ポップアップの外側をクリックしたら閉じる
    window.addEventListener('click', () => {
        if (elements.devicePopup.classList.contains('active')) {
            elements.devicePopup.classList.remove('active');
        }
    });
    
    // --- テキストオーバーフローチェック ---
    
    let resizeTimer;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            updateTextOverflowForSelector(MARQUEE_SELECTOR);
        }, 250);
    });

    const observer = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
                const target = mutation.target;
                if (!target.classList.contains('hidden')) {
                    setTimeout(() => updateTextOverflowForSelector(MARQUEE_SELECTOR), 100);
                }
            }
        }
    });

    elements.views.forEach(view => {
        observer.observe(view, { attributes: true });
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
    
});