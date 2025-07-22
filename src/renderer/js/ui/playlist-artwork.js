export function createPlaylistArtwork(container, artworks) {
    container.innerHTML = '';
    container.classList.remove('grid-collage');

    if (!artworks || artworks.length === 0) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        container.appendChild(img);
    } else if (artworks.length < 4) {
        const img = document.createElement('img');
        img.src = artworks[0];
        container.appendChild(img);
    } else {
        container.classList.add('grid-collage');
        for (let i = 0; i < 4; i++) {
            const imgWrapper = document.createElement('div');
            imgWrapper.className = 'collage-img-wrapper';
            const img = document.createElement('img');
            img.src = artworks[i];
            imgWrapper.appendChild(img);
            container.appendChild(imgWrapper);
        }
    }
}