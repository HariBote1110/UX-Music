// src/renderer/js/bridge.js
/**
 * UIとメインプロセスの通信を抽象化するBridge層
 * Wails移行時はこのファイルのみを修正することで、各コンポーネントのロジックを変更せずに移行可能
 */

const api = window.electronAPI;
const { CHANNELS } = api;

export const musicApi = {
    // --- One-way (Send) ---
    requestAppInfo: () => api && api.send(CHANNELS.SEND.REQUEST_APP_INFO),
    appReady: () => api && api.send(CHANNELS.SEND.APP_READY),
    loadLibrary: () => api && api.send(CHANNELS.SEND.LOAD_LIBRARY),
    requestPlaylistsWithArtwork: () => api && api.send(CHANNELS.SEND.REQUEST_PLAYLISTS_WITH_ARTWORK),
    startScanPaths: (paths) => {
        if (!api) return;
        console.log('[Bridge] startScanPaths called', paths);
        api.send(CHANNELS.SEND.START_SCAN_PATHS, paths);
    },
    handleLyricsDrop: (paths) => api && api.send(CHANNELS.SEND.HANDLE_LYRICS_DROP, paths),

    // --- Two-way (Invoke) ---
    getSettings: () => api ? api.invoke(CHANNELS.INVOKE.GET_SETTINGS) : Promise.resolve({}),
    getArtworksDir: () => api ? api.invoke(CHANNELS.INVOKE.GET_ARTWORKS_DIR) : Promise.resolve(''),
    getPlaylistDetails: (name) => api ? api.invoke(CHANNELS.INVOKE.GET_PLAYLIST_DETAILS, name) : Promise.resolve({ songs: [] }),

    // --- Event Listeners (On) ---
    onAppInfoResponse: (callback) => api && api.on(CHANNELS.ON.APP_INFO_RESPONSE, callback),
    onLoadLibrary: (callback) => api && api.on(CHANNELS.ON.LOAD_LIBRARY, callback),
    onSettingsLoaded: (callback) => api && api.on(CHANNELS.ON.SETTINGS_LOADED, callback),
    onPlaylistsUpdated: (callback) => api && api.on(CHANNELS.ON.PLAYLISTS_UPDATED, callback),
    onForceReloadPlaylist: (callback) => api && api.on(CHANNELS.ON.FORCE_RELOAD_PLAYLIST, callback),
    onPlayCountsUpdated: (callback) => api && api.on(CHANNELS.ON.PLAY_COUNTS_UPDATED, callback),
    onNavigateBack: (callback) => api && api.on(CHANNELS.ON.NAVIGATE_BACK, callback),
};
