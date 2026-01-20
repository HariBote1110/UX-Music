// src/renderer/js/env-setup.js
// Wails などの非 Electron 環境でも動作するように、window.electronAPI を安全化する
const isWails = window.go !== undefined;

window.electronAPI = window.electronAPI || {
    send: (channel, ...args) => {
        if (isWails) {
            console.log(`[Wails-Mock] send: ${channel}`, args);
            if (channel === 'request-initial-library') {
                window.go.main.App.RequestInitialLibrary?.();
            } else if (channel === 'request-initial-play-counts') {
                window.go.main.App.LoadPlayCounts?.();
            } else if (channel === 'request-initial-settings') {
                // GetSettings を呼び出して結果を events-on で模したほうがいいかもしれないが、
                // renderer.js で既に個別に await GetSettings しているので不要な可能性が高い
            }
        }
    },
    on: (channel, callback) => {
        if (isWails && window.runtime && window.runtime.EventsOn) {
            console.log(`[Wails-Mock] on: subscribing to ${channel}`);
            window.runtime.EventsOn(channel, callback);
        }
    },
    invoke: async (channel, ...args) => {
        if (isWails && window.go && window.go.main && window.go.main.App) {
            console.log(`[Wails-Mock] invoke: ${channel}`, args);
            // チャネル名とメソッド名のマッピング
            const mapping = {
                'get-settings': 'GetSettings',
                'get-artworks-dir': 'GetArtworksDir',
                'get-playlist-details': 'GetPlaylistDetails',
            };
            const methodName = mapping[channel];
            if (methodName && window.go.main.App[methodName]) {
                return await window.go.main.App[methodName](...args);
            }
        }
        return Promise.resolve({}); // null ではなく空オブジェクトを返す
    },
    removeAllListeners: () => { },
    CHANNELS: {
        SEND: {
            REQUEST_APP_INFO: 'request-app-info',
            APP_READY: 'app-ready',
            LOAD_LIBRARY: 'load-library',
            REQUEST_INITIAL_LIBRARY: 'request-initial-library',
            REQUEST_INITIAL_PLAY_COUNTS: 'request-initial-play-counts',
            REQUEST_INITIAL_SETTINGS: 'request-initial-settings',
            SAVE_SETTINGS: 'save-settings',
            START_SCAN_PATHS: 'start-scan-paths',
        },
        INVOKE: {
            GET_SETTINGS: 'get-settings',
            GET_ARTWORKS_DIR: 'get-artworks-dir',
            GET_PLAYLIST_DETAILS: 'get-playlist-details',
        },
        ON: {
            APP_INFO_RESPONSE: 'app-info-response',
            LOAD_LIBRARY: 'load-library',
            SETTINGS_LOADED: 'settings-loaded',
            PLAYLISTS_UPDATED: 'playlists-updated',
            FORCE_RELOAD_PLAYLIST: 'force-reload-playlist',
            PLAY_COUNTS_UPDATED: 'play-counts-updated',
            NAVIGATE_BACK: 'navigate-back',
        }
    }
};
