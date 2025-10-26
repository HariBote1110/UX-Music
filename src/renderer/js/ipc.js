import { playSong, playNextSong } from './playback-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { state } from './state.js';
import { showModal } from './modal.js';
import { renderCurrentView } from './ui-manager.js';
// --- ▼▼▼ 新規追加 ▼▼▼ ---
import { showEditMetadataModal } from './edit-metadata.js'; // あとで作成するファイル
// --- ▲▲▲ ここまで ▲▲▲ ---

const startTime = performance.now();
const logPerf = (message) => {
    console.log(`[PERF][IPC] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};
logPerf("ipc.js script execution started.");

export function initIPC(ipcRenderer, callbacks) {
    logPerf("initIPC called.");
    ipcRenderer.on('app-info-response', (event, info) => {
        callbacks.onAppInfoResponse?.(info);
    });
    ipcRenderer.on('load-library', (event, data) => {
        logPerf("Received 'load-library' from main.");
        console.log(`[Debug] Received initial library with ${data.songs ? data.songs.length : 0} songs.`);
        callbacks.onLibraryLoaded?.(data);
    });
    ipcRenderer.on('settings-loaded', (event, settings) => {
        logPerf("Received 'settings-loaded' from main.");
        console.log('[Debug] Settings loaded.');
        callbacks.onSettingsLoaded?.(settings);
    });
    ipcRenderer.on('play-counts-updated', (event, counts) => {
        callbacks.onPlayCountsUpdated?.(counts);
    });
    ipcRenderer.on('youtube-link-processed', (event, newSong) => {
        callbacks.onYoutubeLinkProcessed?.(newSong);
    });
    ipcRenderer.on('playlists-updated', (event, playlists) => {
        callbacks.onPlaylistsUpdated?.(playlists);
    });
    ipcRenderer.on('force-reload-playlist', (event, playlistName) => {
        callbacks.onForceReloadPlaylist?.(playlistName);
    });
    ipcRenderer.on('force-reload-library', () => {
        callbacks.onForceReloadLibrary?.();
    });
    ipcRenderer.on('show-loading', (event, text) => { // YouTube用
        callbacks.onShowLoading?.(text);
    });
    ipcRenderer.on('hide-loading', () => { // YouTube用
        callbacks.onHideLoading?.();
    });
    ipcRenderer.on('show-error', (event, message) => {
        callbacks.onShowError?.(message);
    });
    ipcRenderer.on('playlist-import-progress', (event, progress) => { // YouTube用
        callbacks.onPlaylistImportProgress?.(progress);
    });
    ipcRenderer.on('playlist-import-finished', () => { // YouTube用
        callbacks.onPlaylistImportFinished?.();
    });

    ipcRenderer.on('scan-progress', (event, progress) => {
        callbacks.onScanProgress?.(progress);
    });

    ipcRenderer.on('scan-complete', (event, newSongs) => {
        callbacks.onScanComplete?.(newSongs);
    });

    ipcRenderer.on('loudness-analysis-result', (event, result) => {
        const fileName = result.filePath.split(/[/\\]/).pop();
        const waitingSong = state.songWaitingForAnalysis;

        if (result.success) {
            console.log(`%c[ラウドネス解析完了]%c ${fileName} -> %c${result.loudness.toFixed(2)} LUFS`,
                'color: green; font-weight: bold;',
                'color: inherit;',
                'color: blue; font-weight: bold;'
            );

            if (waitingSong && waitingSong.sourceList[waitingSong.index]?.path === result.filePath) {
                playSong(waitingSong.index, null, true);
            }

        } else {
            console.error(`[ラウドネス解析失敗] ${fileName}: ${result.error}`);

            if (waitingSong && waitingSong.sourceList[waitingSong.index]?.path === result.filePath) {
                showNotification(`「${fileName}」は破損しているためスキップします。`);
                hideNotification(3000);

                state.currentSongIndex = waitingSong.index;
                state.songWaitingForAnalysis = null;

                playNextSong();
            }
        }
    });

    ipcRenderer.on('lyrics-added-notification', (event, count) => {
        showNotification(`${count}個の歌詞ファイルが追加されました。`);
        hideNotification(3000);
    });

    ipcRenderer.on('show-notification', (event, message) => {
        showNotification(message);
        hideNotification(3000);
    });

    ipcRenderer.on('songs-deleted', (event, deletedSongPaths) => {
        const deletedPathsSet = new Set(deletedSongPaths);
        state.library = state.library.filter(song => !deletedPathsSet.has(song.path));
        renderCurrentView();
        showNotification(`${deletedSongPaths.length}曲がライブラリから削除されました。`);
        hideNotification(3000);
    });

    ipcRenderer.on('request-new-playlist-with-songs', (event, songs) => {
        showModal({
            title: '新規プレイリスト作成',
            placeholder: 'プレイリスト名を入力',
            onOk: (playlistName) => {
                if (playlistName && playlistName.trim() !== '') {
                    ipcRenderer.send('create-new-playlist-with-songs', { playlistName, songs });
                }
            }
        });
    });

    // --- ▼▼▼ 新規追加: メタデータ編集モーダル表示 ▼▼▼ ---
    ipcRenderer.on('show-edit-metadata-modal', (event, song) => {
        showEditMetadataModal(song);
    });
    // --- ▲▲▲ ここまで ▲▲▲ ---

    logPerf("Requesting initial data from main process...");
    ipcRenderer.send('request-initial-library');
    ipcRenderer.send('request-initial-play-counts');
    ipcRenderer.send('request-initial-settings');
}