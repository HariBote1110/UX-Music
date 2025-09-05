import { state, elements } from '../state.js';
import { setEqualizerColorFromArtwork } from '../player.js';
import { resolveArtworkPath, formatSongTitle } from './utils.js';
const { ipcRenderer } = require('electron');

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
        setEqualizerColorFromArtwork(img);
    
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

        // ▼▼▼ ここからが修正箇所です ▼▼▼
        // どんなsongオブジェクトでもファイルパスを元にstate.libraryから完全な楽曲情報を検索
        const masterSong = state.library.find(s => s.path === song.path) || song;
        const album = state.albums.get(masterSong.albumKey);
        
        // 楽曲自身のアートワーク(YouTubeなど)を優先し、なければアルバムのアートワークを使用
        const artwork = masterSong.artwork || (album ? album.artwork : null);

        img.src = resolveArtworkPath(artwork, false);

        // 映像の有無はmasterSongの情報で判定する
        if (masterSong.hasVideo && localPlayer) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            localPlayer.poster = img.src;
            localPlayer.style.display = 'block';
            nowPlayingArtworkContainer.appendChild(localPlayer);
        } else {
            nowPlayingArtworkContainer.classList.remove('video-mode');
            nowPlayingArtworkContainer.appendChild(img);
        }
        // ▲▲▲ ここまでが修正箇所です ▲▲▲
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
        titleSpan.textContent = song ? formatSongTitle(song.title) : '曲を選択してください';
    }

    const artistSpan = nowPlayingArtist.querySelector('.marquee-content span');
    if (artistSpan) {
        artistSpan.textContent = song ? song.artist : '';
    }
}