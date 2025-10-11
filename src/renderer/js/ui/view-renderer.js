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
import { initColumnResizing } from './column-resizer.js';
const { ipcRenderer } = require('electron');

let trackViewScroller = null;
let detailViewScroller = null;
const lastScrollPositions = {};

function clearMainContent() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
    if (detailViewScroller) {
        detailViewScroller.destroy();
        detailViewScroller = null;
    }
    disconnectVisualizerObserver();
    elements.mainContent.innerHTML = '';
    state.selectedSongIds.clear();
}

export function destroyTrackViewScroller() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
}

function createListHeader() {
    return `
        <div id="music-list-header">
            <div class="song-index">#</div>
            <div class="song-artwork-col"></div>
            <div class="song-title"><span>タイトル</span></div>
            <div class="song-artist"><span>アーティスト</span></div>
            <div class="song-album"><span>アルバム</span></div>
            <div class="song-hires">HR</div>
            <div class="song-duration"><span>時間</span></div>
            <div class="song-play-count"><span>回数</span></div>
        </div>
    `;
}

function handleSongItemClick(e, song, index, songList, songItem) {
    if (e.metaKey || e.ctrlKey) {
        if (state.selectedSongIds.has(song.id)) {
            state.selectedSongIds.delete(song.id);
            songItem.classList.remove('selected');
        } else {
            state.selectedSongIds.add(song.id);
            songItem.classList.add('selected');
        }
    } else {
        playSong(index, songList);
    }
}

export function renderTrackView() {
    clearMainContent();
    state.currentlyViewedSongs = state.library;
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.id = 'track-view';
    viewWrapper.innerHTML = `
        <div class="search-bar"><input type="text" placeholder="絞り込み検索"></div>
        <h1>曲</h1>
        ${createListHeader()}
    `;
    const musicListContainer = document.createElement('div');
    musicListContainer.id = 'music-list';
    viewWrapper.appendChild(musicListContainer);
    elements.mainContent.appendChild(viewWrapper);

    const renderItem = (song, index) => {
        const songItem = createSongItem(song, index, state.library, { groupAlbumArt: state.groupAlbumArt });
        
        if (state.selectedSongIds.has(song.id)) {
            songItem.classList.add('selected');
        }

        const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
        if (currentPlayingSong && currentPlayingSong.id === song.id) {
            songItem.classList.add('playing');
            // ビジュアライザーのターゲットを即座に設定
            if (state.activeViewId === 'track-view') {
                 setVisualizerTarget(songItem);
            }
        }

        songItem.addEventListener('click', (e) => handleSongItemClick(e, song, index, state.library, songItem));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            let songsForMenu = [song];
            if (state.selectedSongIds.size > 0 && state.selectedSongIds.has(song.id)) {
                songsForMenu = state.library.filter(s => state.selectedSongIds.has(s.id));
            }
            ipcRenderer.send('show-song-context-menu', { songs: songsForMenu, context: { view: 'library' } });
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
    
    // 再レンダリング後に再生中の曲があればビジュアライザーを再設定
    requestAnimationFrame(() => {
        const playingItem = musicListContainer.querySelector('.song-item.playing');
        if (playingItem) {
            setVisualizerTarget(playingItem);
        }
    });

    const headerEl = viewWrapper.querySelector('#music-list-header');
    initColumnResizing(headerEl);
}

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
    state.currentlyViewedSongs = [];
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
    state.currentlyViewedSongs = album.songs;
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
        ${createListHeader()}
    `;
    const listElement = document.createElement('div');
    listElement.id = 'a-detail-list';
    listElement.className = 'music-list';

    const renderItem = (song, index) => {
        const songItem = createSongItem(song, index, album.songs, { groupAlbumArt: state.groupAlbumArt });

        if (state.selectedSongIds.has(song.id)) {
            songItem.classList.add('selected');
        }

        const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
        if (currentPlayingSong && currentPlayingSong.id === song.id) {
            songItem.classList.add('playing');
        }
        songItem.addEventListener('click', (e) => handleSongItemClick(e, song, index, album.songs, songItem));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            let songsForMenu = [song];
            if (state.selectedSongIds.size > 0 && state.selectedSongIds.has(song.id)) {
                songsForMenu = state.currentlyViewedSongs.filter(s => state.selectedSongIds.has(s.id));
            }
            ipcRenderer.send('show-song-context-menu', { songs: songsForMenu, context: { view: 'album' } });
        });
        window.observeNewArtworks(songItem);
        return songItem;
    };

    viewWrapper.appendChild(listElement);
    elements.mainContent.appendChild(viewWrapper);

    detailViewScroller = new VirtualScroller({
        element: listElement,
        data: album.songs,
        itemHeight: 56,
        renderItem: renderItem
    });
    
    requestAnimationFrame(() => {
        const playingItem = listElement.querySelector('.song-item.playing');
        if (playingItem) {
            setVisualizerTarget(playingItem);
        }
    });

    const headerEl = viewWrapper.querySelector('#music-list-header');
    initColumnResizing(headerEl);
    
    const artImg = viewWrapper.querySelector('.detail-art-img');
    artImg.dataset.src = resolveArtworkPath(album.artwork, false);
    
    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, album.songs));
    
    window.observeNewArtworks(viewWrapper);
}

export function renderArtistDetailView(artist) {
    clearMainContent();
    state.currentlyViewedSongs = artist.songs;
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
    state.currentlyViewedSongs = songs;
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
        ${createListHeader()}
    `;
    const listElement = document.createElement('div');
    listElement.id = 'p-detail-list';
    listElement.className = 'music-list';
    
    const artworkContainer = viewWrapper.querySelector('.playlist-art-collage');
    const resolver = (artwork) => resolveArtworkPath(artwork, true);
    createPlaylistArtwork(artworkContainer, artworks, resolver);

    viewWrapper.appendChild(listElement);
    elements.mainContent.appendChild(viewWrapper);

    const renderItem = (song, index) => {
        const songItem = createSongItem(song, index, songs, { groupAlbumArt: state.groupAlbumArt });

        if (state.selectedSongIds.has(song.id)) {
            songItem.classList.add('selected');
        }

        const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
        if (currentPlayingSong && currentPlayingSong.id === song.id) {
            songItem.classList.add('playing');
        }
        songItem.addEventListener('click', (e) => handleSongItemClick(e, song, index, songs, songItem));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            lastScrollPositions[playlistName] = listElement.scrollTop;
            let songsForMenu = [song];
            if (state.selectedSongIds.size > 0 && state.selectedSongIds.has(song.id)) {
                songsForMenu = state.currentlyViewedSongs.filter(s => state.selectedSongIds.has(s.id));
            }
            ipcRenderer.send('show-song-context-menu', { songs: songsForMenu, context: { view: 'playlist', playlistName } });
        });
        window.observeNewArtworks(songItem);
        return songItem;
    };

    detailViewScroller = new VirtualScroller({
        element: listElement,
        data: songs,
        itemHeight: 56,
        renderItem: renderItem
    });
    
    if (lastScrollPositions[playlistName]) {
        requestAnimationFrame(() => {
            listElement.scrollTop = lastScrollPositions[playlistName];
            delete lastScrollPositions[playlistName]; 
        });
    }

    requestAnimationFrame(() => {
        const playingItem = listElement.querySelector('.song-item.playing');
        if (playingItem) {
            setVisualizerTarget(playingItem);
        }
    });

    const headerEl = viewWrapper.querySelector('#music-list-header');
    initColumnResizing(headerEl);

    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, songs));
    
    window.observeNewArtworks(viewWrapper);
}