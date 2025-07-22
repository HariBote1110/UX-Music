import { state, elements } from './state.js';
import { renderTrackView, renderAlbumView, renderArtistView, renderPlaylistView } from './ui/view-renderer.js';
import { renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView } from './ui/detail-view-renderer.js';
const { ipcRenderer } = require('electron');

export function initUI() {
    // UI初期化（必要であれば）
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
        const artistName = song.artist || 'Unknown Artist';
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
        const pDetail = document.getElementById('playlist-detail-view');
        const aDetail = document.getElementById('album-detail-view');
        const artistDetail = document.getElementById('artist-detail-view');
        if (!pDetail.classList.contains('hidden')) {
             renderPlaylistDetailView(pDetail.querySelector('#p-detail-title').textContent, state.originalQueueSource);
        } else if (!aDetail.classList.contains('hidden')) {
             const album = state.albums.get(aDetail.dataset.albumKey);
             if (album) renderAlbumDetailView(album);
        } else if (!artistDetail.classList.contains('hidden')) {
            const artist = state.artists.get(artistDetail.dataset.artistName);
            if (artist) renderArtistDetailView(artist);
        }
    }
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