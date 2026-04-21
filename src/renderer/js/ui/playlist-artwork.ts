// @ts-nocheck
// uxmusic/src/renderer/js/ui/playlist-artwork.js

import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';

// ▼▼▼ ここからが修正箇所です ▼▼▼
function createPlaylistArtwork(container, artworks, resolver) {
    container.innerHTML = '';
    container.classList.remove('grid-collage');

    const defaultImgSrc = DEFAULT_ARTWORK_URL;

    if (!resolver) {
        console.error('createPlaylistArtwork was called without a resolver function, which is required.');
        const img = document.createElement('img');
        img.src = defaultImgSrc;
        container.appendChild(img);
        return;
    }

    if (!artworks || artworks.length === 0) {
        const img = document.createElement('img');
        img.src = defaultImgSrc;
        container.appendChild(img);
    } else if (artworks.length < 4) {
        const img = document.createElement('img');
        img.src = resolver(artworks[0]);
        container.appendChild(img);
    } else {
        container.classList.add('grid-collage');
        for (let i = 0; i < 4; i++) {
            const imgWrapper = document.createElement('div');
            imgWrapper.className = 'collage-img-wrapper';
            const img = document.createElement('img');
            img.src = resolver(artworks[i]);
            imgWrapper.appendChild(img);
            container.appendChild(imgWrapper);
        }
    }
}

export { createPlaylistArtwork };
// ▲▲▲ ここまでが修正箇所です ▲▲▲
