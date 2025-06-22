import { initUI, renderTrackView, renderAlbumView, updateNowPlayingView, renderPlaylistView } from './js/ui.js';
import { initIPC } from './js/ipc.js';
import { initNavigation } from './js/navigation.js';
import { initModal, showModal } from './js/modal.js';
import { initPlaylists } from './js/playlist.js';
import {renderPlaylistDetailView} from './js/ui.js';
import { initPlayer, play as playSongInPlayer, stop as stopSongInPlayer } from './js/player.js';
const { ipcRenderer } = require('electron');

window.addEventListener('DOMContentLoaded', () => {
    // --- 状態管理 ---
    const state = {
        library: [], // ライブラリ全体の曲
        albums: new Map(),
        playlists: [],
        playCounts: {},
        currentSongIndex: -1,
        currentlyVisibleSongs: [], // 現在UIに表示されている曲のリスト
    };

    // --- UI要素の取得 ---
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
        createPlaylistBtn: document.getElementById('create-playlist-btn-main'), // メインビューの作成ボタン
        openSettingsBtn: document.getElementById('open-settings-btn'),
        settingsModalOverlay: document.getElementById('settings-modal-overlay'),
        settingsOkBtn: document.getElementById('settings-ok-btn'),
        youtubeModeRadios: document.querySelectorAll('input[name="youtube-mode"]'),
        youtubeQualityRadios: document.querySelectorAll('input[name="youtube-quality"]'),
        // 他のモジュールから呼び出せるように関数を渡す
        showModal: showModal,
        showPlaylist: showPlaylist,
        playSong: playSong,
    };

    // --- モジュール初期化 ---
    initUI(elements, state, ipcRenderer);
    initPlayer(document.getElementById('main-player'), elements, state, ipcRenderer);
    initNavigation(elements, () => { // ★★★ 修正点: ナビゲーション時のコールバックをシンプルにする ★★★
        // ナビゲーションが変更されたら、現在のビューを描画するだけ
        renderCurrentView();
    });

    initModal(elements);
    initPlaylists(elements, ipcRenderer);
    initIPC(ipcRenderer, {
        onLibraryLoaded: (songs) => addSongsToLibrary(songs, true),
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
            // 現在プレイリストビューを表示しているなら再描画
            if (document.querySelector('.nav-link.active').dataset.view === 'playlist-view') {
                renderPlaylistView();
            }   
        },
        'show-loading': (text) => {
        elements.loadingOverlay.querySelector('.loading-text').textContent = text || '処理中...';
        elements.loadingOverlay.classList.remove('hidden');
        },
        'hide-loading': () => {
            elements.loadingOverlay.classList.add('hidden');
        },
        'show-error': (message) => {
            alert(message); // シンプルにアラートで表示
        }
    });
        // ★★★ 以下に設定モーダルのイベントリスナーを追加 ★★★
    elements.openSettingsBtn.addEventListener('click', async () => {
        const settings = await ipcRenderer.invoke('get-settings');
        const currentMode = settings.youtubePlaybackMode || 'download'; // デフォルトはdownload
        document.querySelector(`input[name="youtube-mode"][value="${currentMode}"]`).checked = true;
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
    // --- トップレベルのイベントリスナー ---
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
            if (elements.musicList.innerHTML === '' && state.library.length === 0) {
                document.querySelector('#track-view .placeholder')?.remove();
                elements.musicList.innerHTML = '<div class="placeholder">対応する音楽ファイルが見つかりませんでした。</div>';
            }
            elements.loadingOverlay.classList.add('hidden');
        }
    });

    // --- アプリケーションのコアロジック ---
    function addSongsToLibrary(newSongs, isInitialLoad = false) {
        if (!newSongs || newSongs.length === 0) return;
        const existingPaths = new Set(state.library.map(song => song.path));
        const uniqueNewSongs = newSongs.filter(song => !existingPaths.has(song.path));
        state.library = state.library.concat(uniqueNewSongs);
        document.querySelector('#track-view .placeholder')?.remove();
        groupLibraryByAlbum();

        // 起動時以外のファイル追加では、曲リストビューに切り替えて全体表示する
        if (!isInitialLoad) {
            state.currentlyVisibleSongs = state.library;
            document.querySelector('.nav-link[data-view="track-view"]').click();
        } else {
            // 起動時は、デフォルトで表示されているビューを再描画
            renderCurrentView();
        }
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
            // アクティブなリンクがない場合（＝プレイリスト詳細表示中）は何もしないか、
            // もしくはプレイリスト詳細ビューを再描画するロジックをここに入れることもできる。
            // 今回の修正では、再生状態の更新はplaySong関数から直接行うため、ここはシンプルにする。
            return;
        }
        const activeViewId = activeLink.dataset.view;
        
        // ★★★ 修正点: 表示中の曲リストを更新してから描画 ★★★
        if (activeViewId === 'track-view') {
            state.currentlyVisibleSongs = state.library;
            renderTrackView();
        } else if (activeViewId === 'album-view') {
            renderAlbumView();
        } else if (activeViewId === 'playlist-view') {
            renderPlaylistView();
        }
    }
    
    // ★★★ showPlaylist関数を全面的に修正 ★★★
    async function showPlaylist(playlistName) {
        // 1. プレイリストの曲情報を取得
        const songs = await ipcRenderer.invoke('get-playlist-songs', playlistName);
        state.currentlyVisibleSongs = songs; // 現在表示中の曲リストを更新
        state.currentSongIndex = -1; // プレイリストを切り替えたら再生インデックスはリセット

        // 2. UIの状態を更新
        // サイドバーのどのナビゲーションも選択されていない状態にする
        elements.navLinks.forEach(l => l.classList.remove('active'));
        // 「プレイリスト詳細ビュー」を表示し、他のビューはすべて隠す
        elements.views.forEach(view => {
            view.classList.toggle('hidden', view.id !== 'playlist-detail-view');
        });
        
        // 3. プレイリスト詳細ビューを描画する
        renderPlaylistDetailView(playlistName, songs);
            // ★★★ 追加点: 再生中パネルをデフォルト表示にリセット ★★★
        updateNowPlayingView(null); 
    }
    
    
