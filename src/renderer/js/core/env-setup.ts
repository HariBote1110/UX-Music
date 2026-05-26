// src/renderer/js/env-setup.js
// Wails などの非 Electron 環境でも動作するように、window.electronAPI を安全化する
import { errorMessage, readRecord, youtubeUrlFromPayload } from '../utils/type-guards.js';

const isWailsEnvironment = () => window.go !== undefined || window.runtime !== undefined;

window.electronAPI = window.electronAPI || {
    send: (channel: string, ...args: unknown[]) => {
        if (isWailsEnvironment()) {
            const app = window.go?.server?.App ?? window.go?.main?.App;
            if (!app) {
                return;
            }
            console.log(`[Wails-Mock] send: ${channel}`, args);
            if (channel === 'request-initial-library') {
                app.RequestInitialLibrary?.();
            } else if (channel === 'request-initial-play-counts') {
                app.LoadPlayCounts?.();
            } else if (channel === 'handle-lyrics-drop') {
                app.HandleLyricsDrop?.(args[0] as string[]);
            } else if (channel === 'request-initial-settings') {
                app.GetSettings?.().then((settings: unknown) => {
                    if (window.runtime) window.runtime.EventsEmit('settings-loaded', settings);
                });
            } else if (channel === 'save-settings') {
                app.SaveSettings?.(args[0] || {});
            } else if (channel === 'add-youtube-link') {
                const payload = args[0];
                const url = youtubeUrlFromPayload(payload);
                console.log('[YouTube][Wails-Mock] add-youtube-link payload:', payload);
                if (!url) {
                    window.runtime?.EventsEmit?.('show-notification', 'YouTubeのURLが空です。');
                    return;
                }
                if (!app?.AddYouTubeLink) {
                    window.runtime?.EventsEmit?.('show-notification', 'YouTubeダウンロード機能が利用できません。');
                    return;
                }
                window.runtime?.EventsEmit?.('show-notification', 'YouTube動画をダウンロードしています...');
                app.AddYouTubeLink(payload).then((result: unknown) => {
                    console.log('[YouTube][Wails-Mock] AddYouTubeLink completed:', result);
                }).catch((error: unknown) => {
                    const message = errorMessage(error);
                    console.error('[YouTube][Wails-Mock] AddYouTubeLink failed:', message);
                    window.runtime?.EventsEmit?.('show-notification', `YouTube楽曲の処理に失敗しました: ${message}`);
                });
            } else if (channel === 'set-library-path') {
                if (app.SetLibraryPath) {
                    app.SetLibraryPath()
                        .catch((error: unknown) => {
                            console.error('[Wails-Mock] set-library-path failed:', error);
                        });
                }
            } else if (channel === 'cd-start-rip') {
                app.CDStartRip?.(args[0]);
            } else if (channel === 'start-normalize-job') {
                const data = readRecord(args[0]);
                app.NormalizeStartJob?.(
                    String(data.jobType ?? ''),
                    (Array.isArray(data.files) ? data.files : []) as unknown[],
                    data.options ?? {}
                );
            } else if (channel === 'request-loudness-analysis') {
                const filePath = args[0];
                if (app.NormalizeAnalyze && filePath) {
                    app.NormalizeAnalyze(filePath as string)
                        .then((result) => {
                            if (window.runtime?.EventsEmit) {
                                window.runtime.EventsEmit('loudness-analysis-result', {
                                    ...result,
                                    filePath
                                });
                            }
                        })
                        .catch((error: unknown) => {
                            console.error('[Wails-Mock] request-loudness-analysis failed:', error);
                            if (window.runtime?.EventsEmit) {
                                window.runtime.EventsEmit('loudness-analysis-result', {
                                    success: false,
                                    error: errorMessage(error),
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
    on: (channel: string, callback: (...args: unknown[]) => void) => {
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
    invoke: async (channel: string, ...args: unknown[]) => {
        const app = window.go?.server?.App ?? window.go?.main?.App;
        if (isWailsEnvironment() && app) {
            console.log(`[Wails-Mock] invoke: ${channel}`, args);

            const dispatch = {
                'get-settings': async () => {
                    if (app.GetSettings) {
                        return (await app.GetSettings()) ?? {};
                    }
                    return {};
                },
                'get-artworks-dir': async () => {
                    if (app?.GetArtworksDir) {
                        return await app.GetArtworksDir();
                    }
                    return '';
                },
                'get-playlist-details': async (name) => {
                    if (app?.GetPlaylistDetails) {
                        return await app.GetPlaylistDetails(name);
                    }
                    return { songs: [] };
                },
                'get-situation-playlists': async () => {
                    if (app?.GetSituationPlaylists) {
                        return await app.GetSituationPlaylists();
                    }
                    return {};
                },
                'rename-playlist': async (data) => {
                    if (app?.RenamePlaylist) {
                        return await app.RenamePlaylist(data);
                    }
                },
                'delete-playlist': async (name) => {
                    if (app?.DeletePlaylist) {
                        return await app.DeletePlaylist(name);
                    }
                },
                'create-playlist': async (name) => {
                    if (app?.CreatePlaylist) {
                        return await app.CreatePlaylist(name);
                    }
                },
                'update-playlist-song-order': async (data) => {
                    if (app?.UpdatePlaylistSongOrder) {
                        return await app.UpdatePlaylistSongOrder(data);
                    }
                },
                'add-songs-to-playlist': async (data) => {
                    if (app?.AddSongsToPlaylist) {
                        return await app.AddSongsToPlaylist(data);
                    }
                },
                'add-album-to-playlist': async (data) => {
                    if (app?.AddAlbumToPlaylist) {
                        return await app.AddAlbumToPlaylist(data);
                    }
                },
                'get-all-playlists': async () => {
                    if (app?.GetAllPlaylists) {
                        return await app.GetAllPlaylists();
                    }
                },
                'get-loudness-value': async (path) => {
                    if (app?.GetLoudnessValue) {
                        return await app.GetLoudnessValue(path);
                    }
                },
                'get-all-loudness-data': async () => {
                    if (app?.GetAllLoudnessData) {
                        return await app.GetAllLoudnessData();
                    }
                    return {};
                },
                'get-library-for-normalize': async () => {
                    if (app?.GetLibraryForNormalize) {
                        return await app.GetLibraryForNormalize();
                    }
                    return [];
                },
                'select-files-for-normalize': async () => {
                    if (app?.SelectFilesForNormalize) {
                        return await app.SelectFilesForNormalize();
                    }
                    return [];
                },
                'select-folder-for-normalize': async () => {
                    if (app?.SelectFolderForNormalize) {
                        return await app.SelectFolderForNormalize();
                    }
                    return [];
                },
                'select-normalize-output-folder': async () => {
                    if (app?.SelectNormalizeOutputFolder) {
                        return await app.SelectNormalizeOutputFolder();
                    }
                    return null;
                },
                'get-lyrics': async (song) => {
                    if (!app?.GetLyrics) return null;

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
                        const result = await app.GetLyrics(candidate);
                        if (result && (result.type === 'lrc' || result.type === 'txt')) {
                            return result;
                        }
                    }

                    return null;
                },
                'save-lrc-file': async (data) => {
                    if (!app?.SaveLrcFile) {
                        return { success: false, message: 'SaveLrcFile が利用できません' };
                    }

                    const fileName = typeof data?.fileName === 'string' ? data.fileName : '';
                    const content = typeof data?.content === 'string' ? data.content : '';

                    try {
                        await app.SaveLrcFile(fileName, content);
                        return { success: true };
                    } catch (error: unknown) {
                        return {
                            success: false,
                            message: errorMessage(error),
                        };
                    }
                },
                'lyrics-auto-sync': async (data) => {
                    if (!app?.AutoSyncLyrics) {
                        return { success: false, error: 'AutoSyncLyrics が利用できません' };
                    }
                    try {
                        return await app.AutoSyncLyrics(data || {});
                    } catch (error: unknown) {
                        return {
                            success: false,
                            error: errorMessage(error),
                        };
                    }
                },
                'get-artwork-as-data-url': async (filename) => {
                    if (app?.GetArtworkAsDataURL) {
                        return await app.GetArtworkAsDataURL(filename);
                    }
                    return null;
                },
                'get-youtube-info': async (url) => {
                    if (app?.GetYouTubeInfo) {
                        console.log('[YouTube][Wails-Mock] GetYouTubeInfo request:', url);
                        const info = await app.GetYouTubeInfo(url);
                        console.log('[YouTube][Wails-Mock] GetYouTubeInfo response:', info);
                        return info;
                    }
                    return null;
                },
                'cd-scan': async () => {
                    if (app?.CDScan) {
                        try {
                            const tracks = await app.CDScan();
                            return { success: true, tracks: tracks };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDScan not available' };
                },
                'cd-search-toc': async (tracks) => {
                    if (app?.CDSearchTOC) {
                        try {
                            const releases = await app.CDSearchTOC(tracks);
                            return { success: true, releases: releases };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDSearchTOC not available' };
                },
                'cd-search-text': async (query) => {
                    if (app?.CDSearchText) {
                        try {
                            const releases = await app.CDSearchText(query);
                            return { success: true, releases: releases };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDSearchText not available' };
                },
                'cd-apply-metadata': async (data) => {
                    if (app?.CDApplyMetadata) {
                        try {
                            const info = await app.CDApplyMetadata(data);
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
                'cd-search-vocadb': async (query) => {
                    if (app?.CDSearchVocaDB) {
                        try {
                            const releases = await app.CDSearchVocaDB(query);
                            return { success: true, releases: releases };
                        } catch (e) {
                            return { success: false, message: e || 'Unknown error' };
                        }
                    }
                    return { success: false, message: 'CDSearchVocaDB not available' };
                },
                'cd-apply-vocadb-metadata': async (data) => {
                    if (app?.CDApplyVocaDBMetadata) {
                        try {
                            const info = await app.CDApplyVocaDBMetadata(data);
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
                    return { success: false, message: 'CDApplyVocaDBMetadata not available' };
                },
                'cd-start-rip': async (data) => {
                    // This is usually called via send, but if invoked:
                    if (app?.CDStartRip) {
                        return await app.CDStartRip(data);
                    }
                    return { success: false, error: 'CDStartRip not available' };
                },
                // --- MTP ---
                'mtp-initialize': async () => {
                    return await app.MTPInitialize?.();
                },
                'mtp-fetch-device-info': async () => {
                    return await app.MTPFetchDeviceInfo?.();
                },
                'mtp-list-storages': async () => {
                    return await app.MTPFetchStorages?.();
                },
                'mtp-browse-directory': async (data) => {
                    // data: { storageId, fullPath, ... } -> WalkOptions is struct
                    // Go expects generic map if from JS? 
                    // Wails maps JS object to Struct automatically if fields match?
                    // Yes.
                    return await app.MTPWalk?.(data);
                },
                'mtp-upload-files': async (data) => {
                    return await app.MTPUploadFiles?.(data);
                },
                'mtp-upload-files-with-structure': async (data) => {
                    return await app.MTPUploadFilesWithStructure?.(data);
                },
                'mtp-download-files': async (data) => {
                    return await app.MTPDownloadFiles?.(data);
                },
                'mtp-get-untransferred-songs': async (data: unknown) => {
                    const payload = readRecord(data);
                    const lib = payload.librarySongs;
                    return await app.MTPGetUntransferredSongs?.(
                        Array.isArray(lib) ? lib : []
                    );
                },
                'mtp-get-status': async () => {
                    return await app.MTPGetStatus?.();
                },
                'mtp-delete-files': async (data) => {
                    return await app.MTPDeleteFile?.(data);
                },
                'mtp-make-directory': async (data) => {
                    return await app.MTPMakeDirectory?.(data);
                },
                'mtp-dispose': async () => {
                    return await app.MTPDispose?.();
                },
                // --- Normalize ---
                'start-normalize-job': async (data) => {
                    // data: { jobType, files, options }
                    if (app?.NormalizeStartJob) {
                        // NormalizeStartJob(jobType string, files []interface{}, options OutputSettings)
                        // data.jobType, data.files, data.options
                        return await app.NormalizeStartJob(data.jobType, data.files, data.options);
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
