// uxmusic/src/renderer/js/ui-manager.js

import { state, elements } from './state.js';
import { playSong } from './playback-manager.js';
import { createQueueItem } from './ui/element-factory.js';
import { showView } from './navigation.js'; 
import { setAudioOutput, setVisualizerTarget } from './player.js';
const { ipcRenderer } = require('electron');

/**
 * 現在アクティブなビューの内容を再描画する
 */
export function renderCurrentView() {
    // ▼▼▼ ログ追加 ▼▼▼
    console.log('[Logger] 5-A. renderCurrentView() が呼び出されました。これはUI全体を再描画するため、スクロールがリセットされる可能性があります。');
    showView(state.activeViewId, state.currentDetailView);
    renderQueueView();
}

/**
 * 再生中の曲の表示（ハイライトやイコライザー）を更新する
 */
export function updatePlayingIndicators() {
    // ▼▼▼ ログ追加 ▼▼▼
    console.log('[Logger] 5-B. updatePlayingIndicators() が呼び出されました。');
    
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];

    // 古い再生中アイテムのハイライトを解除
    const oldPlayingItems = document.querySelectorAll('.main-content .song-item.playing');
    oldPlayingItems.forEach(item => item.classList.remove('playing'));

    // 新しい再生中アイテムをハイライト
    if (currentPlayingSong) {
        try {
            const safePath = CSS.escape(currentPlayingSong.path);
            const newPlayingItem = document.querySelector(`.main-content .song-item[data-song-path="${safePath}"]`);
            if (newPlayingItem) {
                newPlayingItem.classList.add('playing');
                setVisualizerTarget(newPlayingItem);
            }
        } catch (e) {
            console.error('Error selecting song item:', e);
        }
    } else {
        setVisualizerTarget(null);
    }
    
    // 再生キューの表示も更新
    renderQueueView();
}


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
    window.observeNewArtworks(elements.queueList);
}

export function initUI() {
    elements.sidebarTabs.forEach(tab => {
        tab.addEventListener('click', () => {
            elements.sidebarTabs.forEach(t => t.classList.remove('active'));
            elements.sidebarTabContents.forEach(c => c.classList.remove('active'));
            tab.classList.add('active');
            document.getElementById(tab.dataset.tab).classList.add('active');
            renderQueueView();
        });
    });
}

export function addSongsToLibrary({ songs, albums }) {
    console.time('Renderer: Process Library Data');
    let migrationNeeded = false;
    if ((!albums || Object.keys(albums).length === 0) && songs.length > 0 && songs[0].artwork) {
        migrationNeeded = true;
        state.albums.clear(); 
    } else if (albums) {
        state.albums = new Map(Object.entries(albums));
    }
    if (songs && songs.length > 0) {
        const existingPaths = new Set(state.library.map(song => song.path));
        const uniqueNewSongs = songs.filter(song => !existingPaths.has(song.path));
        state.library.push(...uniqueNewSongs);
    }
    groupLibraryByAlbum(migrationNeeded);
    groupLibraryByArtist();
    if (migrationNeeded) {
        const albumsToSave = Object.fromEntries(state.albums.entries());
        ipcRenderer.send('save-migrated-data', { songs: state.library, albums: albumsToSave });
    }
    renderCurrentView();
    console.timeEnd('Renderer: Process Library Data');
}

function groupLibraryByAlbum(isMigration = false) {
    console.time('Renderer: groupLibraryByAlbum');
    const tempAlbumGroups = new Map();
    const localSongs = state.library.filter(song => !song.sourceURL);
    localSongs.forEach(song => {
        const albumTitle = song.album || 'Unknown Album';
        const albumArtistsSet = new Set([song.albumartist, song.artist].filter(Boolean));
        let representativeArtist = 'Unknown Artist';
        if (albumArtistsSet.size > 0) {
            representativeArtist = [...albumArtistsSet][0];
        }
        const albumKey = `${albumTitle}---${representativeArtist}`;
        song.albumKey = albumKey;
        if (!tempAlbumGroups.has(albumKey)) {
            tempAlbumGroups.set(albumKey, {
                title: albumTitle,
                artist: representativeArtist,
                songs: [],
                artwork: isMigration && song.artwork ? song.artwork : null 
            });
        }
        tempAlbumGroups.get(albumKey).songs.push(song);
    });
    for (const [key, albumData] of tempAlbumGroups.entries()) {
        if (!state.albums.has(key)) {
            if (!albumData.artwork) {
                albumData.artwork = albumData.songs.find(s => s.artwork)?.artwork || null;
            }
            state.albums.set(key, albumData);
        }
    }
    if (isMigration) {
        state.library.forEach(song => {
            delete song.artwork;
        });
    }
    console.timeEnd('Renderer: groupLibraryByAlbum');
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
        const firstAlbumKey = songs[0]?.albumKey;
        const representativeAlbum = state.albums.get(firstAlbumKey);
        state.artists.set(artistName, {
            name: artistName,
            artwork: representativeAlbum?.artwork || null,
            songs: songs
        });
    }
}

export async function updateAudioDevices(savedDeviceId = null) {
    try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const audioDevices = devices.filter(device => device.kind === 'audiooutput');
        elements.devicePopup.innerHTML = '';
        const mainPlayer = document.getElementById('main-player');
        if (!mainPlayer) return;
        const currentSinkId = mainPlayer.sinkId || 'default';
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
                elements.devicePopup.querySelectorAll('.device-popup-item').forEach(i => i.classList.remove('active'));
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