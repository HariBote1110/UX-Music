import { state, elements } from './state.js';
import { playSong } from './playback-manager.js';
const { ipcRenderer } = require('electron');

export function initUI() {
    // この関数は将来的にUI関連の初期化処理が増えた場合に使用します。
}

export function addSongsToLibrary(newSongs) {
    if (newSongs && newSongs.length > 0) {
        const existingPaths = new Set(state.library.map(song => song.path));
        const uniqueNewSongs = newSongs.filter(song => !existingPaths.has(song.path));
        state.library.push(...uniqueNewSongs);
    }
    groupLibraryByAlbum();
    groupLibraryByArtist();
    renderCurrentView();
}

function groupLibraryByAlbum() {
    state.albums.clear();
    const tempAlbumGroups = new Map();
    state.library.forEach(song => {
        if (song.type === 'youtube') return;
        const albumTitle = song.album || 'Unknown Album';
        if (!tempAlbumGroups.has(albumTitle)) {
            tempAlbumGroups.set(albumTitle, []);
        }
        tempAlbumGroups.get(albumTitle).push(song);
    });

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

function groupLibraryByArtist() {
    state.artists.clear();
    const tempArtistGroups = new Map();
    state.library.forEach(song => {
        const artistName = song.artist || 'Unknown Artist';
        if (!tempArtistGroups.has(artistName)) {
            tempArtistGroups.set(artistName, []);
        }
        tempArtistGroups.get(artistName).push(song);
    });

    for (const [artistName, songs] of tempArtistGroups.entries()) {
        const artwork = songs.find(s => s.artwork)?.artwork || null;
        state.artists.set(artistName, {
            name: artistName,
            artwork: artwork,
            songs: songs
        });
    }
}

export function renderCurrentView() {
    const activeLink = document.querySelector('.nav-link.active');
    
    if (activeLink) {
        const activeViewId = activeLink.dataset.view;
        if (activeViewId === 'track-view') renderTrackView();
        else if (activeViewId === 'album-view') renderAlbumView();
        else if (activeViewId === 'playlist-view') renderPlaylistView();
        else if (activeViewId === 'artist-view') renderArtistView();
    } else {
        const pDetail = document.getElementById('playlist-detail-view');
        const aDetail = document.getElementById('album-detail-view');
        const artistDetail = document.getElementById('artist-detail-view');
        if (!pDetail.classList.contains('hidden')) {
             renderPlaylistDetailView(pDetail.querySelector('#p-detail-title').textContent, state.originalQueueSource);
        } else if (!aDetail.classList.contains('hidden')) {
             const album = state.albums.get(aDetail.dataset.albumKey);
             if (album) renderAlbumDetailView(album);
        } else if (!artistDetail.classList.contains('hidden')) {
            const artist = state.artists.get(artistDetail.dataset.artistName);
            if (artist) renderArtistDetailView(artist);
        }
    }
}

export async function showPlaylist(playlistName) {
    const songs = await ipcRenderer.invoke('get-playlist-songs', playlistName);
    
    state.originalQueueSource = [...songs];
    state.playbackQueue = state.isShuffled ? state.shuffledQueue : state.originalQueueSource;
    state.currentSongIndex = -1;
    
    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    document.getElementById('playlist-detail-view').classList.remove('hidden');

    renderPlaylistDetailView(playlistName, songs);
}

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;

    state.originalQueueSource = [...album.songs];
    state.playbackQueue = state.isShuffled ? state.shuffledQueue : state.originalQueueSource;
    state.currentSongIndex = -1;

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const aDetail = document.getElementById('album-detail-view');
    aDetail.classList.remove('hidden');
    aDetail.dataset.albumKey = albumKey; 

    renderAlbumDetailView(album);
}

export function showArtist(artistName) {
    const artist = state.artists.get(artistName);
    if (!artist) return;

    // アーティスト詳細では再生キューを直接は変更しない
    state.currentSongIndex = -1;

    elements.views.forEach(view => view.classList.add('hidden'));
    elements.navLinks.forEach(l => l.classList.remove('active'));
    const artistDetail = document.getElementById('artist-detail-view');
    artistDetail.classList.remove('hidden');
    artistDetail.dataset.artistName = artistName;

    renderArtistDetailView(artist);
}


// --- 個別ビューのレンダリング関数 ---

