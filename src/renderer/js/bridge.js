// src/renderer/js/bridge.js
/**
 * UIとメインプロセスの通信を抽象化するBridge層
 * Wails移行時はこのファイルのみを修正することで、各コンポーネントのロジックを変更せずに移行可能
 */

const { CHANNELS } = window.electronAPI;

export const musicApi = {
    // --- One-way (Send) ---
    requestAppInfo: () => window.electronAPI.send(CHANNELS.SEND.REQUEST_APP_INFO),
    appReady: () => window.electronAPI.send(CHANNELS.SEND.APP_READY),
    loadLibrary: () => window.electronAPI.send(CHANNELS.SEND.LOAD_LIBRARY),
    requestPlaylistsWithArtwork: () => window.electronAPI.send(CHANNELS.SEND.REQUEST_PLAYLISTS_WITH_ARTWORK),
    startScanPaths: (paths) => {
        console.log('[Bridge] startScanPaths called', paths);
        console.log('[Bridge] CHANNELS.SEND.START_SCAN_PATHS =', CHANNELS.SEND.START_SCAN_PATHS);
        console.log('[Bridge] window.electronAPI =', window.electronAPI);
        window.electronAPI.send(CHANNELS.SEND.START_SCAN_PATHS, paths);
    },
    handleLyricsDrop: (paths) => window.electronAPI.send(CHANNELS.SEND.HANDLE_LYRICS_DROP, paths),

    // --- Two-way (Invoke) ---
    getSettings: () => window.electronAPI.invoke(CHANNELS.INVOKE.GET_SETTINGS),
    getArtworksDir: () => window.electronAPI.invoke(CHANNELS.INVOKE.GET_ARTWORKS_DIR),
    getPlaylistDetails: (name) => window.electronAPI.invoke(CHANNELS.INVOKE.GET_PLAYLIST_DETAILS, name),

    // --- Event Listeners (On) ---
    onAppInfoResponse: (callback) => window.electronAPI.on(CHANNELS.ON.APP_INFO_RESPONSE, callback),
    onLoadLibrary: (callback) => window.electronAPI.on(CHANNELS.ON.LOAD_LIBRARY, callback),
    onSettingsLoaded: (callback) => window.electronAPI.on(CHANNELS.ON.SETTINGS_LOADED, callback),
    onPlaylistsUpdated: (callback) => window.electronAPI.on(CHANNELS.ON.PLAYLISTS_UPDATED, callback),
    onForceReloadPlaylist: (callback) => window.electronAPI.on(CHANNELS.ON.FORCE_RELOAD_PLAYLIST, callback),
    onPlayCountsUpdated: (callback) => window.electronAPI.on(CHANNELS.ON.PLAY_COUNTS_UPDATED, callback),
    onNavigateBack: (callback) => window.electronAPI.on(CHANNELS.ON.NAVIGATE_BACK, callback),
};
