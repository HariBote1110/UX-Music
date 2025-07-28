import { state, elements } from './state.js';
import { renderTrackView, renderAlbumView, renderArtistView, renderPlaylistView } from './ui/view-renderer.js';
import { renderAlbumDetailView, renderArtistDetailView, renderPlaylistDetailView } from './ui/detail-view-renderer.js';
import { playSong } from './playback-manager.js';
import { setAudioOutput } from './player.js'; // player.jsから関数をインポート
import { createQueueItem } from './ui/element-factory.js';
import { updateTextOverflowForSelector } from './ui/utils.js';
const { ipcRenderer } = require('electron');

const MARQUEE_SELECTOR = '.marquee-wrapper';

function renderQueueView() {
    elements.queueList.innerHTML = '';
    if (state.playbackQueue.length === 0) {
        elements.queueList.innerHTML = '<p class="no-lyrics">再生キューは空です</p>';
        return;
    }

    state.playbackQueue.forEach((song, index) => {
        const isPlaying = index === state.currentSongIndex;
        const queueItem = createQueueItem(song, isPlaying, ipcRenderer);
        queueItem.addEventListener('click', () => playSong(index));
        elements.queueList.appendChild(queueItem);
    });
}

export function initUI() {
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
    const localSongs = state.library.filter(song => !song.sourceURL);

    localSongs.forEach(song => {
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
    const localSongs = state.library.filter(song => !song.sourceURL);

    localSongs.forEach(song => {
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
    renderQueueView();
    updateTextOverflowForSelector(MARQUEE_SELECTOR);
}

// ▼▼▼ ここからが修正箇所です ▼▼▼
export async function updateAudioDevices(savedDeviceId = null) {
    try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const audioDevices = devices.filter(device => device.kind === 'audiooutput');
        
        elements.devicePopup.innerHTML = '';
        const currentSinkId = document.getElementById('main-player').sinkId || 'default';
        
        audioDevices.forEach(device => {
            const item = document.createElement('div');
            item.className = 'device-popup-item';
            item.textContent = device.label || `スピーカー ${elements.devicePopup.children.length + 1}`;
            item.dataset.deviceId = device.deviceId;

            if (device.deviceId === currentSinkId || (currentSinkId === 'default' && device.deviceId === 'default')) {
                item.classList.add('active');
            }

            item.addEventListener('click', () => {
                setAudioOutput(device.deviceId);
                // ポップアップ内のすべてのactiveクラスを削除
                elements.devicePopup.querySelectorAll('.device-popup-item').forEach(i => i.classList.remove('active'));
                // クリックされたアイテムにactiveクラスを追加
                item.classList.add('active');
                elements.devicePopup.classList.remove('active');
            });
            elements.devicePopup.appendChild(item);
        });

        if (savedDeviceId && audioDevices.some(d => d.deviceId === savedDeviceId)) {
             setAudioOutput(savedDeviceId);
        }

    } catch (error) {
        console.error('オーディオデバイスの取得に失敗しました:', error);
    }
}
// ▲▲▲ ここまでが修正箇所です ▲▲▲