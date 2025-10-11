import { state, elements } from './state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './playback-manager.js';
import { showView } from './navigation.js';
import { togglePlayPause, seekToStart } from './player.js';
import { showModal } from './modal.js';
import { handleQuizKeyPress } from './quiz.js';
import { updateTextOverflowForSelector } from './ui/utils.js';
import { updateAudioDevices } from './ui-manager.js';
const { ipcRenderer } = require('electron');
const path = require('path');

export function initEventListeners() {
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
            ipcRenderer.send('start-scan-paths', musicPaths);
        }
        if (lyricsPaths.length > 0) {
            ipcRenderer.send('handle-lyrics-drop', lyricsPaths);
        }
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

        if (state.activeViewId === 'quiz-view') {
            handleQuizKeyPress(e);
            return;
        }
        
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
                // UI update for copy notification
            }
        } else if (modifierKey && e.key.toLowerCase() === 'v') {
            e.preventDefault();
            if (state.copiedSongIds.length > 0 && (state.currentDetailView.type === 'playlist' || state.currentDetailView.type === 'situation')) {
                const playlistName = state.currentDetailView.identifier;
                ipcRenderer.invoke('add-songs-to-playlist', { playlistName, songIds: state.copiedSongIds });
            }
        }
    });

    ipcRenderer.on('navigate-back', () => {
        if (state.currentDetailView.type) {
            showView(state.activeListView);
        }
    });
}