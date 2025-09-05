const { ipcMain, Menu, dialog, BrowserWindow } = require('electron');
const fs = require('fs');
const playlistManager = require('../playlist-manager');

let libraryStore;

function registerContextMenuHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;

    ipcMain.on('show-song-context-menu-in-library', (event, song) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window) return;
        
        const playlists = playlistManager.getAllPlaylists();
        const addToPlaylistSubmenu = playlists.map(name => ({
            label: name,
            click: () => playlistManager.addSongToPlaylist(name, song)
        }));

        const template = [
            {
                label: 'プレイリストに追加',
                submenu: addToPlaylistSubmenu.length > 0 ? addToPlaylistSubmenu : [{ label: '（追加可能なプレイリスト無し）', enabled: false }]
            },
            { type: 'separator' },
            {
                label: 'ライブラリから削除...',
                click: () => deleteSongFromLibrary(window, song, sendToAllWindows)
            }
        ];

        const menu = Menu.buildFromTemplate(template);
        menu.popup({ window });
    });

    ipcMain.on('show-playlist-song-context-menu', (event, { playlistName, song }) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window) return;
        
        const menu = Menu.buildFromTemplate([
            {
                label: 'このプレイリストから削除',
                click: () => {
                    playlistManager.removeSongFromPlaylist(playlistName, song.path);
                    if (!window.isDestroyed()) {
                        event.sender.send('force-reload-playlist', playlistName);
                    }
                }
            },
        ]);
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
        
        playlistManager.getAllPlaylists().forEach(playlistName => {
            playlistManager.removeSongFromPlaylist(playlistName, song.path);
        });
        
        sendToAllWindows('song-deleted', song.path);
    } catch (error) {
        console.error('楽曲の削除中にエラーが発生しました:', error);
        dialog.showErrorBox('削除エラー', '曲の削除中にエラーが発生しました。');
    }
}

module.exports = { registerContextMenuHandlers };