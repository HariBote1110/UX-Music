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
    const hubLinkContainer = document.getElementById('hub-link-container'); // ★ ボタンのコンテナを取得

    // --- 表示をリセット ---
    previewContainer.innerHTML = '';
    hubLinkContainer.innerHTML = ''; // ★ コンテナの中身もリセット
    previewContainer.classList.remove('video-mode');
    document.body.appendChild(localPlayer);
    document.body.appendChild(ytPlayerWrapper);
    localPlayer.style.display = 'none';

    // --- 曲情報に基づいてUIを更新 ---
    if (!song) {
        // 曲がない場合
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        previewContainer.appendChild(img);

    } else if (song.type === 'youtube') {
        // YouTubeストリーミングの場合
        previewContainer.classList.add('video-mode');
        previewContainer.appendChild(ytPlayerWrapper);
    } else if (song.type === 'local' && song.path && song.path.toLowerCase().endsWith('.mp4')) {
        // ダウンロード済みの動画ファイルの場合
        previewContainer.classList.add('video-mode');
        localPlayer.style.display = 'block';
        previewContainer.appendChild(localPlayer);
    } else {
        // それ以外のローカルファイル
        const img = document.createElement('img');
        img.src = song.artwork || './assets/default_artwork.png';
        previewContainer.appendChild(img);
    }
    
    // ★★★ ここからがハブリンクボタンの表示ロジックです ★★★
    if (song && song.hubUrl) {
        // hubUrlがあればボタンを作成して表示
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => {
            ipc.send('open-external-link', song.hubUrl);
        });
        hubLinkContainer.appendChild(hubButton);
    }
    // ★★★ ここまで ★★★


    // 曲名とアーティストの更新 (変更なし)
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
            ipc.send('show-song-context-menu-in-library', song); 
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

// プレイリスト一覧ビューの描画を修正
export function renderPlaylistView() {
    elements.playlistGrid.innerHTML = '';
    if (!state.playlists || state.playlists.length === 0) {
        elements.playlistGrid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
        return;
    }

    for (const playlist of state.playlists) {
        const playlistItem = document.createElement('div');
        playlistItem.className = 'playlist-grid-item';
        playlistItem.innerHTML = `
            <div class="playlist-artwork-container"></div>
            <div class="playlist-title">${playlist.name}</div>
        `;

        const artworkContainer = playlistItem.querySelector('.playlist-artwork-container');
        createPlaylistArtwork(artworkContainer, playlist.artworks); // ヘルパー関数を呼び出し

        playlistItem.addEventListener('click', () => {
            elements.showPlaylist(playlist.name);
        });
        elements.playlistGrid.appendChild(playlistItem);
    }
}

export function renderPlaylistDetailView(playlistName, songs) {
    const header = document.querySelector('#playlist-detail-view .playlist-detail-header');
    
    // ヘッダー情報
    header.querySelector('#p-detail-title').textContent = playlistName;
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    header.querySelector('#p-detail-meta').textContent = `${songs.length} 曲, ${formatTime(totalDuration)}`;

    // アートワークコラージュ
    const artworkContainer = header.querySelector('.playlist-art-collage');
    const artworks = songs.map(s => s.artwork).filter(Boolean);
    createPlaylistArtwork(artworkContainer, artworks); // ヘルパー関数を呼び出し

    // 曲リスト本体
    const listElement = document.getElementById('p-detail-list');
    listElement.innerHTML = ''; // 中身をクリア
    songs.forEach((song, index) => {
        const songItem = document.createElement('div');
        const isPlaying = state.currentlyVisibleSongs === songs && state.currentSongIndex === index;
        songItem.className = `song-item ${isPlaying ? 'playing' : ''}`;
        songItem.addEventListener('click', () => elements.playSong(index, songs));
                // ★★★ 以下の contextmenu イベントリスナーを新規追加 ★★★
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            // メインプロセスにコンテキストメニューの表示を要求
            ipc.send('show-playlist-song-context-menu', { playlistName, song });
        });

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
// ★★★ 新規: プレイリストのコラージュを生成するヘルパー関数 ★★★
function createPlaylistArtwork(container, artworks) {
    container.innerHTML = ''; // 中身をクリア

    if (!artworks || artworks.length === 0) {
        // 曲がない場合
        container.classList.remove('grid-collage');
        container.innerHTML = `<div class="playlist-icon-large">🎵</div>`;
    } else if (artworks.length < 4) {
        // 1〜3曲の場合: 最初の1曲のジャケットを大きく表示
        container.classList.remove('grid-collage');
        const img = document.createElement('img');
        img.src = artworks[0];
        container.appendChild(img);
    } else {
        // 4曲以上の場合: 4曲のグリッドコラージュを表示
        container.classList.add('grid-collage');
        for (let i = 0; i < 4; i++) {
            const wrapper = document.createElement('div');
            wrapper.classList.add('collage-img-wrapper');

            const img = document.createElement('img');
            img.src = artworks[i];

            wrapper.appendChild(img);
            container.appendChild(wrapper);
        }
    }
}


function formatTime(seconds) {
    const min = Math.floor(seconds / 60);
    const sec = Math.floor(seconds % 60).toString().padStart(2, '0');
    return `${min}:${sec}`;
}