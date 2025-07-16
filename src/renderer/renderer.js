import { initUI, renderTrackView, renderAlbumView, updateNowPlayingView, renderPlaylistView, renderPlaylistDetailView } from './js/ui.js';
import { initIPC } from './js/ipc.js';
import { initNavigation } from './js/navigation.js';
import { initModal, showModal } from './js/modal.js';
import { initPlaylists } from './js/playlist.js';
import { initPlayer, play as playSongInPlayer, stop as stopSongInPlayer } from './js/player.js';
const { ipcRenderer } = require('electron');

window.addEventListener('DOMContentLoaded', () => {
    const state = {
        library: [],
        albums: new Map(),
        playlists: [],
        playCounts: {},
        currentSongIndex: -1,
        currentlyVisibleSongs: [],
    };

    const elements = {
        musicList: document.getElementById('music-list'),
        albumGrid: document.getElementById('album-grid'),
        playlistGrid: document.getElementById('playlist-grid'),
        nowPlayingArtworkContainer: document.getElementById('now-playing-artwork-container'),
        nowPlayingTitle: document.getElementById('now-playing-title'),
        nowPlayingArtist: document.getElementById('now-playing-artist'),
        playPauseBtn: document.getElementById('play-pause-btn'),
        progressBar: document.getElementById('progress-bar'),
        currentTimeEl: document.getElementById('current-time'),
        totalDurationEl: document.getElementById('total-duration'),
        volumeSlider: document.getElementById('volume-slider'),
        volumeIcon: document.getElementById('volume-icon'),
        audioOutputSelect: document.getElementById('audio-output-select'),
        navLinks: document.querySelectorAll('.nav-link'),
        views: document.querySelectorAll('.view-container'),
        modalOverlay: document.getElementById('modal-overlay'),
        modalTitle: document.querySelector('#modal h3'),
        modalInput: document.getElementById('modal-input'),
        modalOkBtn: document.getElementById('modal-ok-btn'),
        modalCancelBtn: document.getElementById('modal-cancel-btn'),
        dropZone: document.getElementById('drop-zone'),
        addNetworkFolderBtn: document.getElementById('add-network-folder-btn'),
        addYoutubeBtn: document.getElementById('add-youtube-btn'),
        setLibraryBtn: document.getElementById('set-library-btn'),
        loadingOverlay: document.getElementById('loading-overlay'),
        createPlaylistBtn: document.getElementById('create-playlist-btn-main'),
        openSettingsBtn: document.getElementById('open-settings-btn'),
        settingsModalOverlay: document.getElementById('settings-modal-overlay'),
        settingsOkBtn: document.getElementById('settings-ok-btn'),
        youtubeModeRadios: document.querySelectorAll('input[name="youtube-mode"]'),
        youtubeQualityRadios: document.querySelectorAll('input[name="youtube-quality"]'),
        addYoutubePlaylistBtn: document.getElementById('add-youtube-playlist-btn'),
        showModal: showModal,
        showPlaylist: showPlaylist,
        playSong: playSong,
    };

    function addSongsToLibrary(newSongs) {
        if (!newSongs || newSongs.length === 0) return;
        const existingPaths = new Set(state.library.map(song => song.path));
        const uniqueNewSongs = newSongs.filter(song => !existingPaths.has(song.path));
        state.library.push(...uniqueNewSongs);
        groupLibraryByAlbum();
        renderCurrentView();
    }

    function groupLibraryByAlbum() {
        state.albums.clear();
        const tempAlbumGroups = new Map();
        for (const song of state.library) {
            if (song.type === 'youtube') continue;
            const albumTitle = song.album || 'Unknown Album';
            if (!tempAlbumGroups.has(albumTitle)) {
                tempAlbumGroups.set(albumTitle, []);
            }
            tempAlbumGroups.get(albumTitle).push(song);
        }
        for (const [albumTitle, songsInAlbum] of tempAlbumGroups.entries()) {
            const albumArtistsSet = new Set(songsInAlbum.map(s => s.albumartist).filter(Boolean));
            let representativeArtist = 'Unknown Artist';
            if (albumArtistsSet.size > 1) {
                representativeArtist = 'Various Artists';
            } else if (albumArtistsSet.size === 1) {
                representativeArtist = [...albumArtistsSet][0];
            } else {
                const trackArtistsSet = new Set(songsInAlbum.map(s => s.artist));
                if (trackArtistsSet.size > 1) {
                    representativeArtist = 'Various Artists';
                } else if (trackArtistsSet.size === 1) {
                    representativeArtist = [...trackArtistsSet][0];
                }
            }
            const finalAlbumKey = `${albumTitle}---${representativeArtist}`;
            if (!state.albums.has(finalAlbumKey)) {
                state.albums.set(finalAlbumKey, {
                    title: albumTitle,
                    artist: representativeArtist,
                    artwork: songsInAlbum[0].artwork,
                    songs: songsInAlbum
                });
            }
        }
    }

    function renderCurrentView() {
        const activeLink = document.querySelector('.nav-link.active');
        if (!activeLink) {
            const detailView = document.getElementById('playlist-detail-view');
            if (!detailView.classList.contains('hidden')) {
                const playlistName = detailView.querySelector('#p-detail-title').textContent;
                showPlaylist(playlistName);
            }
            return;
        }
        const activeViewId = activeLink.dataset.view;
        if (activeViewId === 'track-view') {
            state.currentlyVisibleSongs = state.library;
            renderTrackView();
        } else if (activeViewId === 'album-view') {
            renderAlbumView();
        } else if (activeViewId === 'playlist-view') {
            renderPlaylistView();
        }
    }
    
    async function showPlaylist(playlistName) {
        const songs = await ipcRenderer.invoke('get-playlist-songs', playlistName);
        state.currentlyVisibleSongs = songs;
        state.currentSongIndex = -1;
        elements.navLinks.forEach(l => l.classList.remove('active'));
        elements.views.forEach(view => {
            view.classList.toggle('hidden', view.id !== 'playlist-detail-view');
        });
        renderPlaylistDetailView(playlistName, songs);
        updateNowPlayingView(null);
    }
    
    async function playSong(index, customSongList = null) {
        const songList = customSongList || state.currentlyVisibleSongs;
        if (index < 0 || index >= songList.length) {
            stopSongInPlayer();
            return;
        }
        const songToPlay = songList[index];
        state.currentlyVisibleSongs = songList;
        state.currentSongIndex = index;
        updateNowPlayingView(songToPlay);
        renderCurrentView();
        await playSongInPlayer(songToPlay);
    }

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

    initUI(elements, state, ipcRenderer);
    initPlayer(document.getElementById('main-player'), elements, state, ipcRenderer);
    initNavigation(elements, renderCurrentView);
    initModal(elements);
    initPlaylists(elements, ipcRenderer);
    
    initIPC(ipcRenderer, {
        onLibraryLoaded: (songs) => {
            state.library = songs || [];
            groupLibraryByAlbum();
            renderCurrentView();
        },
        onSettingsLoaded: async (settings) => {
            try {
                const devices = await navigator.mediaDevices.enumerateDevices();
                const audioDevices = devices.filter(device => device.kind === 'audiooutput');
                elements.audioOutputSelect.innerHTML = '';
                audioDevices.forEach(device => {
                    const option = document.createElement('option');
                    option.value = device.deviceId;
                    option.textContent = device.label || `スピーカー ${elements.audioOutputSelect.options.length + 1}`;
                    elements.audioOutputSelect.appendChild(option);
                });
                if (settings.audioOutputId && audioDevices.some(d => d.deviceId === settings.audioOutputId)) {
                    elements.audioOutputSelect.value = settings.audioOutputId;
                    await document.getElementById('main-player').setSinkId(settings.audioOutputId);
                }
                if (typeof settings.volume === 'number') {
                    document.getElementById('main-player').volume = settings.volume;
                    elements.volumeSlider.value = settings.volume;
                }
            } catch (error) {
                console.error('Could not enumerate devices:', error);
            }
        },
        onPlayCountsUpdated: (counts) => {
            state.playCounts = counts;
            renderCurrentView();
        },
        onYoutubeLinkProcessed: (song) => addSongsToLibrary([song]),
        onPlaylistsUpdated: (playlists) => {
            state.playlists = playlists;
            if (document.querySelector('.nav-link.active')?.dataset.view === 'playlist-view') {
                renderPlaylistView();
            }
        },
        'force-reload-playlist': (event, playlistName) => {
            const detailView = document.getElementById('playlist-detail-view');
            if (!detailView.classList.contains('hidden')) {
                showPlaylist(playlistName);
            }
        },
        'force-reload-library': () => {
             ipcRenderer.send('request-initial-library');
        },
        'show-loading': (text) => {
            elements.loadingOverlay.querySelector('.loading-text').textContent = text || '処理中...';
            elements.loadingOverlay.classList.remove('hidden');
        },
        'hide-loading': () => {
            elements.loadingOverlay.classList.add('hidden');
        },
        'show-error': (message) => {
            alert(message);
        },
        'playlist-import-progress': (progress) => {
            const text = `${progress.total}曲中 ${progress.current}曲目: ${progress.title}`;
            elements.loadingOverlay.querySelector('.loading-text').textContent = text;
            if (elements.loadingOverlay.classList.contains('hidden')) {
                elements.loadingOverlay.classList.remove('hidden');
            }
        },
        'playlist-import-finished': () => {
            elements.loadingOverlay.classList.add('hidden');
        }
    });

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
            placeholder: 'https://www.youtube.com/watch?v=...`）を貼り付けてOKを押します。...',
            onOk: (url) => {
                ipcRenderer.send('add-youtube-link', url);
            }
        });
    });
    elements.addYoutubePlaylistBtn.addEventListener('click', () => {
        showModal({
            title: 'YouTubeプレイリストのリンク',
            placeholder: 'https://www.youtube.com/playlist?list=PL...',
            onOk: (url) => {
                ipcRenderer.send('import-youtube-playlist', url);
            }
        });
    });
    elements.setLibraryBtn.addEventListener('click', () => {
        ipcRenderer.send('set-library-path');
    });
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
    elements.settingsOkBtn.addEventListener('click', () => {
        elements.settingsModalOverlay.classList.add('hidden');
    });
    elements.youtubeModeRadios.forEach(radio => {
        radio.addEventListener('change', (event) => {
            ipcRenderer.send('save-settings', { 
                youtubePlaybackMode: event.target.value 
            });
        });
    });
    elements.youtubeQualityRadios.forEach(radio => {
        radio.addEventListener('change', (event) => {
            ipcRenderer.send('save-settings', { 
                youtubeDownloadQuality: event.target.value 
            });
        });
    });

    initResizer();

    ipcRenderer.send('request-initial-library');
    ipcRenderer.send('request-initial-play-counts');
    ipcRenderer.send('request-initial-settings');
});