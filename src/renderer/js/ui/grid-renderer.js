// src/renderer/js/ui/grid-renderer.js

import { state } from '../state.js';
import { showAlbum, showArtist, showPlaylist, showSituationPlaylistDetail } from '../navigation.js';
import { createAlbumGridItem, createArtistGridItem, createPlaylistGridItem } from './element-factory.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
import { showContextMenu, resolveArtworkPath } from './utils.js';
import { showModal } from '../modal.js';
import { showNotification, hideNotification } from './notification.js';
import { clearMainContent } from './view-renderer.js'; // clearMainContent は view-renderer からインポート
const electronAPI = window.electronAPI;

/**
 * アルバム一覧ビューを描画する
 */
export function renderAlbumView() {
    clearMainContent();
    state.currentlyViewedSongs = [];
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = '<h1>アルバム</h1>';
    const grid = document.createElement('div');
    grid.id = 'album-grid';
    if (state.albums.size === 0) {
        grid.innerHTML = '<div class="placeholder">ライブラリにアルバムが見つかりません</div>';
    } else {
        for (const [key, album] of state.albums.entries()) {
            const albumItem = createAlbumGridItem(key, album, electronAPI);
            albumItem.addEventListener('click', () => showAlbum(key));

            albumItem.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                e.stopPropagation();

                const playlists = state.playlists || [];
                const addToPlaylistSubmenu = playlists.map(playlist => ({
                    label: playlist.name,
                    action: async () => {
                        const albumToAdd = state.albums.get(key);
                        if (albumToAdd && albumToAdd.songs) {
                            const songPaths = albumToAdd.songs.map(s => s.path);
                            const result = await electronAPI.invoke('add-album-to-playlist', { songPaths, playlistName: playlist.name });

                            if (result.success && result.addedCount > 0) {
                                showNotification(`「${album.title}」の ${result.addedCount} 曲をプレイリスト「${playlist.name}」に追加しました。`);
                                hideNotification(3000);
                            } else if (result.success && result.addedCount === 0) {
                                showNotification(`すべての曲が既にプレイリストに存在します。`);
                                hideNotification(3000);
                            } else {
                                showNotification(`プレイリストへの追加に失敗しました。`, 3000);
                            }
                        }
                    }
                }));

                const menuItems = [
                    {
                        label: 'プレイリストに追加',
                        submenu: addToPlaylistSubmenu.length > 0 ? addToPlaylistSubmenu : [{ label: '（追加可能なプレイリスト無し）', enabled: false }]
                    }
                ];

                showContextMenu(e.pageX, e.pageY, menuItems);
            });

            grid.appendChild(albumItem);
        }
    }
    viewWrapper.appendChild(grid);
    document.getElementById('main-content').appendChild(viewWrapper); // elements.mainContent の代わり
    window.observeNewArtworks(grid);
}

/**
 * アーティスト一覧ビューを描画する
 */
export function renderArtistView() {
    clearMainContent();
    state.currentlyViewedSongs = [];
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = '<h1>アーティスト</h1>';
    const grid = document.createElement('div');
    grid.id = 'artist-grid';
    if (state.artists.size === 0) {
        grid.innerHTML = '<div class="placeholder">ライブラリにアーティストが見つかりません</div>';
    } else {
        const sortedArtists = [...state.artists.values()].sort((a, b) => a.name.localeCompare(b.name));
        sortedArtists.forEach(artist => {
            const artistItem = createArtistGridItem(artist, electronAPI);
            artistItem.addEventListener('click', () => showArtist(artist.name));
            grid.appendChild(artistItem);
        });
    }
    viewWrapper.appendChild(grid);
    document.getElementById('main-content').appendChild(viewWrapper);
    window.observeNewArtworks(grid);
}

/**
 * "For You" (シチュエーション別) ビューを描画する
 */
export async function renderSituationView() {
    clearMainContent();
    state.currentlyViewedSongs = [];
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = '<h1>For You</h1>';
    const grid = document.createElement('div');
    grid.id = 'playlist-grid'; // 'playlist-grid' を再利用

    const situationPlaylists = await electronAPI.invoke('get-situation-playlists');
    const playlists = Object.values(situationPlaylists);

    if (playlists.length === 0) {
        grid.innerHTML = '<div class="placeholder">あなたのためのプレイリストはまだありません。</div>';
    } else {
        playlists.forEach(playlist => {
            const artworks = playlist.songs
                .map(song => (state.albums.get(song.albumKey) || song).artwork)
                .filter(Boolean)
                .slice(0, 4);

            const playlistItem = createPlaylistGridItem({ name: playlist.name, artworks }, electronAPI);

            playlistItem.addEventListener('click', () => {
                const playlistDetails = {
                    name: playlist.name,
                    songs: playlist.songs,
                    artworks: artworks
                };
                showSituationPlaylistDetail(playlistDetails);
            });

            grid.appendChild(playlistItem);
        });
    }

    viewWrapper.appendChild(grid);
    document.getElementById('main-content').appendChild(viewWrapper);
    window.observeNewArtworks(grid);
}

/**
 * プレイリスト一覧ビューを描画する
 */
export function renderPlaylistView() {
    clearMainContent();
    state.currentlyViewedSongs = [];
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = `<div class="view-header"><h1>プレイリスト</h1><button id="create-playlist-btn-main" class="header-button">+ 新規作成</button></div>`;
    const grid = document.createElement('div');
    grid.id = 'playlist-grid';
    if (!state.playlists || state.playlists.length === 0) {
        grid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
    } else {
        state.playlists.forEach(playlist => {
            const playlistItem = createPlaylistGridItem(playlist, electronAPI);
            playlistItem.addEventListener('click', () => showPlaylist(playlist.name));
            playlistItem.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                e.stopPropagation();
                showContextMenu(e.pageX, e.pageY, [
                    {
                        label: '名前を変更',
                        action: () => {
                            showModal({
                                title: 'プレイリスト名を変更',
                                placeholder: '新しい名前',
                                onOk: async (newName) => {
                                    if (newName && newName.trim() !== '' && newName !== playlist.name) {
                                        await electronAPI.invoke('rename-playlist', { oldName: playlist.name, newName });
                                    }
                                }
                            });
                        }
                    },
                    {
                        label: '削除',
                        action: async () => {
                            const confirmed = confirm(`プレイリスト「${playlist.name}」を削除しますか？\nこの操作は元に戻せません。`);
                            if (confirmed) {
                                await electronAPI.invoke('delete-playlist', playlist.name);
                            }
                        }
                    }
                ]);
            });
            grid.appendChild(playlistItem);
        });
    }
    viewWrapper.appendChild(grid);
    document.getElementById('main-content').appendChild(viewWrapper);
    viewWrapper.querySelector('#create-playlist-btn-main').addEventListener('click', () => {
        showModal({
            title: '新規プレイリスト',
            placeholder: 'プレイリスト名',
            onOk: async (name) => {
                await electronAPI.invoke('create-playlist', name);
            }
        });
    });
    window.observeNewArtworks(grid);
}