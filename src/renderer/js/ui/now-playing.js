import { state, elements } from '../state.js';
import { setEqualizerColorFromArtwork } from '../player.js';
const { ipcRenderer } = require('electron');
const path = require('path');

function getYoutubeVideoId(url) {
    if (typeof url !== 'string') return null;
    const regExp = /(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/ ]{11})/;
    const match = url.match(regExp);
    return match ? match[1] : null;
}

function resolveArtworkPath(artwork, isThumbnail = false) {
    if (!artwork) return './assets/default_artwork.png';

    if (typeof artwork === 'string' && (artwork.startsWith('http') || artwork.startsWith('data:'))) {
        return artwork;
    }
    
    if (typeof artwork === 'object' && artwork.full && artwork.thumbnail) {
        const fileName = isThumbnail ? artwork.thumbnail : artwork.full;
        const subDir = isThumbnail ? 'thumbnails' : '';
        const safePath = path.join(subDir, fileName).replace(/\\/g, '/');
        return `safe-artwork://${safePath}`;
    }
    
    if (typeof artwork === 'string') {
        return `safe-artwork://${artwork.replace(/\\/g, '/')}`;
    }
    
    return './assets/default_artwork.png';
}

export function updateNowPlayingView(song) {
    const { 
        nowPlayingArtworkContainer, 
        nowPlayingTitle, 
        nowPlayingArtist,
        hubLinkContainer 
    } = elements;
    
    nowPlayingArtworkContainer.innerHTML = '';
    hubLinkContainer.innerHTML = '';
    nowPlayingArtworkContainer.classList.remove('video-mode');

    if (!song) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        nowPlayingArtworkContainer.appendChild(img);
        setEqualizerColorFromArtwork(img); // デフォルト色にリセット
    
    } else if (song.type === 'youtube') {
        nowPlayingArtworkContainer.classList.add('video-mode');
        const videoId = getYoutubeVideoId(song.sourceURL || song.path);
        if (videoId) {
            const iframe = document.createElement('iframe');
            iframe.width = '100%';
            iframe.height = '100%';
            iframe.src = `http://googleusercontent.com/youtube.com/8{videoId}?autoplay=1&controls=0&fs=0&iv_load_policy=3&modestbranding=1&origin=${window.location.protocol}//${window.location.host}`;
            iframe.setAttribute('frameborder', '0');
            iframe.setAttribute('allow', 'autoplay; encrypted-media');
            nowPlayingArtworkContainer.appendChild(iframe);
        }
        
        // ▼▼▼ 修正点 ▼▼▼
        const artworkImage = new Image();
        artworkImage.crossOrigin = "Anonymous";
        artworkImage.onload = () => setEqualizerColorFromArtwork(artworkImage); // 読み込み完了時に色抽出
        artworkImage.src = song.artwork;
        // ▲▲▲ ▲▲▲

    } else {
        const localPlayer = document.getElementById('main-player');
        const img = document.createElement('img');
        
        // ▼▼▼ 修正点 ▼▼▼
        img.onload = () => setEqualizerColorFromArtwork(img); // 読み込み完了時に色抽出
        // ▲▲▲ ▲▲▲

        const album = state.albums.get(song.albumKey);
        const artwork = album ? album.artwork : null;
        img.src = resolveArtworkPath(artwork, false);

        if (song.hasVideo) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            localPlayer.poster = img.src; // video要素のポスターとしてアートワークを設定
            nowPlayingArtworkContainer.appendChild(localPlayer);
        } else {
            nowPlayingArtworkContainer.classList.remove('video-mode');
            nowPlayingArtworkContainer.appendChild(img);
        }
        
        if (img.complete) setEqualizerColorFromArtwork(img);
    }
    
    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => ipcRenderer.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    const titleSpan = nowPlayingTitle.querySelector('.marquee-content span');
    if (titleSpan) {
        titleSpan.textContent = song ? song.title : '曲を選択してください';
    }

    const artistSpan = nowPlayingArtist.querySelector('.marquee-content span');
    if (artistSpan) {
        artistSpan.textContent = song ? song.artist : '';
    }
}