// ★★★ playSong関数を以下のように書き換える ★★★
async function playSong(index, customSongList = null) {
    const songList = customSongList || state.currentlyVisibleSongs;
    if (index < 0 || index >= songList.length) {
        stopSongInPlayer(); // 再生停止
        return;
    }
    
    const songToPlay = songList[index];
    // ★★★ 再生部分のロジックをシンプル化 ★★★
    // すべての曲がローカルファイル扱いになるため、分岐は不要
    const streamUrl = `file://${songToPlay.path.replace(/\\/g, '/')}`;
    document.getElementById('main-player').src = streamUrl;
    document.getElementById('main-player').play();
    state.currentlyVisibleSongs = songList;
    state.currentSongIndex = index;
    
    // 再生中パネル(右サイドバー)とリストのハイライトを更新
    updateNowPlayingView(songToPlay);
    renderCurrentView(); // playingクラスの更新のため
    
    // player.jsに再生を指示
    await playSongInPlayer(songToPlay);
}
    elements.openSettingsBtn.addEventListener('click', async () => {
        const settings = await ipcRenderer.invoke('get-settings');
        // ★★★ 2つの設定を読み込むように修正 ★★★
        const currentMode = settings.youtubePlaybackMode || 'download';
        const currentQuality = settings.youtubeDownloadQuality || 'full';
        document.querySelector(`input[name="youtube-mode"][value="${currentMode}"]`).checked = true;
        document.querySelector(`input[name="youtube-quality"][value="${currentQuality}"]`).checked = true;
        elements.settingsModalOverlay.classList.remove('hidden');
    });

    elements.settingsOkBtn.addEventListener('click', () => {
        elements.settingsModalOverlay.classList.add('hidden');
    });

    // ... 既存のyoutubeModeRadiosのリスナーの下に追記
    elements.youtubeQualityRadios.forEach(radio => {
        radio.addEventListener('change', (event) => {
            ipcRenderer.send('save-settings', { 
                youtubeDownloadQuality: event.target.value 
            });
        });
    });
});