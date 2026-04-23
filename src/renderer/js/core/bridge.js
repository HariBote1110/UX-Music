// src/renderer/js/core/bridge.js
/**
 * UI と Go App の通信（Wails 専用）
 */

import { getApp } from './api/app.js';
import { eventsOn } from './api/runtime-events.js';
import { fetchLyricsForSong } from './api/lyrics.js';

const EV = {
    APP_INFO_RESPONSE: 'app-info-response',
    LOAD_LIBRARY: 'load-library',
    SETTINGS_LOADED: 'settings-loaded',
    PLAYLISTS_UPDATED: 'playlists-updated',
    FORCE_RELOAD_PLAYLIST: 'force-reload-playlist',
    PLAY_COUNTS_UPDATED: 'play-counts-updated',
    NAVIGATE_BACK: 'navigate-back',
};

export const musicApi = {
    requestAppInfo: () => Promise.resolve({ version: '0.1.9-Beta-9h', platform: typeof navigator !== 'undefined' ? navigator.platform : 'unknown' }),
    appReady: () => {},
    loadLibrary: () => getApp()?.LoadLibrary?.(),
    requestPlaylistsWithArtwork: () => getApp()?.RequestPlaylistsWithArtwork?.(),
    startScanPaths: (paths) => {
        console.log('[Bridge] startScanPaths called', paths);
        return getApp()?.ScanLibrary?.(paths);
    },
    handleLyricsDrop: (paths) => getApp()?.HandleLyricsDrop?.(paths),
    requestInitialPlayCounts: () => getApp()?.LoadPlayCounts?.(),
    playbackStarted: (song) => getApp()?.IncrementPlayCount?.(song),
    songFinished: (song) => getApp()?.SongFinished?.(song),
    songSkipped: (data) => getApp()?.SongSkipped?.(data),

    getSettings: async () => {
        const app = getApp();
        if (!app?.GetSettings) return {};
        return await app.GetSettings();
    },
    saveSettings: (settings) => getApp()?.SaveSettings?.(settings),
    addSongsToPlaylist: (data) => getApp()?.AddSongsToPlaylist?.(data),
    addAlbumToPlaylist: (data) => getApp()?.AddAlbumToPlaylist?.(data),
    getArtworksDir: () => {
        const app = getApp();
        if (!app?.GetArtworksDir) return Promise.resolve('');
        return app.GetArtworksDir();
    },
    getPlaylistDetails: (name) => {
        const app = getApp();
        if (!app?.GetPlaylistDetails) return Promise.resolve({ songs: [] });
        return app.GetPlaylistDetails(name);
    },
    getLyrics: (song) => fetchLyricsForSong(song),
    getSituationPlaylists: () => {
        const app = getApp();
        if (!app?.GetSituationPlaylists) return Promise.resolve({});
        return app.GetSituationPlaylists();
    },
    getPerformanceSnapshot: () => getApp()?.GetPerformanceSnapshot?.() ?? Promise.resolve(null),
    createPlaylist: (name) => getApp()?.CreatePlaylist?.(name),
    renamePlaylist: (data) => getApp()?.RenamePlaylist?.(data),
    deletePlaylist: (name) => getApp()?.DeletePlaylist?.(name),
    buildFLACIndexes: () => getApp()?.BuildFLACIndexes?.(),

    onAppInfoResponse: (callback) => eventsOn(EV.APP_INFO_RESPONSE, callback),
    onLoadLibrary: (callback) => eventsOn(EV.LOAD_LIBRARY, callback),
    onSettingsLoaded: (callback) => eventsOn(EV.SETTINGS_LOADED, callback),
    onPlaylistsUpdated: (callback) => eventsOn(EV.PLAYLISTS_UPDATED, callback),
    onForceReloadPlaylist: (callback) => eventsOn(EV.FORCE_RELOAD_PLAYLIST, callback),
    onPlayCountsUpdated: (callback) => eventsOn(EV.PLAY_COUNTS_UPDATED, callback),
    onNavigateBack: (callback) => eventsOn(EV.NAVIGATE_BACK, callback),
};
