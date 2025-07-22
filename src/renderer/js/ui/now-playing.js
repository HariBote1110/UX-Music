import { elements } from '../state.js';
const { ipcRenderer } = require('electron');

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