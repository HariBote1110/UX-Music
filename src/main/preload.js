const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
    // ipcRenderer の主要な機能をラップして公開
    send: (channel, ...args) => {
        const validChannels = [
            'request-app-info', 'app-ready', 'load-library', 'request-initial-library',
            'request-initial-play-counts', 'request-initial-settings', 'save-settings',
            'start-scan-paths', 'set-library-path', 'handle-lyrics-drop', 'debug-reset-library',
            'debug-rollback-migration', 'save-migrated-data', 'song-finished', 'playback-stopped',
            'request-bpm-analysis', 'request-loudness-analysis', 'start-normalize-job',
            'stop-normalize-job', 'direct-link-command', 'add-youtube-link', 'import-youtube-playlist',
            'show-general-context-menu', 'show-song-context-menu', 'open-external-link',
            'create-new-playlist-with-songs', 'request-playlists-with-artwork', 'cd-start-rip',
            'playback-started', 'song-skipped', 'save-audio-output-id', 'normalize-worker-finished-file'
        ];
        if (validChannels.includes(channel)) {
            ipcRenderer.send(channel, ...args);
        }
    },
    invoke: (channel, ...args) => {
        const validChannels = [
            'get-artworks-dir', 'get-settings', 'get-loudness-value', 'get-artwork-as-data-url',
            'get-playlist-details', 'get-situation-playlists', 'get-library-for-normalize',
            'get-all-loudness-data', 'get-lyrics', 'save-lrc-file', 'edit-metadata',
            'mtp-browse-directory', 'mtp-upload-files', 'mtp-upload-files-with-structure',
            'mtp-download-files', 'mtp-delete-files', 'mtp-select-download-folder',
            'mtp-get-untransferred-songs', 'add-songs-to-playlist', 'add-album-to-playlist',
            'rename-playlist', 'delete-playlist', 'create-playlist', 'save-quiz-score',
            'get-quiz-scores', 'select-files-for-normalize', 'select-folder-for-normalize',
            'select-normalize-output-folder', 'cd-scan', 'cd-search-toc', 'cd-search-text',
            'cd-apply-metadata'
        ];
        if (validChannels.includes(channel)) {
            return ipcRenderer.invoke(channel, ...args);
        }
    },
    on: (channel, func) => {
        const validChannels = [
            'app-info-response', 'load-library', 'library-loaded', 'settings-loaded',
            'force-reload-library', 'force-reload-playlist', 'playlists-updated',
            'play-counts-updated', 'youtube-link-processed', 'show-notification',
            'show-error', 'measure-performance', 'scan-progress', 'scan-complete',
            'rip-progress', 'rip-complete', 'normalize-worker-result', 'mtp-device-status',
            'mtp-device-connected', 'mtp-device-disconnected', 'playlist-import-progress',
            'playlist-import-finished', 'loudness-analysis-result', 'lyrics-added-notification',
            'bpm-analysis-complete', 'navigate-back', 'show-loading', 'hide-loading',
            'songs-deleted', 'request-new-playlist-with-songs', 'show-edit-metadata-modal',
            'request-mtp-transfer'
        ];
        if (validChannels.includes(channel)) {
            const subscription = (event, ...args) => func(...args);
            ipcRenderer.on(channel, subscription);
            return () => ipcRenderer.removeListener(channel, subscription);
        }
    },
    removeAllListeners: (channel) => {
        ipcRenderer.removeAllListeners(channel);
    }
});
