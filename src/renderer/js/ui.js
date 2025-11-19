import { state, elements } from './state.js';
import { setupSongListScroller } from './ui/list-renderer.js';
import { resolveArtworkPath, formatSongTitle } from './ui/utils.js';
import { setEqualizerColorFromArtwork } from './player.js'; // 必要に応じて
const { ipcRenderer } = require('electron');

export function initUI() {
    // UI初期化ロジックがあればここに記述
}

let currentSearchQuery = '';

export function updateSearchQuery(query) {
    currentSearchQuery = query.toLowerCase().trim();
    // トラックビューが表示されている場合のみ再描画
    if (state.activeViewId === 'track-view') {
        renderTrackView();
    }
}

function getYoutubeVideoId(url) {
    if (typeof url !== 'string') return null;
    const regExp = /(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/ ]{11})/;
    const match = url.match(regExp);
    return match ? match[1] : null;
}

export function updateNowPlayingView(song) {
    const { 
        nowPlayingArtworkContainer, 
        nowPlayingTitle, 
        nowPlayingArtist,
        hubLinkContainer 
    } = elements;
    
    const localPlayer = document.getElementById('main-player');

    if (localPlayer) {
        document.body.appendChild(localPlayer);
        localPlayer.style.display = 'none';
    }
    
    nowPlayingArtworkContainer.innerHTML = '';
    hubLinkContainer.innerHTML = '';
    nowPlayingArtworkContainer.classList.remove('video-mode');

    if (!song) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        nowPlayingArtworkContainer.appendChild(img);
        setEqualizerColorFromArtwork(img); // player.jsからインポートが必要、あるいはutils等へ移動推奨
    
    } else if (song.type === 'youtube') {
        nowPlayingArtworkContainer.classList.add('video-mode');
        const videoId = getYoutubeVideoId(song.sourceURL || song.path);
        if (videoId) {
            const iframe = document.createElement('iframe');
            iframe.width = '100%';
            iframe.height = '100%';
            iframe.src = `https://www.youtube.com/embed/${videoId}?autoplay=1&controls=0&fs=0&iv_load_policy=3&modestbranding=1&origin=${window.location.protocol}//${window.location.host}`;
            iframe.setAttribute('frameborder', '0');
            iframe.setAttribute('allow', 'autoplay; encrypted-media');
            nowPlayingArtworkContainer.appendChild(iframe);
        }
        
        const artworkImage = new Image();
        artworkImage.crossOrigin = "Anonymous";
        artworkImage.onload = () => setEqualizerColorFromArtwork(artworkImage);
        artworkImage.src = song.artwork;

    } else {
        const img = document.createElement('img');
        img.crossOrigin = "Anonymous";
        img.onload = () => setEqualizerColorFromArtwork(img);

        // アートワークパスの解決（ここが以前のエラー箇所でした）
        // resolveArtworkPath を使うことでオブジェクト形式も正しく処理されます
        const masterSong = state.library.find(s => s.path === song.path) || song;
        const album = state.albums.get(masterSong.albumKey);
        
        let artwork;
        if (masterSong.album === 'Unknown Album' || (album && album.title === 'Unknown Album')) {
            artwork = null;
        } else {
            artwork = masterSong.artwork || (album ? album.artwork : null);
        }

        img.src = resolveArtworkPath(artwork, false);

        if (masterSong.hasVideo && localPlayer) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            localPlayer.poster = img.src;
            localPlayer.style.display = 'block';
            nowPlayingArtworkContainer.appendChild(localPlayer);
        } else {
            nowPlayingArtworkContainer.classList.remove('video-mode');
            nowPlayingArtworkContainer.appendChild(img);
        }
    }
    
    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => ipcRenderer.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    // state.js の修正に合わせて、querySelector で span を探す
    const titleEl = nowPlayingTitle.querySelector('.marquee-content span') || nowPlayingTitle;
    if (titleEl) {
        titleEl.textContent = song ? formatSongTitle(song.title) : '曲を選択してください';
    }

    const artistEl = nowPlayingArtist.querySelector('.marquee-content span') || nowPlayingArtist;
    if (artistEl) {
        artistEl.textContent = song ? song.artist : '';
    }
}

export function renderTrackView() {
    // 1. 検索クエリに基づいてリストをフィルタリング
    let displaySongs = state.library;
    if (currentSearchQuery) {
        displaySongs = state.library.filter(song => {
            const targetText = (
                (song.title || '') + 
                (song.artist || '') + 
                (song.album || '')
            ).toLowerCase();
            return targetText.includes(currentSearchQuery);
        });
    }

    elements.musicList.innerHTML = ''; // コンテナをクリア
    
    if (displaySongs.length === 0) {
        elements.musicList.innerHTML = '<div class="placeholder">検索結果が見つかりません</div>';
        return;
    }

    // 2. VirtualScroller (list-renderer.js) を使用して描画
    // これにより大量の曲でも高速に表示され、アートワークの処理も正しく行われます
    setupSongListScroller(elements.musicList, displaySongs, {
        contextView: 'track-view'
    });
}