// --- ▼▼▼ 修正: 'getArtworkPath' -> 'resolveArtworkPath' ▼▼▼ ---
import { resolveArtworkPath, showContextMenu } from './utils.js';
// --- ▲▲▲ 修正 ▲▲▲ ---
import { state } from '../state.js';
const { ipcRenderer } = require('electron');

/**
 * 曲リストのアイテム（DOM要素）を作成する
 * @param {object} song - 曲オブジェクト
 * @param {boolean} isPlaying - 現在再生中か
 * @returns {HTMLElement}
 */
export function createSongItem(song, isPlaying) {
    const songItem = document.createElement('div');
    songItem.className = 'song-item';
    songItem.dataset.songPath = song.path;
    songItem.dataset.songId = song.id; 
    
    if (isPlaying) {
        songItem.classList.add('playing');
    }

    // --- ▼▼▼ 修正: 'getArtworkPath' -> 'resolveArtworkPath' ▼▼▼ ---
    const artwork = resolveArtworkPath(song.artwork, true);
    // --- ▲▲▲ 修正 ▲▲▲ ---

    songItem.innerHTML = `
        <div class="song-artwork">
            <img src="${artwork}" data-lazy-src="${artwork}" alt="Artwork" class="lazy-artwork">
        </div>
        <div class="song-info">
            <div class="song-title">${song.title || '不明なタイトル'}</div>
            <div class="song-artist">${song.artist || '不明なアーティスト'}</div>
        </div>
        <div class="song-album">${song.album || ''}</div>
        <div class="song-duration">${song.durationFmt || ''}</div>
        <div class="song-play-count">${state.playCounts[song.path] || 0}</div>
        <div class="song-actions">
            <button class="song-action-btn context-menu-btn" title="その他">︙</button>
        </div>
    `;

    // 右クリック（またはボタンクリック）でコンテキストメニューを表示
    const contextMenuBtn = songItem.querySelector('.context-menu-btn');
    const contextMenuTrigger = (e) => {
        e.preventDefault();
        e.stopPropagation();

        // --- ▼▼▼ MTP機能 (ステップ9で追加済み) ▼▼▼ ---

        // state をチェックし、MTPデバイス（Walkman）が接続されているか確認
        const isMtpDeviceConnected = !!state.mtpDevice;

        ipcRenderer.send('show-context-menu', {
            song: song,
            playlistName: (state.currentView === 'playlist' && state.currentPlaylist) ? state.currentPlaylist : null,
            // MTPデバイスの接続情報と転送に必要なストレージIDを追加
            mtpInfo: {
                isConnected: isMtpDeviceConnected,
                // 転送に必要なストレージIDも渡す (最初のストレージを内部ストレージと仮定)
                storageId: (isMtpDeviceConnected && state.mtpStorages && state.mtpStorages.length > 0) 
                             ? state.mtpStorages[0].Sid 
                             : null
            }
        });
        
        // --- ▲▲▲ MTP機能 (ステップ9で追加済み) ▲▲▲ ---
    };
    
    songItem.addEventListener('contextmenu', contextMenuTrigger);
    contextMenuBtn.addEventListener('click', contextMenuTrigger);

    return songItem;
}

/**
 * 再生キューのアイテム（DOM要素）を作成する
 * @param {object} song - 曲オブジェクト
 * @param {boolean} isPlaying - 現在再生中か
 * @returns {HTMLElement}
 */
export function createQueueItem(song, isPlaying) {
    const queueItem = document.createElement('div');
    queueItem.className = 'queue-item';
    queueItem.dataset.songId = song.id;
    
    if (isPlaying) {
        queueItem.classList.add('playing');
    }

    // --- ▼▼▼ 修正: 'getArtworkPath' -> 'resolveArtworkPath' ▼▼▼ ---
    const artwork = resolveArtworkPath(song.artwork, true);
    // --- ▲▲▲ 修正 ▲▲▲ ---

    queueItem.innerHTML = `
        <div class="queue-item-artwork">
            <img src="${artwork}" data-lazy-src="${artwork}" alt="Artwork" class="lazy-artwork">
        </div>
        <div class="queue-item-info">
            <div class="queue-item-title">${song.title || '不明なタイトル'}</div>
            <div class="queue-item-artist">${song.artist || '不明なアーティスト'}</div>
        </div>
        <button class="queue-item-remove-btn" title="キューから削除">×</button>
    `;

    queueItem.querySelector('.queue-item-remove-btn').addEventListener('click', (e) => {
        e.stopPropagation();
        ipcRenderer.send('remove-from-queue', song.id); // 'remove-from-queue' イベント（仮）
    });

    return queueItem;
}

/**
 * アルバムビューのグリッドアイテム（DOM要素）を作成する
 * @param {object} album - アルバムオブジェクト
 * @returns {HTMLElement}
 */
export function createAlbumGridItem(album) {
    const albumItem = document.createElement('div');
    albumItem.className = 'album-grid-item';
    albumItem.dataset.albumKey = album.key;

    // --- ▼▼▼ 修正: 'getArtworkPath' -> 'resolveArtworkPath' ▼▼▼ ---
    const artwork = resolveArtworkPath(album.artwork, false);
    // --- ▲▲▲ 修正 ▲▲▲ ---

    albumItem.innerHTML = `
        <div class="album-artwork-wrapper">
            <img src="${artwork}" data-lazy-src="${artwork}" alt="${album.title} Artwork" class="lazy-artwork">
        </div>
        <div class="album-info">
            <div class="album-title">${album.title}</div>
            <div class="album-artist">${album.artist}</div>
        </div>
    `;
    return albumItem;
}

/**
 * アーティストビューのグリッドアイテム（DOM要素）を作成する
 * @param {object} artist - アーティストオブジェクト
 * @returns {HTMLElement}
 */
export function createArtistGridItem(artist) {
    const artistItem = document.createElement('div');
    artistItem.className = 'artist-grid-item';
    artistItem.dataset.artistName = artist.name;

    // アーティストのアートワーク（代表アルバムのもの）
    // --- ▼▼▼ 修正: 'getArtworkPath' -> 'resolveArtworkPath' ▼▼▼ ---
    const artwork = resolveArtworkPath(artist.artwork, false);
    // --- ▲▲▲ 修正 ▲▲▲ ---

    artistItem.innerHTML = `
        <div class="artist-artwork-wrapper">
            <img src="${artwork}" data-lazy-src="${artwork}" alt="${artist.name} Artwork" class="lazy-artwork">
        </div>
        <div class="artist-info">
            <div class="artist-name">${artist.name}</div>
        </div>
    `;
    return artistItem;
}

/**
 * プレイリストのサイドバーアイテム（DOM要素）を作成する
 * @param {object} playlist - プレイリストオブジェクト
 * @param {boolean} isActive - 現在表示中か
 * @returns {HTMLElement}
 */
export function createPlaylistSidebarItem(playlist, isActive) {
    const item = document.createElement('div');
    item.className = 'sidebar-playlist-item';
    item.dataset.playlistName = playlist.name;
    item.textContent = playlist.name;
    
    if (isActive) {
        item.classList.add('active');
    }

    item.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        showContextMenu(e.pageX, e.pageY, [
            { label: 'プレイリスト名を変更', action: () => ipcRenderer.send('rename-playlist-request', playlist.name) },
            { label: 'プレイリストを削除', action: () => ipcRenderer.send('delete-playlist-request', playlist.name) },
            { type: 'separator' },
            { label: 'アートワークを変更', action: () => ipcRenderer.send('change-playlist-artwork', playlist.name) }
        ]);
    });

    return item;
}