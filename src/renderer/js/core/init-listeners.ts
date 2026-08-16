import { state, elements } from './state.js';
import { playNextSong, playPrevSong, toggleShuffle, toggleLoopMode } from '../features/playback-manager.js';
import { runShuffleAnimation, runLoopAnimation } from '../ui/player-ui.js';
import { showView } from './navigation.js';
import { togglePlayPause, seekToStart } from '../features/player.js';
import { showModal } from '../ui/modal.js';
import { handleQuizKeyPress } from '../features/quiz.js';
import { updateTextOverflowForSelector } from '../ui/utils.js';
import { updateAudioDevices } from '../ui/ui-manager.js';
import { updateSearchQuery } from '../ui/ui.js';
import { musicApi, getWailsApp } from './bridge.js';
import { enableYoutubeAdvancedModesWithConsent } from '../utils/debug-commands.js';
import { buildYouTubeAddPayload } from './init-listeners-youtube.js';

const electronAPI = window.electronAPI;

export function initEventListeners() {
    elements.nextBtn.addEventListener('click', playNextSong);
    elements.prevBtn.addEventListener('click', playPrevSong);
    elements.shuffleBtn.addEventListener('click', () => {
        toggleShuffle();
        runShuffleAnimation();
    });
    elements.loopBtn.addEventListener('click', () => {
        toggleLoopMode();
        runLoopAnimation();
    });

    const libraryActionsBtn = document.getElementById('library-actions-btn');
    const libraryActionsPopup = document.getElementById('library-actions-popup');
    const youtubeAdvancedModesUnlockTapRequired = 7;
    const youtubeAdvancedModesUnlockWindowMs = 2500;
    let libraryActionsTapCount = 0;
    let libraryActionsTapTimer = null;
    let youtubeAdvancedModesUnlockInProgress = false;

    if (libraryActionsBtn) {
        libraryActionsBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            libraryActionsPopup.classList.toggle('hidden');

            if (libraryActionsTapTimer) {
                clearTimeout(libraryActionsTapTimer);
            }
            libraryActionsTapCount += 1;
            libraryActionsTapTimer = setTimeout(() => {
                libraryActionsTapCount = 0;
            }, youtubeAdvancedModesUnlockWindowMs);

            if (libraryActionsTapCount < youtubeAdvancedModesUnlockTapRequired || youtubeAdvancedModesUnlockInProgress) {
                return;
            }

            libraryActionsTapCount = 0;
            youtubeAdvancedModesUnlockInProgress = true;
            void enableYoutubeAdvancedModesWithConsent({ showAlert: true })
                .finally(() => {
                    youtubeAdvancedModesUnlockInProgress = false;
                });
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
                onOk: async (url) => {
                    const payload = await buildYouTubeAddPayload(url);
                    if (!payload) {
                        return;
                    }
                    console.log('[YouTube][UI] add-youtube-link payload:', payload);
                    electronAPI.send('add-youtube-link', payload);
                }
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
            void showView('normalize-view');
        });
    }

    const cdRipBtn = document.getElementById('cd-rip-view-btn');
    if (cdRipBtn) {
        cdRipBtn.addEventListener('click', () => {
            if (libraryActionsPopup) libraryActionsPopup.classList.add('hidden');
            void showView('cd-rip-view');
        });
    }

    // 検索ボックス
    const searchInput = document.getElementById('search-input');
    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            updateSearchQuery((e.target as HTMLInputElement).value);
        });
    }

    const deleteSelectedSongs = async () => {
        if (state.selectedSongIds.size === 0) return;

        const selectedPaths = state.library
            .filter(song => state.selectedSongIds.has(song.id))
            .map(song => song.path)
            .filter(Boolean);

        if (selectedPaths.length === 0) return;

        const targetCount = selectedPaths.length;
        const message = targetCount === 1
            ? '選択した1曲をライブラリから削除しますか？'
            : `選択した${targetCount}曲をライブラリから削除しますか？`;

        if (!window.confirm(message)) return;

        const wailsApp = getWailsApp();
        if (wailsApp?.DeleteSongs) {
            wailsApp.DeleteSongs(selectedPaths, false).catch((err) => {
                console.error('[DeleteSongs] failed:', err);
            });
        }
    };

    const processDroppedPaths = (allPaths) => {
        if (!Array.isArray(allPaths) || allPaths.length === 0) return;

        const normalized = allPaths
            .filter(p => typeof p === 'string' && p.trim() !== '')
            .map(p => p.trim());
        if (normalized.length === 0) return;

        console.log('[DnD] Dropped paths:', normalized);

        const lyricsExtensions = ['.lrc', '.txt'];
        const lyricsPaths = normalized.filter(p => {
            const lastDot = p.lastIndexOf('.');
            const ext = lastDot !== -1 ? p.substring(lastDot).toLowerCase() : '';
            return lyricsExtensions.includes(ext);
        });
        const musicPaths = normalized.filter(p => {
            const lastDot = p.lastIndexOf('.');
            const ext = lastDot !== -1 ? p.substring(lastDot).toLowerCase() : '';
            return !lyricsExtensions.includes(ext);
        });

        console.log('[DnD] Music paths to process:', musicPaths);
        if (musicPaths.length > 0) {
            console.log('[DnD] Calling musicApi.startScanPaths...');
            musicApi.startScanPaths(musicPaths);
        }
        if (lyricsPaths.length > 0) {
            musicApi.handleLyricsDrop(lyricsPaths);
        }
    };

    const hasWailsFileDrop = !!(window.runtime && typeof window.runtime.OnFileDrop === 'function');
    if (hasWailsFileDrop) {
        // Wails provides native path strings directly. This is more reliable than File.path.
        window.runtime.OnFileDrop((x, y, paths) => {
            console.log('[DnD][Wails] OnFileDrop:', { x, y, count: Array.isArray(paths) ? paths.length : 0 });
            processDroppedPaths(paths || []);
        }, false);
    }

    if (elements.dropZone) {
        elements.dropZone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); elements.dropZone.classList.add('drag-over'); });
        elements.dropZone.addEventListener('dragleave', (e) => { e.preventDefault(); e.stopPropagation(); elements.dropZone.classList.remove('drag-over'); });
        elements.dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            elements.dropZone.classList.remove('drag-over');
            console.log('[DnD] Drop event fired');
            // In Wails, use OnFileDrop callback path list to avoid duplicate handling.
            if (hasWailsFileDrop) return;

            const allPaths = Array.from(e.dataTransfer?.files || [])
                .map(f => (f as unknown as { path: string }).path)
                .filter(Boolean);
            processDroppedPaths(allPaths);
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
        if (libraryActionsPopup && !libraryActionsPopup.classList.contains('hidden') && !libraryActionsPopup.contains(e.target as Node) && e.target !== libraryActionsBtn) {
            libraryActionsPopup.classList.add('hidden');
        }
    });

    window.addEventListener('contextmenu', (e) => {
        const target = e.target as Element | null;
        if (target?.closest('.song-item') ||
            target?.closest('#now-playing-artwork-container') ||
            target?.closest('#footer-artwork-container') ||
            target?.closest('input') ||
            target?.closest('button') ||
            target?.closest('a')) {
            return;
        }

        e.preventDefault();
        electronAPI.send('show-general-context-menu');
    });

    const refreshMarqueeOverflow = () => {
        updateTextOverflowForSelector('.marquee-wrapper');
    };

    let resizeTimer;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(refreshMarqueeOverflow, 250);
    });

    // スリープ復帰やフォーカス復帰時にマルキー状態を再計算する
    window.addEventListener('focus', refreshMarqueeOverflow);
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) {
            refreshMarqueeOverflow();
        }
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
            if (state.currentlyViewedSongIds && state.currentlyViewedSongIds.length > 0) {
                const allIds = new Set(state.currentlyViewedSongIds);
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
        } else if ((e.key === 'Delete' || e.key === 'Backspace') && state.selectedSongIds.size > 0) {
            e.preventDefault();
            deleteSelectedSongs();
        }
    });

    const resizer = document.getElementById('resizer');
    const rightSidebar = document.querySelector('.right-sidebar') as HTMLElement | null;
    const footerArtworkContainer = document.getElementById('footer-artwork-container');

    const SIDEBAR_SNAP_THRESHOLD = 150; // px — これ以下になったら折り畳み
    const SIDEBAR_DEFAULT_WIDTH  = 300;
    let savedSidebarWidth = SIDEBAR_DEFAULT_WIDTH;

    function collapseSidebar() {
        savedSidebarWidth = parseInt(rightSidebar.style.width, 10) || SIDEBAR_DEFAULT_WIDTH;
        rightSidebar.classList.add('collapsed');
        resizer.classList.add('sidebar-collapsed');
        if (footerArtworkContainer) footerArtworkContainer.classList.remove('hidden');
    }

    function expandSidebar() {
        rightSidebar.classList.remove('collapsed');
        rightSidebar.style.width = `${savedSidebarWidth}px`;
        resizer.classList.remove('sidebar-collapsed');
        if (footerArtworkContainer) footerArtworkContainer.classList.add('hidden');
    }

    if (resizer && rightSidebar) {
        let hasDragged = false;

        const onMouseMove = (e) => {
            hasDragged = true;
            const newWidth = window.innerWidth - e.clientX - (resizer.offsetWidth / 2);

            if (newWidth < SIDEBAR_SNAP_THRESHOLD) {
                // 閾値を下回ったら折り畳んでドラッグ終了（スナップアニメーションのためトランジション復元）
                rightSidebar.style.transition = '';
                collapseSidebar();
                document.body.classList.remove('resizing');
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
                return;
            }

            if (newWidth <= 600) {
                rightSidebar.style.width = `${Math.max(newWidth, 160)}px`;
            }
        };

        const onMouseUp = () => {
            rightSidebar.style.transition = ''; // トランジション復元
            document.body.classList.remove('resizing');
            document.removeEventListener('mousemove', onMouseMove);
            document.removeEventListener('mouseup', onMouseUp);
        };

        resizer.addEventListener('mousedown', (e) => {
            e.preventDefault();
            hasDragged = false;

            // 折り畳み済みのときはクリックで展開
            if (rightSidebar.classList.contains('collapsed')) {
                expandSidebar();
                return;
            }

            rightSidebar.style.transition = 'none'; // ドラッグ中はトランジション無効化
            document.body.classList.add('resizing');
            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);
        });
    }
}
