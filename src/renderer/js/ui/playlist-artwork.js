// uxmusic/src/renderer/js/ui/playlist-artwork.js

export function createPlaylistArtwork(container, artworks, resolver) { // resolverを受け取るように引数を変更
    container.innerHTML = '';
    container.classList.remove('grid-collage');

    // ▼▼▼ ここからが修正箇所です ▼▼▼
    const defaultImgSrc = './assets/default_artwork.png';

    if (!artworks || artworks.length === 0) {
        const img = document.createElement('img');
        img.src = defaultImgSrc;
        container.appendChild(img);
    } else if (artworks.length < 4) {
        const img = document.createElement('img');
        // resolverが提供されていれば使い、なければartworks[0]をそのまま使う
        img.src = resolver ? resolver(artworks[0]) : artworks[0];
        container.appendChild(img);
    } else {
        container.classList.add('grid-collage');
        for (let i = 0; i < 4; i++) {
            const imgWrapper = document.createElement('div');
            imgWrapper.className = 'collage-img-wrapper';
            const img = document.createElement('img');
            // resolverが提供されていれば使い、なければartworks[i]をそのまま使う
            img.src = resolver ? resolver(artworks[i]) : artworks[i];
            imgWrapper.appendChild(img);
            container.appendChild(imgWrapper);
        }
    }
    // ▲▲▲ ここまでが修正箇所です ▲▲▲
}