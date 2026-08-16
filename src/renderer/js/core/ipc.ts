import { playSong, markLoudnessAnalysisCompleted } from '../features/playback-manager.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { state } from './state.js';
import { showModal } from '../ui/modal.js';
import { rebuildLibraryIndexes, regroupLibraryCollections } from './library-model.js';
import { renderCurrentView } from '../ui/ui-manager.js';
import { escapeHtml } from '../ui/utils.js';
import { showView } from './navigation.js';
import { musicApi } from './bridge.js';
// --- ▼▼▼ 新規追加 ▼▼▼ ---
import { showEditMetadataModal } from '../features/edit-metadata.js'; // あとで作成するファイル
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

    electronAPI.on('loudness-analysis-result', (rawResult) => {
        const result = rawResult as Record<string, unknown>;
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
            console.error(`[ラウドネス解析失敗] ${fileName}: ${result.error as string}`);

            if (waitingSong && waitingSong.sourceList[waitingSong.index]?.path === filePath) {
                showNotification(`「${fileName}」の解析に失敗したため、ノーマライズなしで再生します。`);
                hideNotification(3000);

                state.songWaitingForAnalysis = null;
                playSong(waitingSong.index, null, true);
            }
        }
    });

    electronAPI.on('lyrics-added-notification', (count) => {
        showNotification(`${count}個の歌詞ファイルが追加されました。`, 3000);
    });

    electronAPI.on('show-notification', (message) => {
        showNotification(String(message), 3000);
    });

    electronAPI.on('songs-deleted', (deletedSongPaths) => {
        const deletedPathsSet = new Set(deletedSongPaths as string[]);
        state.library = state.library.filter(song => !deletedPathsSet.has(song.path));
        rebuildLibraryIndexes();
        state.selectedSongIds.clear();
        state.copiedSongIds = [];
        regroupLibraryCollections();
        renderCurrentView();
        showNotification(`${(deletedSongPaths as string[]).length}曲がライブラリから削除されました。`, 3000);
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
        showEditMetadataModal(song as Record<string, unknown>);
    });

    function handleMtpConnected(payload: Record<string, unknown>) {
        console.log('🎉 [IPC] handleMtpConnected:', payload);
        const deviceInfo = payload.device;
        const storageInfo = payload.storages;

        state.mtpDevice = deviceInfo;
        state.mtpStorages = storageInfo as unknown[];

        updateDevicesSidebar(deviceInfo);
    }

    console.log('[IPC] Registering mtp-device-connected listener');
    electronAPI.on('mtp-device-connected', (payload) => {
        const p = payload as Record<string, unknown>;
        handleMtpConnected(p);
        showNotification(`Walkman (${(p.device as Record<string, unknown>)?.name}) が接続されました。`, 3000);
    });

    electronAPI.on('mtp-device-disconnected', () => {
        console.log('🔌 MTP デバイス切断');
        state.mtpDevice = null;
        state.mtpStorages = null;

        showNotification('Walkmanが切断されました。', 3000);
        updateDevicesSidebar(null);
    });

    electronAPI.on('request-mtp-transfer', async (rawSongs) => {
        const songs = rawSongs as Array<Record<string, unknown>>;
        logPerf("Received 'request-mtp-transfer' from main.");

        if (!state.mtpStorages || state.mtpStorages.length === 0) {
            showNotification('Walkmanのストレージ情報が見つかりません。', 3000);
            return;
        }

        const storageId = (state.mtpStorages[0] as Record<string, unknown>).id;
        const destination = '/Music/';
        const sources = songs.map(s => s.path);

        const songCount = songs.length;
        const message = songCount > 1 ? `${songCount}曲の転送を開始します...` : `「${songs[0].title}」の転送を開始します...`;
        showNotification(message, false);

        try {
            const result = await electronAPI.invoke('mtp-upload-files', { storageId, sources, destination }) as Record<string, unknown>;

            if (result.error) {
                showNotification(`転送に失敗しました: ${result.error}`, 4000);
            } else {
                showNotification(songCount > 1 ? `${songCount}曲の転送が完了しました。` : `「${songs[0].title}」の転送が完了しました。`, 4000);
            }
        } catch (err) {
            showNotification(`転送実行中にエラーが発生しました: ${(err as Error).message}`, 4000);
        }
    });

    logPerf("Requesting initial data from main process...");
    electronAPI.send('request-initial-library');
    musicApi.requestInitialPlayCounts();
    electronAPI.send('request-initial-settings');

    // MTP初期状態の取得
    electronAPI.invoke('mtp-get-status').then(status => {
        if (status) {
            console.log('[IPC] Initial MTP Status found:', status);
            handleMtpConnected(status as Record<string, unknown>);
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

            const { showView } = await import('./navigation.js');
            await showView('mtp-transfer-view');

            showNotification('未転送の曲を確認中...');
            mtpOperationInProgress = true;

            try {
                    const storageId = (state.mtpStorages[0] as Record<string, unknown>).id;
                    const result = await electronAPI.invoke('mtp-get-untransferred-songs', {
                        storageId,
                        librarySongs: state.library
                    }) as Record<string, unknown>;
                    hideNotification();

                    const untransferredSongs = (result?.untransferredSongs as Array<Record<string, unknown>>) || [];
                    const deviceFilesList = (result?.deviceFilesList as unknown[]) || [];

                    const sourceList = document.getElementById('mtp-transfer-source-list');
                    if (sourceList) {
                        if (untransferredSongs && untransferredSongs.length > 0) {
                            sourceList.innerHTML = `<p>未転送の曲: ${untransferredSongs.length}曲</p>`;
                            untransferredSongs.forEach(song => {
                                const item = document.createElement('div');
                                item.className = 'transfer-item';
                                const title = String(song.title || (song.path as string).split('/').pop());
                                const reason = String(song._reason || '理由不明');
                                item.innerHTML = `
                                    <span class="transfer-item-title">${escapeHtml(title)}</span>
                                    <span class="transfer-item-reason">${escapeHtml(reason)}</span>
                                `;
                                item.dataset.path = song.path as string;
                                sourceList.appendChild(item);
                            });
                            state.pendingTransferSongs = untransferredSongs as import('../../types/domain.js').Song[];
                        } else {
                            sourceList.innerHTML = '<p>すべての曲が転送済みです 🎉</p>';
                            state.pendingTransferSongs = [];
                        }
                    }

                    const deviceList = document.getElementById('mtp-transfer-device-list');
                    if (deviceList) {
                        deviceList.innerHTML = `<p>デバイス上のファイル: ${deviceFilesList.length}件</p>`;
                        deviceFilesList.forEach(file => {
                            const f = file as Record<string, unknown>;
                            const item = document.createElement('div');
                            item.className = 'transfer-item';
                            const sizeKB = Math.round(((f.size as number) || 0) / 1024);
                            item.innerHTML = `
                                    <span class="transfer-item-title">${escapeHtml(f.name as string)}</span>
                                    <span class="transfer-item-reason">正規化: "${escapeHtml(f.normalizedName as string)}" (${sizeKB} KB)</span>
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
