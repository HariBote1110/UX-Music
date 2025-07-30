import { elements } from '../state.js';
import { setEqualizerColorFromArtwork } from '../player.js';
const { ipcRenderer } = require('electron');

function getYoutubeVideoId(url) {
    if (typeof url !== 'string') return null;
    const regExp = /^.*(https?:\/\/)?(www\.)?(youtube\.com|youtu\.?be)\/.+$/;
    if(!regExp.test(url)) return null;
    const match = url.match(/(?:\/|v=)([\w-]{11}).*/);
    return match ? match[1] : null;
}

// ▼▼▼ 変更点：関数を同期的(sync)に書き換え ▼▼▼
function resolveArtworkPath(artwork, isThumbnail = false) {
    if (!state.artworksDir) {
        console.error("resolveArtworkPath called before state.artworksDir was set.");
        return './assets/default_artwork.png';
    }
    
    if (!artwork) return './assets/default_artwork.png';

    if (typeof artwork === 'string' && (artwork.startsWith('data:image') || artwork.startsWith('http'))) {
        return artwork;
    }
    
    if (typeof artwork === 'object' && artwork.full && artwork.thumbnail) {
        const fileName = isThumbnail ? artwork.thumbnail : artwork.full;
        const subDir = isThumbnail ? 'thumbnails' : '';
        return `file://${state.artworksDir}/${subDir ? `${subDir}/` : ''}${fileName}`;
    }

    if (typeof artwork === 'string') {
        return `file://${state.artworksDir}/${artwork}`;
    }

    return './assets/default_artwork.png';
}
// ▲▲▲ 変更点ここまで ▲▲▲

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
    
    } else if (song.type === 'youtube') {
        nowPlayingArtworkContainer.classList.add('video-mode');
        const videoId = getYoutubeVideoId(song.sourceURL || song.path);
        if (videoId) {
            const iframe = document.createElement('iframe');
            iframe.width = '100%';
            iframe.height = '100%';
            iframe.src = `https://www.youtube.com/iframe_api/${videoId}?autoplay=1&controls=0&fs=0&iv_load_policy=3&modestbranding=1&origin=${window.location.href}`;
            iframe.setAttribute('frameborder', '0');
            nowPlayingArtworkContainer.appendChild(iframe);
        }
        const img = new Image();
        img.onload = setEqualizerColorFromArtwork;
        img.src = song.artwork;

    } else {
        const localPlayer = document.getElementById('main-player');
        const img = document.createElement('img');
        
        img.onload = setEqualizerColorFromArtwork;

        // ▼▼▼ 変更点：非同期処理(.then)を削除 ▼▼▼
        const album = state.albums.get(song.albumKey);
        const artwork = album ? album.artwork : null;
        img.src = resolveArtworkPath(artwork, false);
        // ▲▲▲ 変更点ここまで ▲▲▲

        if (song.hasVideo) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            nowPlayingArtworkContainer.appendChild(localPlayer);
        } else {
            nowPlayingArtworkContainer.classList.remove('video-mode');
            nowPlayingArtworkContainer.appendChild(img);
        }
        if (img.complete) setEqualizerColorFromArtwork();
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