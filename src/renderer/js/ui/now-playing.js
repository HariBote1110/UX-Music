import { elements } from '../state.js';
import { setEqualizerColorFromArtwork } from '../player.js'; // 修正箇所
const { ipcRenderer } = require('electron');
const path = require('path');

let artworksDir = null;

async function resolveArtworkPath(artworkFileName) {
    if (!artworkFileName) return './assets/default_artwork.png';
    
    if (artworkFileName.startsWith('data:image')) return artworkFileName;
    if (artworkFileName.startsWith('http')) return artworkFileName;
    
    if (!artworksDir) {
        artworksDir = await ipcRenderer.invoke('get-artworks-dir');
    }
    return `file://${path.join(artworksDir, artworkFileName)}`;
}

export async function updateNowPlayingView(song) {
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

    const img = document.createElement('img');
    // ▼▼▼ ここからが修正箇所です ▼▼▼
    // 画像の読み込みが完了したタイミングで色を設定する
    img.onload = () => {
        setEqualizerColorFromArtwork();
    };
    // ▲▲▲ ここまでが修正箇所です ▲▲▲

    if (!song) {
        img.src = './assets/default_artwork.png';
        previewContainer.appendChild(img);
    } else if (song.type === 'youtube') {
        previewContainer.classList.add('video-mode');
        previewContainer.appendChild(ytPlayerWrapper);
        // YouTubeの場合はサムネイルから色を取得
        img.src = song.artwork;
    } else if (song.hasVideo) {
        previewContainer.classList.add('video-mode');
        localPlayer.style.display = 'block';
        previewContainer.appendChild(localPlayer);
        // 映像ありの場合もアートワークから色を取得
        img.src = await resolveArtworkPath(song.artwork);
    } else {
        previewContainer.classList.remove('video-mode'); 
        img.src = await resolveArtworkPath(song.artwork);
        previewContainer.appendChild(img);
    }
    
    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => ipcRenderer.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    const titleSpan = elements.nowPlayingTitle.querySelector('.marquee-content span');
    if (titleSpan) {
        titleSpan.textContent = song ? song.title : '曲を選択してください';
    }

    const artistSpan = elements.nowPlayingArtist.querySelector('.marquee-content span');
    if (artistSpan) {
        artistSpan.textContent = song ? song.artist : '';
    }
    
    // 画像が既にキャッシュされている場合も考慮して、手動で呼び出す
    if (img.complete) {
        setEqualizerColorFromArtwork();
    }
}