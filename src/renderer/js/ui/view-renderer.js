import { state, elements } from '../state.js';
import { showAlbum, showArtist, showPlaylist } from '../navigation.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
// checkTextOverflow のインポートは不要になるので削除
import { showContextMenu, formatTime } from './utils.js';
import { playSong } from '../playback-manager.js';
import { 
    createSongItem, 
    createAlbumGridItem, 
    createArtistGridItem, 
    createPlaylistGridItem 
} from './element-factory.js';
const { ipcRenderer } = require('electron');

export function renderTrackView() {
    elements.musicList.innerHTML = '';
    if (state.library.length === 0) {
        elements.musicList.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    state.library.forEach((song, index) => {
        const songItem = createSongItem(song, index, ipcRenderer);
        
        if (currentPlayingSong && currentPlayingSong.path === song.path) {
            songItem.classList.add('playing');
        }

        songItem.addEventListener('click', () => playSong(index, state.library));
        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            ipcRenderer.send('show-song-context-menu-in-library', song); 
        });

        elements.musicList.appendChild(songItem);
    });
}

export function renderAlbumView() {
    elements.albumGrid.innerHTML = '';
    if (state.albums.size === 0) {
        elements.albumGrid.innerHTML = '<div class="placeholder">ライブラリにアルバムが見つかりません</div>';
        return;
    }
    for (const [key, album] of state.albums.entries()) {
        const albumItem = createAlbumGridItem(key, album, ipcRenderer);
        albumItem.addEventListener('click', () => showAlbum(key));
        elements.albumGrid.appendChild(albumItem);
    }
}

export function renderArtistView() {
    elements.artistGrid.innerHTML = '';
    if (state.artists.size === 0) {
        elements.artistGrid.innerHTML = '<div class="placeholder">ライブラリにアーティストが見つかりません</div>';
        return;
    }
    const sortedArtists = [...state.artists.values()].sort((a, b) => a.name.localeCompare(b.name));
    sortedArtists.forEach(artist => {
        const artistItem = createArtistGridItem(artist, ipcRenderer);
        artistItem.addEventListener('click', () => showArtist(artist.name));
        elements.artistGrid.appendChild(artistItem);
    });
}

export function renderPlaylistView() {
    elements.playlistGrid.innerHTML = '';
    if (!state.playlists || state.playlists.length === 0) {
        elements.playlistGrid.innerHTML = '<p>プレイリストはまだありません。「+ 新規作成」から作成できます。</p>';
        return;
    }
    state.playlists.forEach(playlist => {
        const playlistItem = createPlaylistGridItem(playlist, ipcRenderer);
        playlistItem.addEventListener('click', () => showPlaylist(playlist.name));
        
        playlistItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            showContextMenu(e.pageX, e.pageY, [
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
}