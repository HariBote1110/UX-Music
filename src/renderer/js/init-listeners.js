import { state, elements } from './state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from './playback-manager.js';
import { showView } from './navigation.js';
import { togglePlayPause, seekToStart } from './player.js';
import { showModal } from './modal.js';
import { handleQuizKeyPress } from './quiz.js';
import { updateTextOverflowForSelector } from './ui/utils.js';
import { updateAudioDevices } from './ui-manager.js';
import { updateSearchQuery } from './ui.js';
import { musicApi } from './bridge.js';
const electronAPI = window.electronAPI;

export function initEventListeners() {
    elements.nextBtn.addEventListener('click', playNextSong);
    elements.prevBtn.addEventListener('click', playPrevSong);
    elements.shuffleBtn.addEventListener('click', toggleShuffle);
    elements.loopBtn.addEventListener('click', toggleLoopMode);

    const libraryActionsBtn = document.getElementById('library-actions-btn');
    const libraryActionsPopup = document.getElementById('library-actions-popup');

    if (libraryActionsBtn) {
        libraryActionsBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            libraryActionsPopup.classList.toggle('hidden');
        });
    }

    const addNetworkBtn = document.getElementById('add-network-folder-btn');
    if (addNetworkBtn) {
        addNetworkBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            showModal({
                title: 'ネットワークフォルダのパス',
                placeholder: '\\\\ServerName\\ShareName',
                onOk: (path) => {
                    // electronAPI.send('start-scan-paths', [path]);
                    musicApi.startScanPaths([path]);
                }
            });
        });
    }

    const addYoutubeBtn = document.getElementById('add-youtube-btn');
    if (addYoutubeBtn) {
        addYoutubeBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            showModal({
                title: 'YouTubeのリンク',
                placeholder: 'https://www.youtube.com/watch?v=...',
                onOk: (url) => electronAPI.send('add-youtube-link', url)
            });
        });
    }

    const addYoutubePlaylistBtn = document.getElementById('add-youtube-playlist-btn');
    if (addYoutubePlaylistBtn) {
        addYoutubePlaylistBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            showModal({
                title: 'YouTubeプレイリストのリンク',
                placeholder: 'https://www.youtube.com/playlist?list=...',
                onOk: (url) => electronAPI.send('import-youtube-playlist', url)
            });
        });
    }

    const setLibraryBtn = document.getElementById('set-library-btn');
    if (setLibraryBtn) {
        setLibraryBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            electronAPI.send('set-library-path');
        });
    }

    const normalizeBtn = document.getElementById('normalize-view-btn');
    if (normalizeBtn) {
        normalizeBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            showView('normalize-view');
        });
    }

    const cdRipBtn = document.getElementById('cd-rip-view-btn');
    if (cdRipBtn) {
        cdRipBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            showView('cd-rip-view');
        });
    }

    // 検索ボックス
    const searchInput = document.getElementById('search-input');
    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            updateSearchQuery(e.target.value);
        });
    }

    if (elements.dropZone) {
        elements.dropZone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); elements.dropZone.classList.add('drag-over'); });
        elements.dropZone.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); elements.dropZone.classList.remove('drag-over'); });
        elements.dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            elements.dropZone.classList.remove('drag-over');
            console.log('[DnD] Drop event fired');
            const allPaths = Array.from(e.dataTransfer.files).map(f => f.path);
            console.log('[DnD] Dropped paths:', allPaths);

            if (allPaths.length === 0) return;
            const lyricsExtensions = ['.lrc', '.txt'];
            const lyricsPaths = allPaths.filter(p => {
                const lastDot = p.lastIndexOf('.');
                const ext = lastDot !== -1 ? p.substring(lastDot).toLowerCase() : '';
                return lyricsExtensions.includes(ext);
            });
            const musicPaths = allPaths.filter(p => {
                const lastDot = p.lastIndexOf('.');
                const ext = lastDot !== -1 ? p.substring(lastDot).toLowerCase() : '';
                return !lyricsExtensions.includes(ext);
            });

            console.log('[DnD] Music paths to process:', musicPaths);

            if (musicPaths.length > 0) {
                // electronAPI.send('start-scan-paths', musicPaths);
                console.log('[DnD] Calling musicApi.startScanPaths...');
                musicApi.startScanPaths(musicPaths);
            }
            if (lyricsPaths.length > 0) {
                // electronAPI.send('handle-lyrics-drop', lyricsPaths);
                musicApi.handleLyricsDrop(lyricsPaths);
            }
        });
    }

    if (elements.deviceSelectButton) {
        elements.deviceSelectButton.addEventListener('click', (e) => {
            e.stopPropagation();
            updateAudioDevices();
            if (elements.devicePopup) elements.devicePopup.classList.toggle('active');
        });
    }

    if (elements.sidebarTabs && elements.sidebarTabContents) {
        elements.sidebarTabs.forEach(tab => {
            tab.addEventListener('click', () => {
                elements.sidebarTabs.forEach(t => t.classList.remove('active'));
                tab.classList.add('active');

                elements.sidebarTabContents.forEach(c => c.classList.remove('active'));

                const targetId = tab.dataset.tab;
                const targetContent = document.getElementById(targetId);
                if (targetContent) {
                    targetContent.classList.add('active');
                }
            });
        });
    }

    window.addEventListener('click', (e) => {
        if (elements.devicePopup && elements.devicePopup.classList.contains('active')) {
            elements.devicePopup.classList.remove('active');
        }
        if (libraryActionsPopup && !libraryActionsPopup.classList.contains('hidden') && !libraryActionsPopup.contains(e.target) && e.target !== libraryActionsBtn) {
            libraryActionsPopup.classList.add('hidden');
        }
    });

    window.addEventListener('contextmenu', (e) => {
        if (e.target.closest('.song-item') ||
            e.target.closest('input') ||
            e.target.closest('button') ||
            e.target.closest('a')) {
            return;
        }

        e.preventDefault();
        electronAPI.send('show-general-context-menu');
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

                document.querySelectorAll('.song-item.selected').forEach(item => {
                    item.classList.remove('selected');
                });

                if (!allSelected) {
                    document.querySelectorAll('.song-item').forEach(item => {
                        item.classList.add('selected');
                    });
                }
            }
        } else if (modifierKey && e.key.toLowerCase() === 'c') {
            e.preventDefault();
            if (state.selectedSongIds.size > 0) {
                state.copiedSongIds = [...state.selectedSongIds];
            }
        } else if (modifierKey && e.key.toLowerCase() === 'v') {
            e.preventDefault();
            if (state.copiedSongIds.length > 0 && (state.currentDetailView.type === 'playlist' || state.currentDetailView.type === 'situation')) {
                const playlistName = state.currentDetailView.identifier;
                electronAPI.invoke('add-songs-to-playlist', { playlistName, songIds: state.copiedSongIds });
            }
        }
    });

    electronAPI.on('navigate-back', () => {
        if (state.currentDetailView.type) {
            showView(state.activeListView);
        }
    });

    const resizer = document.getElementById('resizer');
    const rightSidebar = document.querySelector('.right-sidebar');

    if (resizer && rightSidebar) {
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
}