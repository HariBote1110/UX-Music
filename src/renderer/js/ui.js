const elements = {};
let state = {};
let ipc;

export function initUI(uiElements, appState, ipcRenderer) {
    Object.assign(elements, uiElements);
    state = appState;
    ipc = ipcRenderer;
}

// ヘルパー: YouTube URLから動画IDを取得
function getYoutubeVideoId(url) {
    const regExp = /^.*(youtu.be\/|v\/|u\/\w\/|embed\/|watch\?v=|&v=)([^#&?]*).*/;
    const match = url.match(regExp);
    return (match && match[2].length === 11) ? match[2] : null;
}

// src/renderer/js/ui.js 内の updateNowPlayingView 関数を置き換え

export function updateNowPlayingView(song) {
    const previewContainer = document.getElementById('now-playing-artwork-container');
    const localPlayer = document.getElementById('main-player');
    const ytPlayerWrapper = document.getElementById('youtube-player-container');

    // 全てのプレーヤーを一旦、元の非表示の場所に戻す
    document.body.appendChild(localPlayer);
    document.body.appendChild(ytPlayerWrapper);
    localPlayer.style.display = 'none';
    previewContainer.innerHTML = '';

    // アスペクト比をコントロールするクラスを一度リセット
    previewContainer.classList.remove('video-mode');

    if (!song) {
        // 曲がない場合 (1:1)
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        previewContainer.appendChild(img);
    } else if (song.type === 'youtube') {
        // ストリーミング再生の場合 (16:9)
        previewContainer.classList.add('video-mode');
        previewContainer.appendChild(ytPlayerWrapper);
    } else if (song.type === 'local' && song.sourceURL) {
        // --- ★★★ ここからが新しいロジック ★★★ ---
        // ダウンロード済みのYouTube曲の場合
        if (song.path && song.path.toLowerCase().endsWith('.mp4')) {
            // 【動画ファイルの場合】(16:9)
            previewContainer.classList.add('video-mode');
            localPlayer.style.display = 'block';
            previewContainer.appendChild(localPlayer);
        } else {
            // 【音声ファイルの場合（省データモード）】(1:1)
            const img = document.createElement('img');
            img.src = song.artwork || './assets/default_artwork.png';
            previewContainer.appendChild(img);
        }
        // --- ★★★ ここまで ★★★ ---
    } else {
        // 通常のローカル音声ファイルの場合 (1:1)
        const img = document.createElement('img');
        img.src = song.artwork || './assets/default_artwork.png';
        previewContainer.appendChild(img);
    }

    // 曲名とアーティストの更新
    if (song) {
        elements.nowPlayingTitle.textContent = song.title;
        elements.nowPlayingArtist.textContent = song.artist;
    } else {
        elements.nowPlayingTitle.textContent = '曲を選択してください';
        elements.nowPlayingArtist.textContent = '';
    }
}

export function renderTrackView() {
    elements.musicList.innerHTML = '';
    if (state.library.length === 0) {
        elements.musicList.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }
    state.library.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = state.currentSongIndex === index;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => elements.playSong(index));
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
            ipc.send('show-song-context-menu', song);
        });
        elements.musicList.appendChild(songItem);
    });
}

export function renderAlbumView() {
    elements.albumGrid.innerHTML = '';
    for (const [key, album] of state.albums.entries()) {
        const albumItem = document.createElement('div');
        albumItem.className = 'album-grid-item';
        albumItem.innerHTML = `
            <img src="${album.artwork || ''}" class="album-artwork" alt="${album.title}">
            <div class="album-title">${album.title || 'Unknown Album'}</div>
            <div class="album-artist">${album.artist || 'Unknown Artist'}</div>
        `;
        elements.albumGrid.appendChild(albumItem);
    }
}

export function renderPlaylistView() {
    elements.playlistGrid.innerHTML = '';
    if (!state.playlists || state.playlists.length === 0) {
        elements.playlistGrid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
        return;
    }
    for (const name of state.playlists) {
        const playlistItem = document.createElement('div');
        playlistItem.className = 'playlist-grid-item';
        playlistItem.innerHTML = `
            <div class="playlist-icon">🎵</div>
            <div class="playlist-title">${name}</div>
        `;
        playlistItem.addEventListener('click', () => {
            elements.showPlaylist(name);
        });
        elements.playlistGrid.appendChild(playlistItem);
    }
}

export function renderPlaylistDetailView(playlistName, songs) {
    const header = document.querySelector('#playlist-detail-view .playlist-detail-header');
    header.querySelector('#p-detail-title').textContent = playlistName;

    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    header.querySelector('#p-detail-meta').textContent = `${songs.length} 曲, ${formatTime(totalDuration)}`;

    const collageImgs = header.querySelectorAll('.collage-img');
    for (let i = 0; i < 4; i++) {
        collageImgs[i].src = songs[i]?.artwork || '';
    }

    const listElement = document.getElementById('p-detail-list');
    listElement.innerHTML = '';
    songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = state.currentlyVisibleSongs === songs && state.currentSongIndex === index;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => elements.playSong(index, songs));
        
        const artworkSrc = song.artwork || '';
        songItem.innerHTML = `
            <div class="song-index">${index + 1}</div>
            <div class="song-title">
                <img src="${artworkSrc}" class="artwork-small" alt="artwork">
                <span>${song.title}</span>
            </div>
            <div class="song-artist">${song.artist}</div>
            <div class="song-album">${song.album}</div>
            <div class="song-duration">${formatTime(song.duration || 0)}</div>
            <div class="song-file-size">${(song.fileSize / 1024 / 1024).toFixed(1)} MB</div>
            <div class="song-year">${song.year || '-'}</div>
            <div class="song-play-count">${state.playCounts[song.path] || 0}</div>
        `;
        listElement.appendChild(songItem);
    });
}

function formatTime(seconds) {
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}