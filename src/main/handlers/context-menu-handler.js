const { ipcMain, Menu, dialog, BrowserWindow } = require('electron');
const fs = require('fs');
const playlistManager = require('../playlist-manager');
const { getPlaylistsWithArtwork } = require('./playlist-handler');

let libraryStore;

function createUnifiedSongMenu(songs, context, sendToAllWindows) {
    const { playlistName } = context;
    const allPlaylists = playlistManager.getAllPlaylists();
    const favoritesName = playlistManager.getFavoritesPlaylistName();
    const firstSong = songs[0]; // Keep for single-song checks like favorite status

    const isFavorited = firstSong ? playlistManager.isSongInPlaylist(favoritesName, firstSong.path) : false;

    const addToPlaylistSubmenu = allPlaylists
        .map(name => ({
            label: name,
            click: () => {
                const result = playlistManager.addSongsToPlaylist(name, songs);
                const window = BrowserWindow.getAllWindows()[0];
                if (window) {
                    const message = songs.length > 1 ?
                        `${songs.length}曲をプレイリスト「${name}」に追加しました。` :
                        `「${firstSong?.title || '選択した曲'}」をプレイリスト「${name}」に追加しました。`;
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
            enabled: songs.length === 1, // Enable only for single selection for now
            click: () => {
                if (songs.length !== 1) return;
                playlistManager.ensureFavoritesPlaylistExists();
                const songPaths = songs.map(s => s.path);
                if (isFavorited) {
                    playlistManager.removeSongsFromPlaylist(favoritesName, songPaths);
                } else {
                    playlistManager.addSongsToPlaylist(favoritesName, songs);
                }
                sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
                // Optionally refresh the current view if favorite status affects it
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
                    // Send playlist name to reload specific playlist
                    window.webContents.send('force-reload-playlist', playlistName);
                }
            }
        }, { type: 'separator' });
    }

    template.push({
        label: songs.length > 1 ? `選択した${songs.length}曲をライブラリから削除...` : 'ライブラリから削除...',
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            // Pass the entire array of selected songs
            deleteSongsFromLibrary(window, songs, sendToAllWindows);
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

// Renamed and modified to handle an array of songs
async function deleteSongsFromLibrary(window, songsToDelete, sendToAllWindows) {
    if (!songsToDelete || songsToDelete.length === 0) return;

    const message = songsToDelete.length > 1
        ? `選択された${songsToDelete.length}曲をライブラリから完全に削除しますか？`
        : `「${songsToDelete[0].title}」をライブラリから完全に削除しますか？`;

    const dialogResult = await dialog.showMessageBox(window, {
        type: 'warning',
        buttons: ['キャンセル', '削除'],
        defaultId: 0,
        title: '曲の削除の確認',
        message: message,
        detail: 'この操作は元に戻せません。ファイルもディスクから削除されます。'
    });

    if (dialogResult.response !== 1) return; // User canceled

    const deletedSongIds = [];
    const errors = [];
    let library = libraryStore.load() || [];
    const allPlaylistNames = playlistManager.getAllPlaylists();

    for (const song of songsToDelete) {
        try {
            // 1. Delete the actual file
            if (fs.existsSync(song.path)) {
                fs.unlinkSync(song.path);
            }
            
            // 2. Remove from library data (filter based on ID for robustness)
            library = library.filter(s => s.id !== song.id);

            // 3. Remove from all playlists
            const songPathArray = [song.path];
            allPlaylistNames.forEach(playlistName => {
                playlistManager.removeSongsFromPlaylist(playlistName, songPathArray);
            });

            deletedSongIds.push(song.id);

        } catch (error) {
            console.error(`楽曲「${song.title}」の削除中にエラーが発生しました:`, error);
            errors.push(song.title);
        }
    }

    // Save the updated library data once after the loop
    libraryStore.save(library);

    // Send update to renderer with all deleted IDs
    if (deletedSongIds.length > 0) {
        sendToAllWindows('songs-deleted', deletedSongIds);
        // Also update playlists in UI if necessary (optional, as song-deleted might cover it)
        sendToAllWindows('playlists-updated', getPlaylistsWithArtwork());
    }

    // Show error message if any deletions failed
    if (errors.length > 0) {
        dialog.showErrorBox('削除エラー', `以下の曲の削除中にエラーが発生しました:\n${errors.join('\n')}`);
    }
}

module.exports = { registerContextMenuHandlers };