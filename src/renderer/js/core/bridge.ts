// src/renderer/js/bridge.ts
/**
 * UIとメインプロセスの通信を抽象化するBridge層
 * Wails移行時はこのファイルのみを修正することで、各コンポーネントのロジックを変更せずに移行可能
 *
 * `window.go` が存在しても `server.App` / `main.App` は注入タイミングまで未定義になり得るため、
 * バインドの有無は毎回 `getWailsApp()` で判定する（モジュール読み込み時の真偽に依存しない）。
 */

import type {
  AddSongsToPlaylistPayload,
  RenamePlaylistPayload,
  Song,
  SongSkippedPayload,
} from '../../types/domain.js';

const api = window.electronAPI;
const { CHANNELS } = api;

/** Go バインディング（`package server` → `window.go.server.App` を優先）。 */
export function getWailsApp() {
  return window.go?.server?.App ?? window.go?.main?.App;
}

/** True when Wails Go bindings are available (not pure Electron). */
export function isWailsMode() {
  return getWailsApp() != null;
}

export const musicApi = {
  // --- One-way (Send) ---
  requestAppInfo: () => {
    if (getWailsApp()) {
      return Promise.resolve({ version: '0.1.9-Beta-17b', platform: 'darwin' });
    }
    return api && api.send(CHANNELS.SEND.REQUEST_APP_INFO);
  },
  appReady: () => api && api.send(CHANNELS.SEND.APP_READY),
  loadLibrary: () => {
    const app = getWailsApp();
    if (app) {
      return app.LoadLibrary();
    }
    return api && api.send(CHANNELS.SEND.LOAD_LIBRARY);
  },
  requestPlaylistsWithArtwork: () => {
    const app = getWailsApp();
    if (app) {
      return app.RequestPlaylistsWithArtwork?.();
    }
    return api && api.send(CHANNELS.SEND.REQUEST_PLAYLISTS_WITH_ARTWORK);
  },
  startScanPaths: (paths: string[]) => {
    const app = getWailsApp();
    if (app) {
      return app.ScanLibrary(paths);
    }
    if (!api) return;
    console.log('[Bridge] startScanPaths called', paths);
    api.send(CHANNELS.SEND.START_SCAN_PATHS, paths);
  },
  handleLyricsDrop: (paths: string[]) => {
    const app = getWailsApp();
    if (app) {
      return app.HandleLyricsDrop(paths);
    }
    return api && api.send(CHANNELS.SEND.HANDLE_LYRICS_DROP, paths);
  },
  requestInitialPlayCounts: () => {
    const app = getWailsApp();
    if (app) {
      return app.LoadPlayCounts();
    }
    return api && api.send(CHANNELS.SEND.REQUEST_INITIAL_PLAY_COUNTS);
  },
  playbackStarted: (song: Song) => {
    const app = getWailsApp();
    if (app) {
      return app.IncrementPlayCount(song as Record<string, unknown>);
    }
    return api && api.send(CHANNELS.SEND.PLAYBACK_STARTED, song);
  },
  songFinished: (song: Song) => {
    const app = getWailsApp();
    if (app) {
      return app.SongFinished(song as Record<string, unknown>);
    }
    return api && api.send(CHANNELS.SEND.SONG_FINISHED, song);
  },
  songSkipped: (data: SongSkippedPayload) => {
    const app = getWailsApp();
    if (app) {
      return app.SongSkipped(data as Record<string, unknown>);
    }
    return api && api.send(CHANNELS.SEND.SONG_SKIPPED, data);
  },

  // --- Two-way (Invoke) ---
  getSettings: async () => {
    const app = getWailsApp();
    if (app) {
      return (await app.GetSettings()) ?? {};
    }
    return api ? api.invoke(CHANNELS.INVOKE.GET_SETTINGS) : Promise.resolve({});
  },
  saveSettings: (settings: Record<string, unknown>) => {
    const app = getWailsApp();
    if (app) {
      return app.SaveSettings(settings);
    }
    return api && api.send(CHANNELS.SEND.SAVE_SETTINGS, settings);
  },
  addSongsToPlaylist: (data: AddSongsToPlaylistPayload) => {
    const app = getWailsApp();
    if (app) {
      return app.AddSongsToPlaylist(data as Record<string, unknown>);
    }
    return api && api.invoke(CHANNELS.INVOKE.ADD_SONGS_TO_PLAYLIST, data);
  },
  getArtworksDir: () => {
    const app = getWailsApp();
    if (app) {
      return app.GetArtworksDir();
    }
    return api ? api.invoke(CHANNELS.INVOKE.GET_ARTWORKS_DIR) : Promise.resolve('');
  },
  getPlaylistDetails: (name: string) => {
    const app = getWailsApp();
    if (app) {
      return app.GetPlaylistDetails(name);
    }
    return api ? api.invoke(CHANNELS.INVOKE.GET_PLAYLIST_DETAILS, name) : Promise.resolve({ songs: [] });
  },
  getLyrics: (song: Song) => {
    const app = getWailsApp();
    if (app) {
      return app.GetLyrics(song.title ?? '');
    }
    return api && api.invoke('get-lyrics', song);
  },
  getSituationPlaylists: () => {
    const app = getWailsApp();
    if (app) {
      return app.GetSituationPlaylists();
    }
    return api && api.invoke('get-situation-playlists');
  },
  getPerformanceSnapshot: () => {
    const app = getWailsApp();
    if (app) {
      return app.GetPerformanceSnapshot?.();
    }
    return Promise.resolve(null);
  },
  createPlaylist: (name: string) => {
    const app = getWailsApp();
    if (app) {
      return app.CreatePlaylist(name);
    }
    return api && api.invoke('create-playlist', name);
  },
  renamePlaylist: (data: RenamePlaylistPayload) => {
    const app = getWailsApp();
    if (app) {
      return app.RenamePlaylist(data as Record<string, unknown>);
    }
    return api && api.invoke('rename-playlist', data);
  },
  deletePlaylist: (name: string) => {
    const app = getWailsApp();
    if (app) {
      return app.DeletePlaylist(name);
    }
    return api && api.invoke('delete-playlist', name);
  },
  buildFLACIndexes: () => {
    const app = getWailsApp();
    if (app) {
      return app.BuildFLACIndexes();
    }
    return api && api.send('build-flac-indexes');
  },
  discoverSyncDevices: (timeoutMs = 2500) => {
    const app = getWailsApp();
    if (app?.DiscoverSyncDevices) {
      return app.DiscoverSyncDevices(timeoutMs);
    }
    return Promise.resolve([]);
  },
  startSyncPairing: (baseUrl: string) => {
    const app = getWailsApp();
    if (app?.StartSyncPairing) {
      return app.StartSyncPairing(baseUrl);
    }
    return Promise.reject(new Error('UX Sync ペアリングはこの環境では利用できません。'));
  },
  confirmSyncPairing: (baseUrl: string, sessionId: string, code: string, expectedRemoteDeviceId: string) => {
    const app = getWailsApp();
    if (app?.ConfirmSyncPairing) {
      return app.ConfirmSyncPairing(baseUrl, sessionId, code, expectedRemoteDeviceId);
    }
    return Promise.reject(new Error('UX Sync ペアリングはこの環境では利用できません。'));
  },

  // --- Event Listeners (On) ---
  onAppInfoResponse: (callback: (info: { version?: string; platform?: string }) => void) =>
    api && api.on(CHANNELS.ON.APP_INFO_RESPONSE, callback),
  onLoadLibrary: (callback: (data: unknown) => void) => api && api.on(CHANNELS.ON.LOAD_LIBRARY, callback),
  onSettingsLoaded: (callback: (settings: unknown) => void) => api && api.on(CHANNELS.ON.SETTINGS_LOADED, callback),
  onPlaylistsUpdated: (callback: (playlists: unknown) => void) => api && api.on(CHANNELS.ON.PLAYLISTS_UPDATED, callback),
  onForceReloadPlaylist: (callback: (name: string) => void) =>
    api &&
    api.on(CHANNELS.ON.FORCE_RELOAD_PLAYLIST, (...args: unknown[]) => {
      callback(String(args[0] ?? ''));
    }),
  onPlayCountsUpdated: (callback: (counts: unknown) => void) => api && api.on(CHANNELS.ON.PLAY_COUNTS_UPDATED, callback),
  onNavigateBack: (callback: () => void) => api && api.on(CHANNELS.ON.NAVIGATE_BACK, callback),
};
