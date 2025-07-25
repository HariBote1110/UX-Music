import { state, elements } from './state.js';
import { renderTrackView, renderAlbumView, renderArtistView, renderPlaylistView } from './ui/view-renderer.js';
import { renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView } from './ui/detail-view-renderer.js';
import { playSong } from './playback-manager.js'; // ★★★ playSongをインポート ★★★
const { ipcRenderer } = require('electron');
const path = require('path'); // ★★★ pathをインポート ★★★

// ★★★ ここからが修正箇所です ★★★
let artworksDir = null; // アートワークディレクトリのパスをキャッシュ

// アートワークのパスを非同期で解決する関数
async function resolveArtworkPath(artworkFileName) {
    if (!artworkFileName) return './assets/default_artwork.png';
    if (artworkFileName.startsWith('http')) return artworkFileName;
    
    if (!artworksDir) {
        artworksDir = await ipcRenderer.invoke('get-artworks-dir');
    }
    return `file://${path.join(artworksDir, artworkFileName)}`;
}

/**
 * 再生キューリストを描画する
 */
function renderQueueView() {
    elements.queueList.innerHTML = '';
    if (state.playbackQueue.length === 0) {
        elements.queueList.innerHTML = '<p class="no-lyrics">再生キューは空です</p>';
        return;
    }

    state.playbackQueue.forEach((song, index) => {
        const queueItem = document.createElement('div');
        const isPlaying = index === state.currentSongIndex;
        queueItem.className = `queue-item ${isPlaying ? 'playing' : ''}`;
        queueItem.dataset.songPath = song.path;
        queueItem.draggable = true;

        queueItem.innerHTML = `
            <img src="./assets/default_artwork.png" class="artwork-small" alt="artwork">
            <div class="queue-item-info">
                <span class="queue-item-title">${song.title}</span>
                <span class="queue-item-artist">${song.artist}</span>
            </div>
        `;
        
        const artworkImg = queueItem.querySelector('.artwork-small');
        resolveArtworkPath(song.artwork).then(src => artworkImg.src = src);

        // クリックでその曲を再生
        queueItem.addEventListener('click', () => playSong(index));

        elements.queueList.appendChild(queueItem);
    });
}
// ★★★ ここまでが修正箇所です ★★★

export function initUI() {
    // ★★★ 右サイドバーのタブ切り替え機能を追加 ★★★
    elements.sidebarTabs.forEach(tab => {
        tab.addEventListener('click', () => {
            elements.sidebarTabs.forEach(t => t.classList.remove('active'));
            elements.sidebarTabContents.forEach(c => c.classList.remove('active'));
            tab.classList.add('active');
            document.getElementById(tab.dataset.tab).classList.add('active');
        });
    });
}

export function addSongsToLibrary(newSongs) {
    if (newSongs && newSongs.length > 0) {
        const existingPaths = new Set(state.library.map(song => song.path));
        const uniqueNewSongs = newSongs.filter(song => !existingPaths.has(song.path));
        state.library.push(...uniqueNewSongs);
    }
    groupLibraryByAlbum();
    groupLibraryByArtist();
    renderCurrentView();
}

function groupLibraryByAlbum() {
    state.albums.clear();
    const tempAlbumGroups = new Map();
    state.library.forEach(song => {
        if (song.type === 'youtube') return;
        const albumTitle = song.album || 'Unknown Album';
        if (!tempAlbumGroups.has(albumTitle)) {
            tempAlbumGroups.set(albumTitle, []);
        }
        tempAlbumGroups.get(albumTitle).push(song);
    });

    for (const [albumTitle, songsInAlbum] of tempAlbumGroups.entries()) {
        const albumArtistsSet = new Set(songsInAlbum.map(s => s.albumartist).filter(Boolean));
        let representativeArtist = 'Unknown Artist';
        if (albumArtistsSet.size > 1) {
            representativeArtist = 'Various Artists';
        } else if (albumArtistsSet.size === 1) {
            representativeArtist = [...albumArtistsSet][0];
        } else {
            const trackArtistsSet = new Set(songsInAlbum.map(s => s.artist));
            if (trackArtistsSet.size > 1) {
                representativeArtist = 'Various Artists';
            } else if (trackArtistsSet.size === 1) {
                representativeArtist = [...trackArtistsSet][0];
            }
        }
        const finalAlbumKey = `${albumTitle}---${representativeArtist}`;
        if (!state.albums.has(finalAlbumKey)) {
            state.albums.set(finalAlbumKey, {
                title: albumTitle,
                artist: representativeArtist,
                artwork: songsInAlbum[0].artwork,
                songs: songsInAlbum
            });
        }
    }
}

function groupLibraryByArtist() {
    state.artists.clear();
    const tempArtistGroups = new Map();

    state.library.forEach(song => {
        const artistName = song.albumartist || song.artist || 'Unknown Artist';
        if (!tempArtistGroups.has(artistName)) {
            tempArtistGroups.set(artistName, []);
        }
        tempArtistGroups.get(artistName).push(song);
    });

    for (const [artistName, songs] of tempArtistGroups.entries()) {
        const artwork = songs.find(s => s.artwork)?.artwork || null;
        state.artists.set(artistName, {
            name: artistName,
            artwork: artwork,
            songs: songs
        });
    }
}

export function renderCurrentView() {
    const activeLink = document.querySelector('.nav-link.active');
    
    if (activeLink) {
        const activeViewId = activeLink.dataset.view;
        if (activeViewId === 'track-view') renderTrackView();
        else if (activeViewId === 'album-view') renderAlbumView();
        else if (activeViewId === 'playlist-view') renderPlaylistView();
        else if (activeViewId === 'artist-view') renderArtistView();
    } else {
        const { type, identifier } = state.currentDetailView;
        if (type === 'playlist') {
             renderPlaylistDetailView(identifier, state.currentlyViewedSongs);
        } else if (type === 'album') {
             const album = state.albums.get(identifier);
             if (album) renderAlbumDetailView(album);
        } else if (type === 'artist') {
            const artist = state.artists.get(identifier);
            if (artist) renderArtistDetailView(artist);
        }
    }
    renderQueueView(); // ★★★ 常に再生キューも再描画 ★★★
}

export async function updateAudioDevices(targetDeviceId = null) {
    const mainPlayer = document.getElementById('main-player');
    const currentSelectedId = elements.audioOutputSelect.value; 

    try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const audioDevices = devices.filter(device => device.kind === 'audiooutput');
        
        elements.audioOutputSelect.innerHTML = '';
        audioDevices.forEach(device => {
            const option = document.createElement('option');
            option.value = device.deviceId;
            option.textContent = device.label || `スピーカー ${elements.audioOutputSelect.options.length + 1}`;
            elements.audioOutputSelect.appendChild(option);
        });

        let deviceIdToSet = null;
        if (targetDeviceId && audioDevices.some(d => d.deviceId === targetDeviceId)) {
            deviceIdToSet = targetDeviceId;
        } else if (audioDevices.some(d => d.deviceId === currentSelectedId)) {
            deviceIdToSet = currentSelectedId;
        } else if (audioDevices.length > 0) {
            deviceIdToSet = audioDevices[0].deviceId;
        }

        if (deviceIdToSet) {
            elements.audioOutputSelect.value = deviceIdToSet;
        }
    } catch (error) {
        console.error('Could not enumerate audio devices:', error);
    }
}