function renderTrackView() {
    elements.musicList.innerHTML = '';
    if (state.library.length === 0) {
        elements.musicList.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    state.library.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, state.library));
        const artworkSrc = song.artwork || './assets/default_artwork.png';
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="${artworkSrc}" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist">${song.artist}</div>
            <div class="song-album">${song.album}</div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
            <div class="song-play-count">${state.playCounts[song.path] || 0}</div>
        `;
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song); 
        });
        elements.musicList.appendChild(songItem);
    });
}

function renderAlbumView() {
    elements.albumGrid.innerHTML = '';
    if (state.albums.size === 0) {
        elements.albumGrid.innerHTML = '<div class="placeholder">ライブラリにアルバムが見つかりません</div>';
        return;
    }
    for (const [key, album] of state.albums.entries()) {
        const albumItem = document.createElement('div');
        albumItem.className = 'album-grid-item';
        albumItem.innerHTML = `
            <img src="${album.artwork || './assets/default_artwork.png'}" class="album-artwork" alt="${album.title}">
            <div class="album-title">${album.title || 'Unknown Album'}</div>
            <div class="album-artist">${album.artist || 'Unknown Artist'}</div>
        `;
        albumItem.addEventListener('click', () => showAlbum(key));
        elements.albumGrid.appendChild(albumItem);
    }
}

function renderArtistView() {
    elements.artistGrid.innerHTML = '';
    if (state.artists.size === 0) {
        elements.artistGrid.innerHTML = '<div class="placeholder">ライブラリにアーティストが見つかりません</div>';
        return;
    }

    const sortedArtists = [...state.artists.values()].sort((a, b) => a.name.localeCompare(b.name));

    sortedArtists.forEach(artist => {
        const artistItem = document.createElement('div');
        artistItem.className = 'artist-grid-item';
        artistItem.innerHTML = `
            <img src="${artist.artwork || './assets/default_artwork.png'}" class="artist-artwork" alt="${artist.name}">
            <div class="artist-name">${artist.name}</div>
        `;
        artistItem.addEventListener('click', () => showArtist(artist.name));
        elements.artistGrid.appendChild(artistItem);
    });
}

function renderPlaylistView() {
    elements.playlistGrid.innerHTML = '';
    if (!state.playlists || state.playlists.length === 0) {
        elements.playlistGrid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
        return;
    }
    state.playlists.forEach(playlist => {
        const playlistItem = document.createElement('div');
        playlistItem.className = 'playlist-grid-item';
        playlistItem.innerHTML = `
            <div class="playlist-artwork-container"></div>
            <div class="playlist-title">${playlist.name}</div>
        `;
        const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
        createPlaylistArtwork(artworkContainer, playlist.artworks);
        playlistItem.addEventListener('click', () => showPlaylist(playlist.name));
        elements.playlistGrid.appendChild(playlistItem);
    });
}

function renderAlbumDetailView(album) {
    const view = elements.albumDetailView;
    view.querySelector('#a-detail-art').src = album.artwork || './assets/default_artwork.png';
    view.querySelector('#a-detail-title').textContent = album.title;
    view.querySelector('#a-detail-artist').textContent = album.artist;
    const totalDuration = album.songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    view.querySelector('#a-detail-meta').textContent = `${album.songs.length} 曲, ${formatTime(totalDuration)}`;

    const listElement = view.querySelector('#a-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    album.songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, album.songs));
        
        const artworkSrc = song.artwork || './assets/default_artwork.png';
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="${artworkSrc}" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist">${song.artist}</div>
            <div class="song-album">${song.album}</div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
            <div class="song-play-count">${state.playCounts[song.path] || 0}</div>
        `;
        listElement.appendChild(songItem);
    });
}

// ★★★ ここからが修正箇所です (ロジックを全面的に変更) ★★★
function renderArtistDetailView(artist) {
    const view = elements.artistDetailView;
    view.querySelector('#artist-detail-art').src = artist.artwork || './assets/default_artwork.png';
    view.querySelector('#artist-detail-name').textContent = artist.name;

    const gridElement = elements.artistDetailAlbumGrid;
    gridElement.innerHTML = '';

    // このアーティストが含まれるアルバムを state.albums から見つける
    const artistAlbums = [...state.albums.entries()].filter(([key, album]) => {
        // アルバムアーティスト、または参加アーティストのいずれかに含まれていれば対象とする
        return album.artist === artist.name || album.songs.some(song => song.artist === artist.name);
    });

    view.querySelector('#artist-detail-meta').textContent = `${artistAlbums.length}枚のアルバム, ${artist.songs.length}曲`;

    if (artistAlbums.length === 0) {
        gridElement.innerHTML = `<div class="placeholder">このアーティストのアルバムは見つかりません</div>`;
        return;
    }
    
    // 見つかったアルバムをグリッド表示する
    for (const [key, album] of artistAlbums) {
        const albumItem = document.createElement('div');
        albumItem.className = 'album-grid-item';
        albumItem.innerHTML = `
            <img src="${album.artwork || './assets/default_artwork.png'}" class="album-artwork" alt="${album.title}">
            <div class="album-title">${album.title || 'Unknown Album'}</div>
            <div class="album-artist">${album.artist || 'Unknown Artist'}</div>
        `;
        // クリックで通常のアルバム詳細画面に遷移
        albumItem.addEventListener('click', () => showAlbum(key));
        gridElement.appendChild(albumItem);
    }
}
// ★★★ ここまでが修正箇所です ★★★

