import { playSong } from './playback-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';

export function initIPC(ipcRenderer, callbacks) {
    // --- IPCリスナー群 ---
    ipcRenderer.on('load-library', (event, initialSongs) => {
        console.log('[Debug] Received initial library with', initialSongs ? initialSongs.length : 0, 'songs.');
        callbacks.onLibraryLoaded?.(initialSongs);
    });
    ipcRenderer.on('settings-loaded', (event, settings) => {
        console.log('[Debug] Settings loaded.');
        callbacks.onSettingsLoaded?.(settings);
    });
    ipcRenderer.on('play-counts-updated', (event, counts) => {
        callbacks.onPlayCountsUpdated?.(counts);
    });
    ipcRenderer.on('youtube-link-processed', (event, newSong) => {
        callbacks.onYoutubeLinkProcessed?.(newSong);
    });
    ipcRenderer.on('playlists-updated', (event, playlists) => {
        callbacks.onPlaylistsUpdated?.(playlists);
    });
    ipcRenderer.on('force-reload-playlist', (event, playlistName) => {
        callbacks.onForceReloadPlaylist?.(playlistName);
    });
    ipcRenderer.on('force-reload-library', () => {
        callbacks.onForceReloadLibrary?.();
    });
    ipcRenderer.on('show-loading', (event, text) => {
        callbacks.onShowLoading?.(text);
    });
    ipcRenderer.on('hide-loading', () => {
        callbacks.onHideLoading?.();
    });
    ipcRenderer.on('show-error', (event, message) => {
        callbacks.onShowError?.(message);
    });
    ipcRenderer.on('playlist-import-progress', (event, progress) => {
        callbacks.onPlaylistImportProgress?.(progress);
    });
    ipcRenderer.on('playlist-import-finished', () => {
        callbacks.onPlaylistImportFinished?.();
    });

    // ★★★ ここからが修正箇所です ★★★
    ipcRenderer.on('loudness-analysis-result', (event, result) => {
        const fileName = result.filePath.split(/[/\\]/).pop();
        if (result.success) {
            console.log(`%c[ラウドネス解析完了]%c ${fileName} -> %c${result.loudness.toFixed(2)} LUFS`, 
                'color: green; font-weight: bold;', 
                'color: inherit;',
                'color: blue; font-weight: bold;'
            );
            
            const waitingSong = window.state.songWaitingForAnalysis;
            if (waitingSong && waitingSong.sourceList[waitingSong.index].path === result.filePath) {
                playSong(waitingSong.index, null, true);
            }

        } else {
            // エラー内容に`ffmpeg`が見つからないことを示す `ENOENT` が含まれている場合のみ、
            // より詳細なデバッグメッセージをコンソールに出力します。
            // これにより、解析自体は成功しているのに誤ったエラーが表示されるのを防ぎます。
            if (result.error && result.error.includes('ENOENT')) {
                console.error(`[ラウドネス解析失敗] ffmpegが見つかりません。ファイルパスを確認してください: ${fileName}`, result.error);
            } else {
                console.error(`[ラウドネス解析失敗] ${fileName}: ${result.error}`);
            }
        }
    });
    // ★★★ ここまでが修正箇所です ★★★

    ipcRenderer.on('lyrics-added-notification', (event, count) => {
        showNotification(`${count}個の歌詞ファイルが追加されました。`);
        hideNotification(3000);
    });

    // --- 初期データの要求 ---
    console.log('[Debug] Requesting initial data from main process...');
    ipcRenderer.send('request-initial-library');
    ipcRenderer.send('request-playlists-with-artwork');
    ipcRenderer.send('request-initial-play-counts');
    ipcRenderer.send('request-initial-settings');
}