import { state, elements } from '../state.js';
import { showAlbum, showArtist, showPlaylist } from '../navigation.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
import { showContextMenu } from './utils.js';
import { playSong } from '../playback-manager.js';
import { startVisualizer } from '../player.js'; 
import { VirtualScroller } from '../virtual-scroller.js';
import { 
    createSongItem, 
    createAlbumGridItem, 
    createArtistGridItem, 
    createPlaylistGridItem 
} from './element-factory.js';
const { ipcRenderer } = require('electron');

let trackViewScroller = null;

export function renderTrackView() {
    console.time('Renderer: renderTrackView');
    console.log('[View Renderer] Rendering Track View...');

    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];

    // VirtualScrollerのインスタンスが存在すればデータを更新、なければ新規作成
    if (trackViewScroller) {
        trackViewScroller.updateData(state.library);
    } else {
        elements.musicList.innerHTML = ''; // 初期化
        if (state.library.length === 0) {
            elements.musicList.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
            console.timeEnd('Renderer: renderTrackView');
            return;
        }

        trackViewScroller = new VirtualScroller({
            element: elements.musicList,
            data: state.library,
            itemHeight: 56, // .song-item の高さ (padding含む)
            renderItem: (song, index) => {
                const songItem = createSongItem(song, index, ipcRenderer);
                
                if (currentPlayingSong && currentPlayingSong.path === song.path) {
                    songItem.classList.add('playing');
                    songItem.classList.add('indicator-ready');
                }

                songItem.addEventListener('click', () => playSong(index, state.library));
                songItem.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    ipcRenderer.send('show-song-context-menu-in-library', song); 
                });
                
                // 遅延読み込みの対象として画像を監視
                window.observeNewArtworks(songItem);

                return songItem;
            }
        });
    }

    if (currentPlayingSong) {
        startVisualizer();
    }
    
    console.timeEnd('Renderer: renderTrackView');
}


export function renderAlbumView() {
    console.time('Renderer: renderAlbumView');
    console.log('[View Renderer] Rendering Album View...');

    elements.albumGrid.innerHTML = '';
    if (state.albums.size === 0) {
        elements.albumGrid.innerHTML = '<div class="placeholder">ライブラリにアルバムが見つかりません</div>';
        console.timeEnd('Renderer: renderAlbumView');
        return;
    }
    for (const [key, album] of state.albums.entries()) {
        const albumItem = createAlbumGridItem(key, album, ipcRenderer);
        albumItem.addEventListener('click', () => showAlbum(key));
        elements.albumGrid.appendChild(albumItem);
    }
    window.observeNewArtworks(elements.albumGrid);

    console.timeEnd('Renderer: renderAlbumView');
}

export function renderArtistView() {
    console.time('Renderer: renderArtistView');
    console.log('[View Renderer] Rendering Artist View...');

    elements.artistGrid.innerHTML = '';
    if (state.artists.size === 0) {
        elements.artistGrid.innerHTML = '<div class="placeholder">ライブラリにアーティストが見つかりません</div>';
        console.timeEnd('Renderer: renderArtistView');
        return;
    }
    const sortedArtists = [...state.artists.values()].sort((a, b) => a.name.localeCompare(b.name));
    sortedArtists.forEach(artist => {
        const artistItem = createArtistGridItem(artist, ipcRenderer);
        artistItem.addEventListener('click', () => showArtist(artist.name));
        elements.artistGrid.appendChild(artistItem);
    });
    window.observeNewArtworks(elements.artistGrid);

    console.timeEnd('Renderer: renderArtistView');
}

export function renderPlaylistView() {
    console.time('Renderer: renderPlaylistView');
    console.log('[View Renderer] Rendering Playlist View...');

    elements.playlistGrid.innerHTML = '';
    if (!state.playlists || state.playlists.length === 0) {
        elements.playlistGrid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
        console.timeEnd('Renderer: renderPlaylistView');
        return;
    }
    state.playlists.forEach(playlist => {
        const playlistItem = createPlaylistGridItem(playlist, ipcRenderer);
        playlistItem.addEventListener('click', () => showPlaylist(playlist.name));
        
        playlistItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
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
        
        elements.playlistGrid.appendChild(playlistItem);
    });
    window.observeNewArtworks(elements.playlistGrid);
    
    console.timeEnd('Renderer: renderPlaylistView');
}