function renderPlaylistDetailView(playlistName, songs) {
    const header = document.querySelector('#playlist-detail-view .detail-header');
    header.querySelector('#p-detail-title').textContent = playlistName;
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    header.querySelector('#p-detail-meta').textContent = `${songs.length} 曲, ${formatTime(totalDuration)}`;
    const artworkContainer = header.querySelector('.playlist-art-collage');
    const artworks = songs.map(s => s.artwork).filter(Boolean);
    createPlaylistArtwork(artworkContainer, artworks);

    const listElement = document.getElementById('p-detail-list');
    listElement.innerHTML = '';
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = currentPlayingSong && currentPlayingSong.path === song.path;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => playSong(index, songs));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-playlist-song-context-menu', { playlistName, song });
        });
        const artworkSrc = song.artwork || './assets/default_artwork.png';
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="${artworkSrc}" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist">${song.artist}</div>
            <div class="song-album">${song.album}</div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
            <div class="song-play-count">${state.playCounts[song.path] || 0}</div>
        `;
        listElement.appendChild(songItem);
    });
}

export function updateNowPlayingView(song) {
    const previewContainer = elements.nowPlayingArtworkContainer;
    const localPlayer = document.getElementById('main-player');
    const ytPlayerWrapper = document.getElementById('youtube-player-container');
    const hubLinkContainer = document.getElementById('hub-link-container');

    previewContainer.innerHTML = '';
    hubLinkContainer.innerHTML = '';
    previewContainer.classList.remove('video-mode');
    document.body.appendChild(localPlayer);
    document.body.appendChild(ytPlayerWrapper);
    localPlayer.style.display = 'none';

    if (!song) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        previewContainer.appendChild(img);
    } else if (song.type === 'youtube') {
        previewContainer.classList.add('video-mode');
        previewContainer.appendChild(ytPlayerWrapper);
    } else if (song.type === 'local' && song.path && song.path.toLowerCase().endsWith('.mp4')) {
        previewContainer.classList.add('video-mode');
        localPlayer.style.display = 'block';
        previewContainer.appendChild(localPlayer);
    } else {
        const img = document.createElement('img');
        img.src = song.artwork || './assets/default_artwork.png';
        previewContainer.appendChild(img);
    }
    
    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => ipcRenderer.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    elements.nowPlayingTitle.textContent = song ? song.title : '曲を選択してください';
    elements.nowPlayingArtist.textContent = song ? song.artist : '';
}

function createPlaylistArtwork(container, artworks) {
    container.innerHTML = '';
    container.classList.remove('grid-collage'); 

    if (!artworks || artworks.length === 0) {
        container.innerHTML = `<div style="font-size: 50px; text-align: center; width: 100%; height: 100%; display: flex; align-items: center; justify-content: center;">🎵</div>`;
    } else if (artworks.length < 4) {
        const img = document.createElement('img');
        img.src = artworks[0];
        container.appendChild(img);
    } else {
        container.classList.add('grid-collage');
        for (let i = 0; i < 4; i++) {
            const imgWrapper = document.createElement('div');
            imgWrapper.className = 'collage-img-wrapper';
            const img = document.createElement('img');
            img.src = artworks[i];
            imgWrapper.appendChild(img);
            container.appendChild(imgWrapper);
        }
    }
}

function formatTime(seconds) {
    if (isNaN(seconds) || seconds < 0) return '0:00';
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}

// ui-manager.js の一番下にある updateAudioDevices 関数を修正

export async function updateAudioDevices(targetDeviceId = null) {
    const mainPlayer = document.getElementById('main-player');
    const currentSelectedId = elements.audioOutputSelect.value; 

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

        let deviceIdToSet = null;
        if (targetDeviceId && audioDevices.some(d => d.deviceId === targetDeviceId)) {
            deviceIdToSet = targetDeviceId;
        } else if (audioDevices.some(d => d.deviceId === currentSelectedId)) {
            deviceIdToSet = currentSelectedId;
        } else if (audioDevices.length > 0) {
            deviceIdToSet = audioDevices[0].deviceId;
        }

        if (deviceIdToSet) {
            elements.audioOutputSelect.value = deviceIdToSet;
            // ★★★ 修正箇所: この行をコメントアウト ★★★
            // if (mainPlayer.sinkId !== deviceIdToSet) {
            //      await mainPlayer.setSinkId(deviceIdToSet);
            // }
        }
    } catch (error) {
        console.error('Could not enumerate audio devices:', error);
    }
}