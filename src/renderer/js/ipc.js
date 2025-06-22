export function initIPC(ipcRenderer, callbacks) {
    // --- IPCリスナー群 ---
    ipcRenderer.on('load-library', (event, initialSongs) => {
        console.log('[Debug] Received initial library with', initialSongs.length, 'songs.');
        callbacks.onLibraryLoaded(initialSongs);
    });
    ipcRenderer.on('settings-loaded', (event, settings) => {
        console.log('[Debug] Settings loaded.');
        callbacks.onSettingsLoaded(settings);
    });
    ipcRenderer.on('play-counts-updated', (event, counts) => {
        callbacks.onPlayCountsUpdated(counts);
    });
    ipcRenderer.on('youtube-link-processed', (event, newSong) => {
        callbacks.onYoutubeLinkProcessed(newSong);
    });
    ipcRenderer.on('playlists-updated', (event, playlists) => {
        callbacks.onPlaylistsUpdated(playlists);
    });
    // --- 初期データの要求 ---
    console.log('[Debug] Requesting initial data from main process...');
    ipcRenderer.send('request-initial-play-counts');
    ipcRenderer.send('request-initial-settings');
}