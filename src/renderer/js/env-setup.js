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
            } else if (channel === 'handle-lyrics-drop') {
                window.go.main.App.HandleLyricsDrop?.(args[0]);
            } else if (channel === 'request-initial-settings') {
                window.go.main.App.GetSettings?.().then(settings => {
                    if (window.runtime) window.runtime.EventsEmit('settings-loaded', settings);
                });
            }
        }
    },
    on: (channel, callback) => {
        if (isWails && window.runtime) {
            console.log(`[Wails-Mock] on: subscribing to ${channel}`);
            window.runtime.EventsOn(channel, callback);
        }
    },
    invoke: async (channel, ...args) => {
        if (isWails && window.go && window.go.main && window.go.main.App) {
            console.log(`[Wails-Mock] invoke: ${channel}`, args);

            const dispatch = {
                'get-settings': async () => {
                    if (window.go?.main?.App?.GetSettings) {
                        return await window.go.main.App.GetSettings();
                    }
                    return {};
                },
                'get-artworks-dir': async () => {
                    if (window.go?.main?.App?.GetArtworksDir) {
                        return await window.go.main.App.GetArtworksDir();
                    }
                    return '';
                },
                'get-playlist-details': async (name) => {
                    if (window.go?.main?.App?.GetPlaylistDetails) {
                        return await window.go.main.App.GetPlaylistDetails(name);
                    }
                    return { songs: [] };
                },
                'get-situation-playlists': async () => {
                    if (window.go?.main?.App?.GetSituationPlaylists) {
                        return await window.go.main.App.GetSituationPlaylists();
                    }
                    return {};
                },
                'rename-playlist': async (data) => {
                    if (window.go?.main?.App?.RenamePlaylist) {
                        return await window.go.main.App.RenamePlaylist(data);
                    }
                },
                'delete-playlist': async (name) => {
                    if (window.go?.main?.App?.DeletePlaylist) {
                        return await window.go.main.App.DeletePlaylist(name);
                    }
                },
                'create-playlist': async (name) => {
                    if (window.go?.main?.App?.CreatePlaylist) {
                        return await window.go.main.App.CreatePlaylist(name);
                    }
                },
                'update-playlist-song-order': async (data) => {
                    if (window.go?.main?.App?.UpdatePlaylistSongOrder) {
                        return await window.go.main.App.UpdatePlaylistSongOrder(data);
                    }
                },
                'add-songs-to-playlist': async (data) => {
                    if (window.go?.main?.App?.AddSongsToPlaylist) {
                        return await window.go.main.App.AddSongsToPlaylist(data);
                    }
                },
                'add-album-to-playlist': async (data) => {
                    if (window.go?.main?.App?.AddAlbumToPlaylist) {
                        return await window.go.main.App.AddAlbumToPlaylist(data);
                    }
                },
                'get-all-playlists': async () => {
                    if (window.go?.main?.App?.GetAllPlaylists) {
                        return await window.go.main.App.GetAllPlaylists();
                    }
                },
                'get-loudness-value': async (path) => {
                    if (window.go?.main?.App?.GetLoudnessValue) {
                        return await window.go.main.App.GetLoudnessValue(path);
                    }
                },
                'get-lyrics': async (song) => {
                    if (window.go?.main?.App?.GetLyrics) {
                        // Go 側は string を受け取るのでタイトルを渡す
                        return await window.go.main.App.GetLyrics(song?.title || '');
                    }
                },
                'save-lrc-file': async (data) => {
                    if (window.go?.main?.App?.SaveLrcFile) {
                        return await window.go.main.App.SaveLrcFile(data.fileName, data.content);
                    }
                },
                'get-artwork-as-data-url': async (filename) => {
                    if (window.go?.main?.App?.GetArtworkAsDataURL) {
                        return await window.go.main.App.GetArtworkAsDataURL(filename);
                    }
                    return null;
                },
                'get-youtube-info': async (url) => {
                    if (window.go?.main?.App?.GetYouTubeInfo) {
                        return await window.go.main.App.GetYouTubeInfo(url);
                    }
                    return null;
                }
            };

            if (dispatch[channel]) {
                return await dispatch[channel](...args);
            }
        }
        return Promise.resolve(null); // オブジェクトではなく null を返すことで [object Object] を防ぐ
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
