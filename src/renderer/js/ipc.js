import { playSong } from './playback-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { state } from './state.js';

const startTime = performance.now();
const logPerf = (message) => {
    console.log(`[PERF][IPC] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};
logPerf("ipc.js script execution started.");

export function initIPC(ipcRenderer, callbacks) {
    logPerf("initIPC called.");
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
    ipcRenderer.on('show-loading', (event, text) => {
        callbacks.onShowLoading?.(text);
    });
    ipcRenderer.on('hide-loading', () => {
        callbacks.onHideLoading?.();
    });
    ipcRenderer.on('show-error', (event, message) => {
        callbacks.onShowError?.(message);
    });
    ipcRenderer.on('playlist-import-progress', (event, progress) => {
        callbacks.onPlaylistImportProgress?.(progress);
    });
    ipcRenderer.on('playlist-import-finished', () => {
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
        if (result.success) {
            console.log(`%c[ラウドネス解析完了]%c ${fileName} -> %c${result.loudness.toFixed(2)} LUFS`, 
                'color: green; font-weight: bold;', 
                'color: inherit;',
                'color: blue; font-weight: bold;'
            );
            
            const waitingSong = state.songWaitingForAnalysis;
            if (waitingSong && waitingSong.sourceList[waitingSong.index].path === result.filePath) {
                playSong(waitingSong.index, null, true);
            }

        } else {
            console.error(`[ラウドネス解析失敗] ${fileName}: ${result.error}`);
        }
    });

    ipcRenderer.on('lyrics-added-notification', (event, count) => {
        showNotification(`${count}個の歌詞ファイルが追加されました。`);
        hideNotification(3000);
    });

    logPerf("Requesting initial data from main process...");
    ipcRenderer.send('request-initial-library');
    ipcRenderer.send('request-playlists-with-artwork');
    ipcRenderer.send('request-initial-play-counts');
    ipcRenderer.send('request-initial-settings');
}