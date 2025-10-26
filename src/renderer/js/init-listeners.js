import { state, elements } from './state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './playback-manager.js';
import { showView } from './navigation.js';
import { togglePlayPause, seekToStart } from './player.js';
import { showModal } from './modal.js';
import { handleQuizKeyPress } from './quiz.js';
import { updateTextOverflowForSelector } from './ui/utils.js';
import { updateAudioDevices } from './ui-manager.js';
const { ipcRenderer } = require('electron');
const path = require('path'); // path is still needed for lyrics check if done here

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

        console.log('[Import Debug] Drop event triggered.');
        const files = Array.from(e.dataTransfer.files);
        console.log('[Import Debug] Raw dropped files list:', files);

        // --- ▼▼▼ Send File objects to main process ▼▼▼ ---
        if (files.length > 0) {
            // We need to extract the minimal necessary info because File objects themselves
            // might not serialize correctly over IPC, especially their non-standard properties.
            // The 'path' property IS the key piece of info needed by the main process.
            // Let's try sending just the path property again, assuming it *should* work
            // in a nodeIntegration context based on common Electron patterns.
            // If it's still undefined, we need a different approach (like main process handling drop).

            const filePaths = files.map(f => f.path).filter(p => typeof p === 'string' && p.length > 0);

            console.log('[Import Debug] Extracted paths to send:', filePaths);

            if (filePaths.length > 0) {
                // Send only the extracted paths to the main process
                ipcRenderer.send('files-dropped', filePaths);
            } else {
                console.warn('[Import Debug] No valid file paths could be extracted from dropped items.');
                // Maybe show an error to the user here
            }
        } else {
            console.log('[Import Debug] No files found in drop event.');
        }
        // --- ▲▲▲ Logic simplified to send paths ▲▲▲ ---
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

    // --- Sidebar Resizing Logic ---
    const resizer = document.getElementById('resizer');
    const rightSidebar = document.querySelector('.right-sidebar');

    const onMouseMove = (e) => {
        const newWidth = window.innerWidth - e.clientX - (resizer.offsetWidth / 2);
        if (newWidth >= 240 && newWidth <= 600) {
            rightSidebar.style.width = `${newWidth}px`;
        }
    };

    const onMouseUp = () => {
        document.body.classList.remove('resizing');
        document.removeEventListener('mousemove', onMouseMove);
        document.removeEventListener('mouseup', onMouseUp);
    };

    resizer.addEventListener('mousedown', (e) => {
        e.preventDefault();
        document.body.classList.add('resizing');
        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
    });
}