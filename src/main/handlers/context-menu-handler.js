const { ipcMain, Menu, MenuItem, dialog, BrowserWindow } = require('electron');
const fs = require('fs');
const playlistManager = require('../playlist-manager');
const { getPlaylistsWithArtwork } = require('./playlist-handler');
const mtpManager = require('../mtp/mtp-manager');
const IPC_CHANNELS = require('../ipc-channels');

let libraryStore;

function createUnifiedSongMenu(songs, context, sendToAllWindows) {
    const { playlistName } = context;
    const allPlaylists = playlistManager.getAllPlaylists();
    const favoritesName = playlistManager.getFavoritesPlaylistName();
    const firstSong = songs[0];

    const isFavorited = songs.length === 1 && playlistManager.isSongInPlaylist(favoritesName, firstSong.path);

    const addToPlaylistSubmenu = allPlaylists
        .map(name => ({
            label: name,
            click: () => {
                const result = playlistManager.addSongsToPlaylist(name, songs);
                const window = BrowserWindow.getAllWindows()[0];
                if (window) {
                    const message = songs.length > 1 ?
                        `${songs.length}曲をプレイリスト「${name}」に追加しました。` :
                        `「${firstSong.title}」をプレイリスト「${name}」に追加しました。`;
                    window.webContents.send(IPC_CHANNELS.ON.SHOW_NOTIFICATION, message);
                }
                sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
            }
        }));

    addToPlaylistSubmenu.unshift({
        label: '+ 新規プレイリスト',
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            if (window) {
                window.webContents.send(IPC_CHANNELS.ON.REQUEST_NEW_PLAYLIST_WITH_SONGS, songs);
            }
        }
    }, { type: 'separator' });

    const template = [];

    template.push({
        label: '情報を編集...',
        enabled: songs.length === 1,
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            if (window && songs.length === 1) {
                window.webContents.send(IPC_CHANNELS.ON.SHOW_EDIT_METADATA_MODAL, songs[0]);
            }
        }
    });
    template.push({ type: 'separator' });

    const mtpDevice = mtpManager.getDevice();
    template.push({
        label: songs.length > 1 ? `${songs.length}曲をWalkmanへ転送` : 'Walkmanへ転送',
        enabled: !!mtpDevice,
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            if (window && mtpDevice) {
                window.webContents.send(IPC_CHANNELS.ON.REQUEST_MTP_TRANSFER, songs);
            }
        }
    });
    template.push({ type: 'separator' });

    if (songs.length === 1) {
        template.push({
            label: isFavorited ? 'お気に入りから削除' : 'お気に入りに追加',
            click: () => {
                playlistManager.ensureFavoritesPlaylistExists();
                const songPaths = songs.map(s => s.path);
                if (isFavorited) {
                    playlistManager.removeSongsFromPlaylist(favoritesName, songPaths);
                } else {
                    playlistManager.addSongsToPlaylist(favoritesName, songs);
                }
                sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
            }
        });
    }

    template.push({
        label: 'プレイリストに追加',
        submenu: addToPlaylistSubmenu.length > 2 ? addToPlaylistSubmenu : [{ label: '（追加可能なプレイリスト無し）', enabled: false }]
    });

    template.push({ type: 'separator' });

    if (playlistName && playlistName !== favoritesName) {
        const label = songs.length > 1 ? `選択した${songs.length}曲をこのプレイリストから削除` : 'このプレイリストから削除';
        template.push({
            label: label,
            click: () => {
                const songPaths = songs.map(s => s.path);
                playlistManager.removeSongsFromPlaylist(playlistName, songPaths);
                const window = BrowserWindow.getAllWindows()[0];
                if (window && !window.isDestroyed()) {
                    window.webContents.send(IPC_CHANNELS.ON.FORCE_RELOAD_PLAYLIST, playlistName);
                }
            }
        }, { type: 'separator' });
    }

    template.push({
        label: songs.length > 1 ? `選択した${songs.length}曲をライブラリから削除...` : 'ライブラリから削除...',
        click: () => {
            const window = BrowserWindow.getAllWindows()[0];
            deleteSongsFromLibrary(window, songs, sendToAllWindows);
        }
    });

    return Menu.buildFromTemplate(template);
}

