import { playSong, markLoudnessAnalysisCompleted } from '../features/playback-manager.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { state } from './state.js';
import { showModal } from '../ui/modal.js';
import { renderCurrentView, regroupLibraryCollections, rebuildLibraryIndexes } from '../ui/ui-manager.js';
import { showView } from './navigation.js';
import { musicApi } from './bridge.js';
// --- ▼▼▼ 新規追加 ▼▼▼ ---
import { showEditMetadataModal } from '../features/edit-metadata.js'; // あとで作成するファイル
import { escapeHtml } from '../ui/utils.js';
// --- ▲▲▲ ここまで ▲▲▲ ---

const startTime = performance.now();
const logPerf = (message) => {
    console.log(`[PERF][IPC] ${message} at ${(performance.now() - startTime).toFixed(2)}ms`);
};
logPerf("ipc.js script execution started.");

const electronAPI = window.electronAPI;
let mtpOperationInProgress = false;

export function initIPC(callbacks) {
    console.log('[IPC] initIPC called');
    logPerf("initIPC called.");

    electronAPI.on('app-info-response', (info) => {
        callbacks.onAppInfoResponse?.(info);
    });
    electronAPI.on('load-library', (data) => {
        logPerf("Received 'load-library' from main.");
        console.log(`[Debug] Received initial library with ${data.songs ? data.songs.length : 0} songs.`);
        callbacks.onLibraryLoaded?.(data);
    });
    electronAPI.on('settings-loaded', (settings) => {
        logPerf("Received 'settings-loaded' from main.");
        console.log('[Debug] Settings loaded.');
        callbacks.onSettingsLoaded?.(settings);
    });
    electronAPI.on('play-counts-updated', (counts) => {
        callbacks.onPlayCountsUpdated?.(counts);
    });
    electronAPI.on('youtube-link-processed', (newSong) => {
        callbacks.onYoutubeLinkProcessed?.(newSong);
    });
    electronAPI.on('playlists-updated', (playlists) => {
        callbacks.onPlaylistsUpdated?.(playlists);
    });
    electronAPI.on('force-reload-playlist', (playlistName) => {
        callbacks.onForceReloadPlaylist?.(playlistName);
    });
    electronAPI.on('force-reload-library', () => {
        callbacks.onForceReloadLibrary?.();
    });
    electronAPI.on('show-loading', (text) => { // YouTube用
        callbacks.onShowLoading?.(text);
    });
    electronAPI.on('hide-loading', () => { // YouTube用
        callbacks.onHideLoading?.();
    });
    electronAPI.on('show-error', (message) => {
        callbacks.onShowError?.(message);
    });
    electronAPI.on('playlist-import-progress', (progress) => { // YouTube用
        callbacks.onPlaylistImportProgress?.(progress);
    });
    electronAPI.on('playlist-import-finished', () => { // YouTube用
        callbacks.onPlaylistImportFinished?.();
    });

    electronAPI.on('scan-progress', (progress) => {
        callbacks.onScanProgress?.(progress);
    });

    electronAPI.on('scan-complete', (newSongs) => {
        callbacks.onScanComplete?.(newSongs);
    });
    electronAPI.on('flac-index-progress', (progress) => {
        callbacks.onFlacIndexProgress?.(progress);
    });
    electronAPI.on('flac-index-complete', (total) => {
        callbacks.onFlacIndexComplete?.(total);
    });

    electronAPI.on('loudness-analysis-result', (result) => {
        const filePath = typeof result?.filePath === 'string' ? result.filePath : '';
        const fileName = filePath ? filePath.split(/[/\\]/).pop() : 'Unknown';
        markLoudnessAnalysisCompleted(filePath);

        const waitingSong = state.songWaitingForAnalysis;
        const loudness = Number(result?.loudness);

        if (result.success) {
            const loudnessText = Number.isFinite(loudness) ? loudness.toFixed(2) : 'N/A';
            console.log(`%c[ラウドネス解析完了]%c ${fileName} -> %c${loudnessText} LUFS`,
                'color: green; font-weight: bold;',
                'color: inherit;',
                'color: blue; font-weight: bold;'
            );

            if (waitingSong && waitingSong.sourceList[waitingSong.index]?.path === filePath) {
                playSong(waitingSong.index, null, true);
            }

        } else {
            console.error(`[ラウドネス解析失敗] ${fileName}: ${result.error}`);

            if (waitingSong && waitingSong.sourceList[waitingSong.index]?.path === filePath) {
                showNotification(`「${fileName}」の解析に失敗したため、ノーマライズなしで再生します。`);
                hideNotification(3000);

                state.songWaitingForAnalysis = null;
                playSong(waitingSong.index, null, true);
            }
        }
    });

    electronAPI.on('lyrics-added-notification', (count) => {
        showNotification(`${count}個の歌詞ファイルが追加されました。`);
        hideNotification(3000);
    });

    electronAPI.on('show-notification', (message) => {
        showNotification(message);
        hideNotification(3000);
    });

    electronAPI.on('songs-deleted', (deletedSongPaths) => {
        const deletedPathsSet = new Set(deletedSongPaths);
        state.library = state.library.filter(song => !deletedPathsSet.has(song.path));
        rebuildLibraryIndexes();
        state.selectedSongIds.clear();
        state.copiedSongIds = [];
        regroupLibraryCollections();
        renderCurrentView();
        showNotification(`${deletedSongPaths.length}曲がライブラリから削除されました。`);
        hideNotification(3000);
    });

    electronAPI.on('request-new-playlist-with-songs', (songs) => {
        showModal({
            title: '新規プレイリスト作成',
            placeholder: 'プレイリスト名を入力',
            onOk: (playlistName) => {
                if (playlistName && playlistName.trim() !== '') {
                    electronAPI.send('create-new-playlist-with-songs', { playlistName, songs });
                }
            }
        });
    });

    electronAPI.on('show-edit-metadata-modal', (song) => {
        showEditMetadataModal(song);
    });

    function handleMtpConnected(payload) {
        console.log('🎉 [IPC] handleMtpConnected:', payload);
        const deviceInfo = payload.device;
        const storageInfo = payload.storages;

        state.mtpDevice = deviceInfo;
        state.mtpStorages = storageInfo;

        updateDevicesSidebar(deviceInfo);
    }

    console.log('[IPC] Registering mtp-device-connected listener');
    electronAPI.on('mtp-device-connected', (payload) => {
        handleMtpConnected(payload);
        showNotification(`Walkman (${payload.device?.name}) が接続されました。`);
        hideNotification(3000);
    });

    electronAPI.on('mtp-device-disconnected', () => {
        console.log('🔌 MTP デバイス切断');
        state.mtpDevice = null;
        state.mtpStorages = null;

        showNotification('Walkmanが切断されました。');
        hideNotification(3000);
        updateDevicesSidebar(null);
    });

    electronAPI.on('request-mtp-transfer', async (songs) => {
        logPerf("Received 'request-mtp-transfer' from main.");

        if (!state.mtpStorages || state.mtpStorages.length === 0) {
            showNotification('Walkmanのストレージ情報が見つかりません。');
            hideNotification(3000);
            return;
        }

        const storageId = state.mtpStorages[0].id;
        const destination = '/Music/';
        const sources = songs.map(s => s.path);

        const songCount = songs.length;
        const message = songCount > 1 ? `${songCount}曲の転送を開始します...` : `「${songs[0].title}」の転送を開始します...`;
        showNotification(message);

        try {
            const result = await electronAPI.invoke('mtp-upload-files', { storageId, sources, destination });

            if (result.error) {
                showNotification(`転送に失敗しました: ${result.error}`);
            } else {
                showNotification(songCount > 1 ? `${songCount}曲の転送が完了しました。` : `「${songs[0].title}」の転送が完了しました。`);
            }
        } catch (err) {
            showNotification(`転送実行中にエラーが発生しました: ${err.message}`);
        }
        hideNotification(4000);
    });

    logPerf("Requesting initial data from main process...");
    electronAPI.send('request-initial-library');
    musicApi.requestInitialPlayCounts();
    electronAPI.send('request-initial-settings');

    // MTP初期状態の取得
    electronAPI.invoke('mtp-get-status').then(status => {
        if (status) {
            console.log('[IPC] Initial MTP Status found:', status);
            handleMtpConnected(status);
        } else {
            console.log('[IPC] No MTP device connected initially');
        }
    }).catch(err => {
        console.error('[IPC] Failed to get initial MTP status:', err);
    });

    const mtpDeviceNavLink = document.getElementById('mtp-device-nav-link');
    if (mtpDeviceNavLink) {
        console.log('[IPC] mtp-device-nav-link listener attached');
        mtpDeviceNavLink.addEventListener('click', async (e) => {
            console.log('[IPC][Click] mtp-device-nav-link clicked');
            e.preventDefault();
            if (mtpOperationInProgress) {
                console.warn('[IPC] MTP operation already in progress, skipping click');
                return;
            }

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                showNotification('ストレージ情報がありません');
                hideNotification(3000);
                return;
            }

            const mainContent = document.getElementById('main-content');
            const mtpTransferView = document.getElementById('mtp-transfer-view');

            if (mainContent && mtpTransferView) {
                mainContent.classList.add('hidden');
                mtpTransferView.classList.remove('hidden');

                showNotification('未転送の曲を確認中...');
                mtpOperationInProgress = true;

                try {
                    const storageId = state.mtpStorages[0].id;
                    const result = await electronAPI.invoke('mtp-get-untransferred-songs', {
                        storageId,
                        librarySongs: state.library
                    });
                    hideNotification();

                    const untransferredSongs = result?.untransferredSongs || [];
                    const deviceFilesList = result?.deviceFilesList || [];

                    const sourceList = document.getElementById('mtp-transfer-source-list');
                    if (sourceList) {
                        if (untransferredSongs && untransferredSongs.length > 0) {
                            sourceList.innerHTML = `<p>未転送の曲: ${untransferredSongs.length}曲</p>`;
                            untransferredSongs.forEach(song => {
                                const item = document.createElement('div');
                                item.className = 'transfer-item';
                                const title = song.title || song.path.split('/').pop();
                                const reason = song._reason || '理由不明';
                                item.innerHTML = `
                                    <span class="transfer-item-title">${escapeHtml(title)}</span>
                                    <span class="transfer-item-reason">${escapeHtml(reason)}</span>
                                `;
                                item.dataset.path = song.path;
                                sourceList.appendChild(item);
                            });
                            state.pendingTransferSongs = untransferredSongs;
                        } else {
                            sourceList.innerHTML = '<p>すべての曲が転送済みです 🎉</p>';
                            state.pendingTransferSongs = [];
                        }
                    }

                    const deviceList = document.getElementById('mtp-transfer-device-list');
                    if (deviceList) {
                        deviceList.innerHTML = `<p>デバイス上のファイル: ${deviceFilesList.length}件</p>`;
                        deviceFilesList.forEach(file => {
                            const item = document.createElement('div');
                            item.className = 'transfer-item';
                            const sizeKB = Math.round((file.size || 0) / 1024);
                            item.innerHTML = `
                                <span class="transfer-item-title">${escapeHtml(file.name)}</span>
                                <span class="transfer-item-reason">正規化: "${escapeHtml(file.normalizedName)}" (${sizeKB} KB)</span>
                            `;
                            deviceList.appendChild(item);
                        });
                    }

                } catch (error) {
                    console.error('[IPC] MTP操作中にエラー発生:', error);
                    hideNotification();
                    showNotification('未転送曲の確認に失敗しました');
                    hideNotification(3000);
                } finally {
                    mtpOperationInProgress = false;
                }
            }
        });
    }
    // --- ▲▲▲ デバイスリンクのクリックハンドラ ▲▲▲ ---
}

/**
 * サイドバーのデバイスセクションを更新
 * @param {object|null} device - デバイス情報（nullで非表示）
 */
function updateDevicesSidebar(device) {
    const devicesSection = document.getElementById('devices-section');
    const deviceNavName = document.getElementById('mtp-device-nav-name');

    if (!devicesSection) {
        console.warn('[IPC] devices-section が見つかりません');
        return;
    }

    if (device) {
        // デバイス接続時: セクションを表示
        devicesSection.classList.remove('hidden');
        if (deviceNavName) {
            deviceNavName.textContent = device.name || 'MTPデバイス';
        }
        console.log('[IPC] サイドバーにデバイスを表示:', device.name);
    } else {
        // デバイス切断時: セクションを非表示
        devicesSection.classList.add('hidden');
        console.log('[IPC] サイドバーからデバイスを非表示');
    }
}
