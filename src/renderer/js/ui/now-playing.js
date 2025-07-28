import { elements } from '../state.js';
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

    if (!song) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        previewContainer.appendChild(img);
    } else if (song.type === 'youtube') {
        previewContainer.classList.add('video-mode');
        previewContainer.appendChild(ytPlayerWrapper);
    } else if (song.hasVideo) {
        previewContainer.classList.add('video-mode');
        localPlayer.style.display = 'block';
        previewContainer.appendChild(localPlayer);
    } else {
        previewContainer.classList.remove('video-mode'); 
        const img = document.createElement('img');
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

    // ▼▼▼ ここからが修正箇所です ▼▼▼
    elements.nowPlayingTitle.querySelector('span').textContent = song ? song.title : '曲を選択してください';
    elements.nowPlayingArtist.querySelector('span').textContent = song ? song.artist : '';
    // ▲▲▲ ここまでが修正箇所です ▲▲▲
}