// --- ▼▼▼ 新規追加: 汎用コンテキストメニュー作成 ▼▼▼ ---
function createGeneralContextMenu(webContents) {
    const menu = new Menu();

    // 戻るボタン
    menu.append(new MenuItem({
        label: '戻る',
        accelerator: 'CmdOrCtrl+[',
        click: () => {
            webContents.send(IPC_CHANNELS.ON.NAVIGATE_BACK);
        }
    }));

    return menu;
}
// --- ▲▲▲ ここまで ▲▲▲ ---

function registerContextMenuHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;

    ipcMain.on(IPC_CHANNELS.SEND.SHOW_SONG_CONTEXT_MENU, (event, { songs, context = {} }) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window || !songs || songs.length === 0) return;

        const menu = createUnifiedSongMenu(songs, context, sendToAllWindows);
        menu.popup({ window });
    });

    // --- ▼▼▼ 新規追加: 汎用メニューハンドラ ▼▼▼ ---
    ipcMain.on(IPC_CHANNELS.SEND.SHOW_GENERAL_CONTEXT_MENU, (event) => {
        const window = BrowserWindow.fromWebContents(event.sender);
        if (!window) return;

        const menu = createGeneralContextMenu(event.sender);
        menu.popup({ window });
    });
    // --- ▲▲▲ ここまで ▲▲▲ ---

    ipcMain.on(IPC_CHANNELS.SEND.CREATE_NEW_PLAYLIST_WITH_SONGS, (event, { playlistName, songs }) => {
        const createResult = playlistManager.createPlaylist(playlistName);
        if (createResult.success) {
            const addResult = playlistManager.addSongsToPlaylist(playlistName, songs);
            if (addResult.success) {
                const message = songs.length > 1 ?
                    `${songs.length}曲を新規プレイリスト「${playlistName}」に追加しました。` :
                    `「${songs[0].title}」を新規プレイリスト「${playlistName}」に追加しました。`;
                event.sender.send(IPC_CHANNELS.ON.SHOW_NOTIFICATION, message);
                sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
            } else {
                event.sender.send(IPC_CHANNELS.ON.SHOW_ERROR, `プレイリスト「${playlistName}」への曲の追加に失敗しました: ${addResult.message}`);
            }
        } else {
            event.sender.send(IPC_CHANNELS.ON.SHOW_ERROR, `新規プレイリスト「${playlistName}」の作成に失敗しました: ${createResult.message}`);
        }
    });
}

async function deleteSongsFromLibrary(window, songs, sendToAllWindows) {
    if (!songs || songs.length === 0) return;

    const message = songs.length > 1
        ? `選択された${songs.length}曲をライブラリから完全に削除しますか？`
        : `「${songs[0].title}」をライブラリから完全に削除しますか？`;

    const dialogResult = await dialog.showMessageBox(window, {
        type: 'warning',
        buttons: ['キャンセル', '削除'],
        defaultId: 0,
        title: '曲の削除の確認',
        message: message,
        detail: 'この操作は元に戻せません。ファイルもディスクから削除されます。'
    });

    if (dialogResult.response !== 1) return;

    const library = libraryStore.load() || [];
    const pathsToRemove = new Set(songs.map(s => s.path));
    const updatedLibrary = library.filter(s => !pathsToRemove.has(s.path));
    let deletedCount = 0;
    let errorCount = 0;

    for (const song of songs) {
        try {
            if (fs.existsSync(song.path)) {
                fs.unlinkSync(song.path);
            }
            deletedCount++;
        } catch (error) {
            console.error(`楽曲ファイル ${song.path} の削除中にエラーが発生しました:`, error);
            errorCount++;
        }
    }

    if (deletedCount > 0) {
        libraryStore.save(updatedLibrary);

        const allPlaylists = playlistManager.getAllPlaylists();
        for (const playlistName of allPlaylists) {
            playlistManager.removeSongsFromPlaylist(playlistName, Array.from(pathsToRemove));
        }

        sendToAllWindows(IPC_CHANNELS.ON.SONGS_DELETED, Array.from(pathsToRemove));
        sendToAllWindows(IPC_CHANNELS.ON.PLAYLISTS_UPDATED, getPlaylistsWithArtwork());
    }

    if (errorCount > 0) {
        dialog.showErrorBox('削除エラー', `${errorCount}曲のファイル削除中にエラーが発生しました。詳細はコンソールを確認してください。`);
    }
}

module.exports = { registerContextMenuHandlers };