// src/renderer/js/env-setup.js
// Wails などの非 Electron 環境でも動作するように、window.electronAPI を安全化する
const isWailsEnvironment = () => window.go !== undefined || window.runtime !== undefined;

window.electronAPI = window.electronAPI || {
    send: (channel, ...args) => {
        if (isWailsEnvironment()) {
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
            } else if (channel === 'save-settings') {
                window.go.main.App.SaveSettings?.(args[0] || {});
            } else if (channel === 'set-library-path') {
                if (window.go?.main?.App?.SetLibraryPath) {
                    window.go.main.App.SetLibraryPath()
                        .catch((error) => {
                            console.error('[Wails-Mock] set-library-path failed:', error);
                        });
                }
            } else if (channel === 'cd-start-rip') {
                window.go.main.App.CDStartRip?.(args[0]);
            } else if (channel === 'start-normalize-job') {
                const data = args[0] || {};
                window.go.main.App.NormalizeStartJob?.(data.jobType, data.files || [], data.options || {});
            } else if (channel === 'request-loudness-analysis') {
                const filePath = args[0];
                if (window.go?.main?.App?.NormalizeAnalyze && filePath) {
                    window.go.main.App.NormalizeAnalyze(filePath)
                        .then((result) => {
                            if (window.runtime?.EventsEmit) {
                                window.runtime.EventsEmit('loudness-analysis-result', {
                                    ...result,
                                    filePath
                                });
                            }
                        })
                        .catch((error) => {
                            console.error('[Wails-Mock] request-loudness-analysis failed:', error);
                            if (window.runtime?.EventsEmit) {
                                window.runtime.EventsEmit('loudness-analysis-result', {
                                    success: false,
                                    error: error?.message || String(error),
                                    filePath
                                });
                            }
                        });
                }
            } else if (channel === 'normalize-worker-finished-file') {
                // Worker-pool signalling is Electron-specific. Wails side runs with goroutine semaphore.
            }
        }
    },
    on: (channel, callback) => {
        const dynamicallyIsWails = window.go !== undefined || window.runtime !== undefined;
        if (dynamicallyIsWails) {
            if (window.runtime) {
                console.log(`[Wails-Bridge] on: subscribing to ${channel}`);
                window.runtime.EventsOn(channel, callback);
            } else {
                console.warn(`[Wails-Bridge] on: failed to subscribe to ${channel} (window.runtime is missing)`);
                // Wails の実行準備ができるまで待機する仕組みが必要な場合がある
                setTimeout(() => window.electronAPI.on(channel, callback), 100);
            }
        } else {
            console.log(`[Electron-Mock] on: mock subscribing to ${channel}`);
        }
    },
    invoke: async (channel, ...args) => {
        if (isWailsEnvironment() && window.go && window.go.main && window.go.main.App) {
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
                'get-all-loudness-data': async () => {
                    if (window.go?.main?.App?.GetAllLoudnessData) {
                        return await window.go.main.App.GetAllLoudnessData();
                    }
                    return {};
                },
                'get-library-for-normalize': async () => {
                    if (window.go?.main?.App?.GetLibraryForNormalize) {
                        return await window.go.main.App.GetLibraryForNormalize();
                    }
                    return [];
                },
                'select-files-for-normalize': async () => {
                    if (window.go?.main?.App?.SelectFilesForNormalize) {
                        return await window.go.main.App.SelectFilesForNormalize();
                    }
                    return [];
                },
                'select-folder-for-normalize': async () => {
                    if (window.go?.main?.App?.SelectFolderForNormalize) {
                        return await window.go.main.App.SelectFolderForNormalize();
                    }
                    return [];
                },
                'select-normalize-output-folder': async () => {
                    if (window.go?.main?.App?.SelectNormalizeOutputFolder) {
                        return await window.go.main.App.SelectNormalizeOutputFolder();
                    }
                    return null;
                },
                'get-lyrics': async (song) => {
                    if (!window.go?.main?.App?.GetLyrics) return null;

                    const candidates = [];
                    const songPath = typeof song?.path === 'string' ? song.path.trim() : '';
                    const songTitle = typeof song?.title === 'string' ? song.title.trim() : '';

                    if (songPath) {
                        const fileName = songPath.split(/[\\/]/).pop() || '';
                        const dotIndex = fileName.lastIndexOf('.');
                        const baseName = dotIndex > 0 ? fileName.slice(0, dotIndex) : fileName;
                        if (baseName.trim()) {
                            candidates.push(baseName.trim());
                        }
                    }
                    if (songTitle) {
                        candidates.push(songTitle);
                    }

                    const uniqueCandidates = [...new Set(candidates)];
                    for (const candidate of uniqueCandidates) {
                        const result = await window.go.main.App.GetLyrics(candidate);
                        if (result && (result.type === 'lrc' || result.type === 'txt')) {
                            return result;
                        }
                    }

                    return null;
                },
                'save-lrc-file': async (data) => {
                    if (!window.go?.main?.App?.SaveLrcFile) {
                        return { success: false, message: 'SaveLrcFile が利用できません' };
                    }

                    const fileName = typeof data?.fileName === 'string' ? data.fileName : '';
                    const content = typeof data?.content === 'string' ? data.content : '';

                    try {
                        await window.go.main.App.SaveLrcFile(fileName, content);
                        return { success: true };
                    } catch (error) {
                        return {
                            success: false,
                            message: error?.message || String(error),
                        };
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
                },
                'cd-scan': async () => {
                    if (window.go?.main?.App?.CDScan) {
                        try {
                            const tracks = await window.go.main.App.CDScan();
                            return { success: true, tracks: tracks };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDScan not available' };
                },
                'cd-search-toc': async (tracks) => {
                    if (window.go?.main?.App?.CDSearchTOC) {
                        try {
                            const releases = await window.go.main.App.CDSearchTOC(tracks);
                            return { success: true, releases: releases };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDSearchTOC not available' };
                },
                'cd-search-text': async (query) => {
                    if (window.go?.main?.App?.CDSearchText) {
                        try {
                            const releases = await window.go.main.App.CDSearchText(query);
                            return { success: true, releases: releases };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDSearchText not available' };
                },
                'cd-apply-metadata': async (data) => {
                    if (window.go?.main?.App?.CDApplyMetadata) {
                        try {
                            const info = await window.go.main.App.CDApplyMetadata(data);
                            // Map fields: Go Title -> JS album
                            return {
                                success: true,
                                tracks: info.tracks,
                                album: info.title,
                                artist: info.artist,
                                artwork: info.artwork
                            };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDApplyMetadata not available' };
                },
                'cd-start-rip': async (data) => {
                    // This is usually called via send, but if invoked:
                    if (window.go?.main?.App?.CDStartRip) {
                        return await window.go.main.App.CDStartRip(data);
                    }
                    return { success: false, error: 'CDStartRip not available' };
                },
                // --- MTP ---
                'mtp-initialize': async () => {
                    return await window.go.main.App.MTPInitialize?.();
                },
                'mtp-fetch-device-info': async () => {
                    return await window.go.main.App.MTPFetchDeviceInfo?.();
                },
                'mtp-list-storages': async () => {
                    return await window.go.main.App.MTPFetchStorages?.();
                },
                'mtp-browse-directory': async (data) => {
                    // data: { storageId, fullPath, ... } -> WalkOptions is struct
                    // Go expects generic map if from JS? 
                    // Wails maps JS object to Struct automatically if fields match?
                    // Yes.
                    return await window.go.main.App.MTPWalk?.(data);
                },
                'mtp-upload-files': async (data) => {
                    return await window.go.main.App.MTPUploadFiles?.(data);
                },
                'mtp-upload-files-with-structure': async (data) => {
                    return await window.go.main.App.MTPUploadFilesWithStructure?.(data);
                },
                'mtp-download-files': async (data) => {
                    return await window.go.main.App.MTPDownloadFiles?.(data);
                },
                'mtp-get-untransferred-songs': async (data) => {
                    return await window.go.main.App.MTPGetUntransferredSongs?.(data.librarySongs);
                },
                'mtp-get-status': async () => {
                    return await window.go.main.App.MTPGetStatus?.();
                },
                'mtp-delete-files': async (data) => {
                    return await window.go.main.App.MTPDeleteFile?.(data);
                },
                'mtp-make-directory': async (data) => {
                    return await window.go.main.App.MTPMakeDirectory?.(data);
                },
                'mtp-dispose': async () => {
                    return await window.go.main.App.MTPDispose?.();
                },
                // --- Normalize ---
                'start-normalize-job': async (data) => {
                    // data: { jobType, files, options }
                    if (window.go?.main?.App?.NormalizeStartJob) {
                        // NormalizeStartJob(jobType string, files []interface{}, options OutputSettings)
                        // data.jobType, data.files, data.options
                        return await window.go.main.App.NormalizeStartJob(data.jobType, data.files, data.options);
                    }
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
