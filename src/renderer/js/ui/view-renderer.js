import { state, elements } from '../state.js';
import { showAlbum, showArtist, showPlaylist, showSituationPlaylistDetail } from '../navigation.js';
import { playSong } from '../playback-manager.js';
import { setVisualizerTarget, disconnectVisualizerObserver } from '../player.js';
import { VirtualScroller } from '../virtual-scroller.js';
import { createSongItem, createAlbumGridItem, createArtistGridItem, createPlaylistGridItem } from './element-factory.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
import { showContextMenu, formatTime, resolveArtworkPath } from './utils.js';
import { showModal } from '../modal.js';
import { showNotification, hideNotification } from './notification.js';
const { ipcRenderer } = require('electron');

let trackViewScroller = null;

function clearMainContent() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
    disconnectVisualizerObserver();
    elements.mainContent.innerHTML = '';
}

export function destroyTrackViewScroller() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
}

export function renderTrackView() {
    clearMainContent();
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];

    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.id = 'track-view';
    viewWrapper.innerHTML = `
        <div class="search-bar"><input type="text" placeholder="絞り込み検索"></div>
        <h1>曲</h1>
        <div id="music-list-header">
            <div class="header-item">#</div>
            <div class="header-item">タイトル</div>
            <div class="header-item">アーティスト</div>
            <div class="header-item">アルバム</div>
            <div class="header-item">再生時間</div>
            <div class="header-item">再生数</div>
        </div>
    `;
    const musicListContainer = document.createElement('div');
    musicListContainer.id = 'music-list';
    viewWrapper.appendChild(musicListContainer);
    elements.mainContent.appendChild(viewWrapper);

    const renderItem = (song, index) => {
        const songItem = createSongItem(song, index, ipcRenderer);
        songItem.dataset.songPath = song.path;
        
        const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
        if (currentPlayingSong && currentPlayingSong.path === song.path) {
            songItem.classList.add('playing');
            setVisualizerTarget(songItem);
        }

        songItem.addEventListener('click', () => playSong(index, state.library));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song);
        });
        window.observeNewArtworks(songItem);
        return songItem;
    };

    if (state.library.length === 0) {
        musicListContainer.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }

    trackViewScroller = new VirtualScroller({
        element: musicListContainer,
        data: state.library,
        itemHeight: 56,
        renderItem: renderItem,
    });
}

export function renderAlbumView() {
    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = '<h1>アルバム</h1>';
    const grid = document.createElement('div');
    grid.id = 'album-grid';
    if (state.albums.size === 0) {
        grid.innerHTML = '<div class="placeholder">ライブラリにアルバムが見つかりません</div>';
    } else {
        for (const [key, album] of state.albums.entries()) {
            const albumItem = createAlbumGridItem(key, album, ipcRenderer);
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
                            const result = await ipcRenderer.invoke('add-album-to-playlist', { songPaths, playlistName: playlist.name });

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
    elements.mainContent.appendChild(viewWrapper);
    window.observeNewArtworks(grid);
}

export function renderArtistView() {
    clearMainContent();
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
            const artistItem = createArtistGridItem(artist, ipcRenderer);
            artistItem.addEventListener('click', () => showArtist(artist.name));
            grid.appendChild(artistItem);
        });
    }
    viewWrapper.appendChild(grid);
    elements.mainContent.appendChild(viewWrapper);
    window.observeNewArtworks(grid);
}

export async function renderSituationView() {
    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = '<h1>For You</h1>';
    const grid = document.createElement('div');
    grid.id = 'playlist-grid';

    const situationPlaylists = await ipcRenderer.invoke('get-situation-playlists');
    const playlists = Object.values(situationPlaylists);

    if (playlists.length === 0) {
        grid.innerHTML = '<div class="placeholder">あなたのためのプレイリストはまだありません。</div>';
    } else {
        playlists.forEach(playlist => {
            const artworks = playlist.songs
                .map(song => (state.albums.get(song.albumKey) || song).artwork)
                .filter(Boolean)
                .slice(0, 4);
            
            const playlistItem = createPlaylistGridItem({ name: playlist.name, artworks }, ipcRenderer);
            
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
    elements.mainContent.appendChild(viewWrapper);
    window.observeNewArtworks(grid);
}

export function renderPlaylistView() {
    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.innerHTML = `<div class="view-header"><h1>プレイリスト</h1><button id="create-playlist-btn-main" class="header-button">+ 新規作成</button></div>`;
    const grid = document.createElement('div');
    grid.id = 'playlist-grid';
    if (!state.playlists || state.playlists.length === 0) {
        grid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
    } else {
        state.playlists.forEach(playlist => {
            const playlistItem = createPlaylistGridItem(playlist, ipcRenderer);
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
                                       await ipcRenderer.invoke('rename-playlist', { oldName: playlist.name, newName });
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
                                await ipcRenderer.invoke('delete-playlist', playlist.name);
                            }
                        }
                    }
                ]);
            });
            grid.appendChild(playlistItem);
        });
    }
    viewWrapper.appendChild(grid);
    elements.mainContent.appendChild(viewWrapper);
    viewWrapper.querySelector('#create-playlist-btn-main').addEventListener('click', () => {
        showModal({
            title: '新規プレイリスト',
            placeholder: 'プレイリスト名',
            onOk: async (name) => {
                await ipcRenderer.invoke('create-playlist', name);
            }
        });
    });
    window.observeNewArtworks(grid);
}

