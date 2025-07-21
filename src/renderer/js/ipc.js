export function initIPC(ipcRenderer, callbacks) {
    // --- IPCリスナー群 ---
    ipcRenderer.on('load-library', (event, initialSongs) => {
        console.log('[Debug] Received initial library with', initialSongs ? initialSongs.length : 0, 'songs.');
        callbacks.onLibraryLoaded?.(initialSongs);
    });
    ipcRenderer.on('settings-loaded', (event, settings) => {
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

    // --- 初期データの要求 ---
    console.log('[Debug] Requesting initial data from main process...');
    ipcRenderer.send('request-initial-library');
    ipcRenderer.send('request-playlists-with-artwork');
    ipcRenderer.send('request-initial-play-counts');
    ipcRenderer.send('request-initial-settings');
}