const { ipcMain, Menu, dialog, BrowserWindow } = require('electron');
const fs = require('fs');
const playlistManager = require('../playlist-manager');
const { getPlaylistsWithArtwork } = require('./playlist-handler');

let libraryStore;

function createUnifiedSongMenu(songs, context, sendToAllWindows) {
    const { playlistName } = context;
    const allPlaylists = playlistManager.getAllPlaylists();
    const favoritesName = playlistManager.getFavoritesPlaylistName();
    const firstSong = songs[0];

    const isFavorited = playlistManager.isSongInPlaylist(favoritesName, firstSong.path);

    const addToPlaylistSubmenu = allPlaylists
        .filter(name => name !== favoritesName)
        .map(name => ({
            label: name,
            click: () => {
                const result = playlistManager.addSongsToPlaylist(name, songs);
                const window = BrowserWindow.getAllWindows()[0];
                if (window) {
                    const message = songs.length > 1 ?
                        `${songs.length}曲をプレイリスト「${name}」に追加しました。` :
                        `「${firstSong.title}」をプレイリスト「${name}」に追加しました。`;
                    window.webContents.send('show-notification', message);
                }
            }
        }));

    addToPlaylistSubmenu.unshift({
        label: '+ 新規プレイリスト',
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            if (window) {
                window.webContents.send('request-new-playlist-with-songs', songs);
            }
        }
    }, { type: 'separator' });

    const template = [
        {
            label: isFavorited ? 'お気に入りから削除' : 'お気に入りに追加',
            click: () => {
                playlistManager.ensureFavoritesPlaylistExists();
                const songPaths = songs.map(s => s.path);
                if (isFavorited) {
                    playlistManager.removeSongsFromPlaylist(favoritesName, songPaths);
                } else {
                    playlistManager.addSongsToPlaylist(favoritesName, songs);
                }
                sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
            }
        },
        {
            label: 'プレイリストに追加',
            submenu: addToPlaylistSubmenu.length > 2 ? addToPlaylistSubmenu : [{ label: '（追加可能なプレイリスト無し）', enabled: false }]
        },
        { type: 'separator' },
    ];

    if (playlistName && playlistName !== favoritesName) {
        const label = songs.length > 1 ? `選択した${songs.length}曲をこのプレイリストから削除` : 'このプレイリストから削除';
        template.push({
            label: label,
            click: () => {
                const songPaths = songs.map(s => s.path);
                playlistManager.removeSongsFromPlaylist(playlistName, songPaths);
                const window = BrowserWindow.getAllWindows()[0];
                if (window && !window.isDestroyed()) {
                    window.webContents.send('force-reload-playlist', playlistName);
                }
            }
        }, { type: 'separator' });
    }

    template.push({
        label: 'ライブラリから削除...',
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            deleteSongFromLibrary(window, firstSong, sendToAllWindows); // Deletion is still one by one with confirmation
        }
    });

    return Menu.buildFromTemplate(template);
}


function registerContextMenuHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;

    ipcMain.on('show-song-context-menu', (event, { songs, context = {} }) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window || !songs || songs.length === 0) return;
        
        const menu = createUnifiedSongMenu(songs, context, sendToAllWindows);
        menu.popup({ window });
    });
}

async function deleteSongFromLibrary(window, song, sendToAllWindows) {
    const dialogResult = await dialog.showMessageBox(window, {
        type: 'warning',
        buttons: ['キャンセル', '削除'],
        defaultId: 0,
        title: '曲の削除の確認',
        message: `「${song.title}」をライブラリから完全に削除しますか？`,
        detail: 'この操作は元に戻せません。ファイルもディスクから削除されます。'
    });

    if (dialogResult.response !== 1) return;

    try {
        if (fs.existsSync(song.path)) {
            fs.unlinkSync(song.path);
        }
        
        const library = libraryStore.load() || [];
        const updatedLibrary = library.filter(s => s.path !== song.path);
        libraryStore.save(updatedLibrary);
        
        const songPaths = [song.path];
        playlistManager.getAllPlaylists().forEach(playlistName => {
            playlistManager.removeSongsFromPlaylist(playlistName, songPaths);
        });
        
        sendToAllWindows('song-deleted', song.path);
    } catch (error) {
        console.error('楽曲の削除中にエラーが発生しました:', error);
        dialog.showErrorBox('削除エラー', '曲の削除中にエラーが発生しました。');
    }
}

module.exports = { registerContextMenuHandlers };