export function renderAlbumDetailView(album) {
    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    const totalDuration = album.songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    viewWrapper.innerHTML = `
        <div class="detail-header">
            <img class="detail-art-img lazy-load">
            <div class="detail-info">
                <h1>${album.title}</h1>
                <p>${album.artist}</p>
                <p>${album.songs.length} 曲, ${formatTime(totalDuration)}</p>
                <div class="detail-actions"><button class="play-all-btn">▶ すべて再生</button></div>
            </div>
        </div>
        <div id="a-detail-list-header" class="music-list-header">
             <div class="header-item">#</div>
             <div class="header-item">タイトル</div>
             <div class="header-item">アーティスト</div>
             <div class="header-item">アルバム</div>
             <div class="header-item">再生時間</div>
             <div class="header-item">再生数</div>
        </div>
    `;
    const listElement = document.createElement('div');
    listElement.id = 'a-detail-list';
    listElement.className = 'music-list';

    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    album.songs.forEach((song, index) => {
        const songItem = createSongItem(song, index, ipcRenderer);
        songItem.dataset.songPath = song.path;
        if (currentPlayingSong && currentPlayingSong.path === song.path) {
            songItem.classList.add('playing');
        }
        songItem.addEventListener('click', () => playSong(index, album.songs));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song);
        });
        listElement.appendChild(songItem);
    });
    
    viewWrapper.appendChild(listElement);
    elements.mainContent.appendChild(viewWrapper);
    
    const artImg = viewWrapper.querySelector('.detail-art-img');
    artImg.dataset.src = resolveArtworkPath(album.artwork, false);
    
    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, album.songs));
    
    const playingItem = listElement.querySelector('.song-item.playing');
    if (playingItem) {
        setVisualizerTarget(playingItem);
    }
    
    window.observeNewArtworks(viewWrapper);
}

export function renderArtistDetailView(artist) {
    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    const artistAlbums = [...state.albums.values()].filter(album => album.artist === artist.name);
    viewWrapper.innerHTML = `
        <div class="detail-header">
            <img class="detail-art-img artist-detail-art-round lazy-load">
            <div class="detail-info">
                <h1>${artist.name}</h1>
                <p>${artistAlbums.length}枚のアルバム, ${artist.songs.length}曲</p>
            </div>
        </div>
        <h2>アルバム</h2>
    `;
    const grid = document.createElement('div');
    grid.className = 'album-grid';
    if (artistAlbums.length === 0) {
        grid.innerHTML = `<div class="placeholder">このアーティストのアルバムは見つかりません</div>`;
    } else {
        artistAlbums.forEach(album => {
            const albumKey = `${album.title}---${album.artist}`;
            const albumItem = createAlbumGridItem(albumKey, album, ipcRenderer);
            albumItem.addEventListener('click', () => showAlbum(albumKey));
            grid.appendChild(albumItem);
        });
    }
    viewWrapper.appendChild(grid);
    elements.mainContent.appendChild(viewWrapper);

    const artImg = viewWrapper.querySelector('.detail-art-img');
    artImg.dataset.src = resolveArtworkPath(artist.artwork, false);

    window.observeNewArtworks(viewWrapper);
}

export function renderPlaylistDetailView(playlistDetails) {
    const { name: playlistName, songs, artworks } = playlistDetails;

    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    viewWrapper.innerHTML = `
        <div class="detail-header">
            <div class="playlist-art-collage detail-art-img"></div>
            <div class="detail-info">
                <h1>${playlistName}</h1>
                <p>${songs.length} 曲, ${formatTime(totalDuration)}</p>
                <div class="detail-actions"><button class="play-all-btn">▶ すべて再生</button></div>
            </div>
        </div>
        <div id="p-detail-list-header" class="music-list-header">
            <div class="header-item">#</div>
            <div class="header-item">タイトル</div>
            <div class="header-item">アーティスト</div>
            <div class="header-item">アルバム</div>
            <div class="header-item">再生時間</div>
            <div class="header-item">再生数</div>
        </div>
    `;
    const listElement = document.createElement('div');
    listElement.id = 'p-detail-list';
    listElement.className = 'music-list';
    
    const artworkContainer = viewWrapper.querySelector('.playlist-art-collage');
    const resolver = (artwork) => resolveArtworkPath(artwork, true);
    createPlaylistArtwork(artworkContainer, artworks, resolver);

    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    songs.forEach((song, index) => {
        const songItem = createSongItem(song, index, ipcRenderer);
        songItem.dataset.songPath = song.path;
        if (currentPlayingSong && currentPlayingSong.path === song.path) {
            songItem.classList.add('playing');
        }
        songItem.addEventListener('click', () => playSong(index, songs));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-playlist-song-context-menu', { playlistName, song });
        });
        listElement.appendChild(songItem);
    });
    viewWrapper.appendChild(listElement);
    elements.mainContent.appendChild(viewWrapper);
    
    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, songs));
    
    const playingItem = listElement.querySelector('.song-item.playing');
    if (playingItem) {
        setVisualizerTarget(playingItem);
    }
    
    window.observeNewArtworks(viewWrapper);
}