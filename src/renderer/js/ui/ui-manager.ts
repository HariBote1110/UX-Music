// uxmusic/src/renderer/js/ui-manager.js

import { state, elements } from '../core/state.js';
import type { Song } from '../../types/domain.js';
import { playSong } from '../features/playback-manager.js';
import { createQueueItem } from './element-factory.js';
import { showView } from '../core/navigation.js';
import { setAudioOutput, setVisualizerTarget } from '../features/player.js';
import { getWailsApp, isWailsMode } from '../core/bridge.js';
import { showNotification, hideNotification } from './notification.js';
import { showContextMenu, formatBytes } from './utils.js';
import {
    rebuildLibraryIndexes,
    groupLibraryByAlbum,
    groupLibraryByArtist,
    upsertAlbumForSong,
    upsertArtistForSong,
} from '../core/library-model.js';
import { loadNormalizedSettings } from '../core/settings-helpers.js';

const electronAPI = window.electronAPI;

/** For `[attr="..."]` selectors — not {@link CSS.escape} (that targets identifiers and breaks UUIDs starting with a digit). */
function cssQuotedAttrValue(value) {
    return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

/**
 * Stops playback and switches the audio output device, then updates the device popup selection.
 */
async function applyOutputDeviceChange(selectedItem: HTMLElement, newDeviceId: string | undefined) {
    if (newDeviceId == null || newDeviceId === '') {
        return;
    }
    await setAudioOutput(newDeviceId);
    elements.devicePopup.querySelectorAll('.device-popup-item').forEach((i) => {
        i.classList.remove('active');
    });
    selectedItem.classList.add('active');
    elements.devicePopup.classList.remove('active');
}

let lastPlayingQueueIndex = -1;
/** @type {HTMLElement | null} */
let cachedMainPlayingItem = null;

/**
 * 現在アクティブなビューの内容を再描画する
 */
export function renderCurrentView() {
    console.log(`[Debug:UI] renderCurrentView 実行 - ViewId: ${state.activeViewId}`);
    void showView(state.activeViewId, state.currentDetailView);
    renderQueueView();
}

/**
 * 再生中の曲の表示（ハイライトやイコライザー）を更新する
 */
export function updatePlayingIndicators() {
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    const playingIdentifier = currentPlayingSong?.id || currentPlayingSong?.path;
    console.log(`[Debug:UI] updatePlayingIndicators 実行 - SongID: ${playingIdentifier}`);

    if (cachedMainPlayingItem) {
        cachedMainPlayingItem.classList.remove('playing');
        cachedMainPlayingItem = null;
    }

    if (currentPlayingSong && playingIdentifier) {
        try {
            const selector = `.main-content .song-item[data-song-id="${cssQuotedAttrValue(playingIdentifier)}"]`;
            const newPlayingItem = document.querySelector(selector);

            if (newPlayingItem) {
                console.log('[Debug:UI] 該当する song-item を発見しました。ハイライトを適用します。');
                newPlayingItem.classList.add('playing');
                cachedMainPlayingItem = newPlayingItem;
                setVisualizerTarget(newPlayingItem);
            } else {
                console.warn(`[Debug:UI] セレクター "${selector}" に一致する要素が見つかりませんでした。`);
            }
        } catch (e) {
            console.error('[Debug:UI] エラー:', e);
        }
    } else {
        setVisualizerTarget(null);
    }

    syncQueuePlayingState();
}

/**
 * 指定された曲の再生回数表示を更新する
 */
export function updatePlayCountDisplay(songPath, count) {
    try {
        const songItem = document.querySelector(`.main-content .song-item[data-song-path="${cssQuotedAttrValue(songPath)}"]`);
        if (songItem) {
            const countElement = songItem.querySelector('.song-play-count');
            if (countElement) {
                countElement.textContent = count;
            }
        }
    } catch (e) {
        console.error('Error updating play count display:', e);
    }
}

export function renderQueueView() {
    elements.queueList.innerHTML = '';
    lastPlayingQueueIndex = -1;
    if (state.playbackQueue.length === 0) {
        elements.queueList.innerHTML = '<p class="no-lyrics">再生キューは空です</p>';
        return;
    }
    const frag = document.createDocumentFragment();
    state.playbackQueue.forEach((song, index) => {
        const isPlaying = index === state.currentSongIndex;
        const queueItem = createQueueItem(song, isPlaying, index);
        frag.appendChild(queueItem);
        if (isPlaying) {
            lastPlayingQueueIndex = index;
        }
    });
    elements.queueList.appendChild(frag);

    if (typeof window.observeNewArtworks === 'function') {
        window.observeNewArtworks(elements.queueList);
    }

    // 再生中アイテムをスクロールして表示
    if (lastPlayingQueueIndex >= 0) {
        const playingItem = elements.queueList.querySelector(`[data-queue-index="${lastPlayingQueueIndex}"]`);
        playingItem?.scrollIntoView({ block: 'nearest' });
    }
}

function syncQueuePlayingState() {
    const nextPlayingIndex = state.currentSongIndex;

    if (lastPlayingQueueIndex === nextPlayingIndex) {
        return;
    }

    if (lastPlayingQueueIndex >= 0) {
        const previousItem = elements.queueList.querySelector(`[data-queue-index="${lastPlayingQueueIndex}"]`);
        previousItem?.classList.remove('playing');
    }

    if (nextPlayingIndex >= 0) {
        const nextItem = elements.queueList.querySelector(`[data-queue-index="${nextPlayingIndex}"]`);
        nextItem?.classList.add('playing');
        nextItem?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }

    lastPlayingQueueIndex = nextPlayingIndex;
}

/**
 * サイドバー（歌詞・再生キュー・EQ）、キュー行クリック、MTP デバイス UI。
 * `renderer` は `ui.ts` の initUI を入口にしているため、そこから必ず一度呼び出すこと。
 */
export function initQueueSidebarMtpHandlers() {
    if (elements.queueList) {
        elements.queueList.addEventListener('click', (e) => {
            const item = e.target.closest('[data-queue-index]');
            if (!item || !elements.queueList.contains(item)) return;
            const raw = item.getAttribute('data-queue-index');
            if (raw == null) return;
            const idx = parseInt(raw, 10);
            if (!Number.isFinite(idx)) return;
            playSong(idx);
        });
    }

    elements.sidebarTabs.forEach(tab => {
        tab.addEventListener('click', () => {
            elements.sidebarTabs.forEach(t => t.classList.remove('active'));
            elements.sidebarTabContents.forEach(c => c.classList.remove('active'));
            tab.classList.add('active');
            const targetContent = document.getElementById(tab.dataset.tab);
            if (targetContent) targetContent.classList.add('active');
            renderQueueView();
        });
    });

    elements.mtpDeviceButton.addEventListener('click', (e) => {
        console.log('[UI-Manager][Click] mtpDeviceButton clicked');
        e.stopPropagation();
        elements.mtpDevicePopup.classList.toggle('active');
        elements.devicePopup.classList.remove('active');
    });

    document.addEventListener('click', (e) => {
        if (!elements.mtpDevicePopup.contains(e.target) && !elements.mtpDeviceButton.contains(e.target)) {
            elements.mtpDevicePopup.classList.remove('active');
        }
    });

    electronAPI.on('mtp-device-connected', (payload) => {
        console.log('[MTP-LOG] mtp-device-connected 受信:', payload);
        // payload: { device: { name, ... }, storages: [...] }
        updateMtpDeviceView(payload);
    });

    electronAPI.on('mtp-device-disconnected', () => {
        console.log('[MTP-LOG] mtp-device-disconnected 受信');
        updateMtpDeviceView(null);
    });

    elements.mtpTransferQueueBtn.addEventListener('click', () => {
        void showView('mtp-transfer-view');
        elements.mtpDevicePopup.classList.remove('active');
    });

    // MTPストレージを参照ボタン
    if (elements.mtpBrowseStorageBtn) {
        elements.mtpBrowseStorageBtn.addEventListener('click', () => {
            console.log('[UI-Manager][Click] mtpBrowseStorageBtn clicked');
            elements.mtpDevicePopup.classList.remove('active');

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                showNotification('ストレージ情報がありません');
                hideNotification(3000);
                return;
            }

            // ナビゲーションを使用してMTPブラウザビューを表示
            void showView('mtp-browser-view', {
                storageId: (state.mtpStorages[0] as Record<string, unknown>).id,
                initialPath: '/'
            });
        });
    };
}

/** @deprecated 代わりに {@link initQueueSidebarMtpHandlers} を使用（`ui.ts` から呼び出し） */
export const initUI = initQueueSidebarMtpHandlers;

function updateMtpDeviceView(payload) {
    if (payload && payload.device) {
        const device = payload.device;
        const storages = payload.storages;

        elements.mtpDeviceButton.classList.remove('hidden');
        elements.mtpDeviceName.textContent = device.name || 'MTP Device';
        const mtpTransferNameEl = document.getElementById('mtp-transfer-device-name');
        if (mtpTransferNameEl) mtpTransferNameEl.textContent = device.name || 'MTP Device';

        if (storages && storages.length > 0) {
            const storage = storages[0];
            const free = storage.free || 0;
            const total = storage.total || 0;
            const used = total - free;
            const usedPercent = total > 0 ? (used / total) * 100 : 0;

            const fBytes = typeof formatBytes === 'function' ? formatBytes : (b) => `${(b / 1024 ** 3).toFixed(1)} GB`;
            elements.mtpStorageUsed.style.width = `${usedPercent}%`;
            elements.mtpStorageLabel.textContent = `${fBytes(free)} 空き (${fBytes(used)} / ${fBytes(total)})`;
        } else {
            elements.mtpStorageUsed.style.width = '0%';
            elements.mtpStorageLabel.textContent = 'ストレージ情報なし';
        }
    } else {
        elements.mtpDeviceButton.classList.add('hidden');
        elements.mtpDevicePopup.classList.remove('active');

        if (state.activeViewId === 'mtp-transfer-view') {
            void showView(state.activeListView || 'track-view');
            showNotification('MTPデバイスが切断されました。', 3000);
        }
    }
}

export function addSongsToLibrary({ songs, albums, skipRender = false }: { songs: Song[]; albums: Record<string, unknown>; skipRender?: boolean }) {
    console.time('Renderer: Process Library Data');
    let migrationNeeded = false;
    let fullRegroupNeeded = false;

    if (albums && Object.keys(albums).length === 0 && songs && songs.length > 0 && songs[0].artwork && typeof songs[0].artwork !== 'object') {
        migrationNeeded = true;
        state.albums.clear();
    }

    if (songs && songs.length > 0) {
        if (state.libraryByPath.size === 0 || state.libraryById.size === 0) {
            rebuildLibraryIndexes();
        }

        songs.forEach((newSong) => {
            if (!newSong.id && newSong.path) {
                newSong.id = newSong.path;
            }
            const existingSong = state.libraryByPath.get(newSong.path);
            if (existingSong) {
                Object.assign(existingSong, newSong);
                fullRegroupNeeded = true;
            } else {
                state.library.push(newSong);
                if (newSong.id) {
                    state.libraryById.set(newSong.id, newSong);
                }
                if (newSong.path) {
                    state.libraryByPath.set(newSong.path, newSong);
                }
                if (!migrationNeeded && !newSong.sourceURL) {
                    upsertAlbumForSong(newSong);
                    upsertArtistForSong(newSong);
                }
            }
        });
    }

    if (migrationNeeded || fullRegroupNeeded) {
        groupLibraryByAlbum(migrationNeeded);
        groupLibraryByArtist();
    }
    if (migrationNeeded || (albums && Object.keys(albums).length > 0)) {
        const albumsToSave = Object.fromEntries(state.albums.entries());
        electronAPI.send('save-migrated-data', { songs: state.library, albums: albumsToSave });
    }
    if (!skipRender) renderCurrentView();
    console.timeEnd('Renderer: Process Library Data');
}

export async function updateAudioDevices() {
    try {
        console.log('[AudioDevices] enumerating devices...');

        const settings = await loadNormalizedSettings();

        const wailsApp = getWailsApp();
        if (wailsApp?.AudioListDevices) {
            const activeDeviceId = (settings.audioOutputId as string | undefined) || 'default';
            elements.devicePopup.innerHTML = '';

            try {
                const goDevices = await wailsApp.AudioListDevices();
                console.log('[AudioDevices] Go devices:', goDevices);

                if (!Array.isArray(goDevices)) {
                    console.warn('[AudioDevices] Go AudioListDevices did not return an array');
                    return;
                }

                // システムデフォルト追従エントリ
                const defaultItem = document.createElement('div');
                defaultItem.className = 'device-popup-item';
                defaultItem.textContent = 'システムデフォルト';
                defaultItem.dataset.deviceId = 'default';
                if (activeDeviceId === 'default') defaultItem.classList.add('active');
                defaultItem.style.borderBottom = '1px solid #334';
                defaultItem.addEventListener('click', async () => {
                    await applyOutputDeviceChange(defaultItem, 'default');
                });
                elements.devicePopup.appendChild(defaultItem);

                goDevices.forEach(d => {
                    const item = document.createElement('div');
                    item.className = 'device-popup-item';
                    item.textContent = d.isDefault ? `${d.name} ★` : d.name;
                    item.dataset.deviceId = d.id;
                    if (d.id === activeDeviceId) item.classList.add('active');

                    item.addEventListener('click', async () => {
                        await applyOutputDeviceChange(item, item.dataset.deviceId);
                    });
                    elements.devicePopup.appendChild(item);
                });
            } catch (e) { console.error("Failed to list audio devices via Go:", e); }
            return;
        }

        const md = navigator.mediaDevices;
        if (!md?.enumerateDevices) {
            console.warn('[AudioDevices] navigator.mediaDevices is not available in this WebView');
            if (elements.devicePopup) {
                elements.devicePopup.innerHTML = '';
                const msg = document.createElement('div');
                msg.className = 'device-popup-item';
                msg.textContent = 'この環境ではブラウザのオーディオ一覧を取得できません（Wails 側のデバイス一覧を利用してください）';
                elements.devicePopup.appendChild(msg);
            }
            return;
        }

        let devices = await md.enumerateDevices();

        // 権限がない場合 deviceId と label が空文字になる
        // Wails環境では getUserMedia で権限を取得してから再度 enumerateDevices を呼ぶ必要がある
        const hasEmptyDeviceIds = devices.some(d => d.kind === 'audiooutput' && d.deviceId === '');
        if (hasEmptyDeviceIds && isWailsMode() && md.getUserMedia) {
            console.log('[AudioDevices] Detected devices with empty IDs, requesting media permission...');
            try {
                const stream = await md.getUserMedia({ audio: true });
                stream.getTracks().forEach(t => t.stop());
                // 権限取得後に再度列挙
                devices = await md.enumerateDevices();
                console.log('[AudioDevices] Devices after permission:', devices.map(d => ({ kind: d.kind, label: d.label, id: d.deviceId })));
            } catch (permErr) {
                console.warn('[AudioDevices] Permission request failed:', permErr);
            }
        }

        console.log('[AudioDevices] all devices found:', devices.map(d => ({ kind: d.kind, label: d.label, id: d.deviceId })));
        const hiddenDevices = (settings.hiddenDeviceIds as string[] | undefined) || [];

        const audioDevices = devices.filter(device =>
            device.kind === 'audiooutput' && !hiddenDevices.includes(device.deviceId)
        );

        const activeDeviceId = (settings.audioOutputId as string | undefined) || 'default';
        elements.devicePopup.innerHTML = '';

        if (audioDevices.length === 0 && devices.length > 0) {
            console.log('[AudioDevices] No audiooutput devices found by type filter. Checking all devices...');
            // WebKit 等では kind が正しく取得できない場合や制限されている場合がある
        }

        type ExtendedDevice = MediaDeviceInfo | { deviceId: string; label: string; isVirtual: true };
        const directLinkDevice: ExtendedDevice = {
            deviceId: 'ux-direct-link',
            label: 'UX Audio Router (Direct)',
            isVirtual: true
        };
        const displayDevices: ExtendedDevice[] = [directLinkDevice, ...audioDevices];

        // デバイスが見つからない場合のヘルパー
        if (audioDevices.length === 0 && isWailsMode()) {
            const permissionItem = document.createElement('div');
            permissionItem.className = 'device-popup-item permission-prompt';
            permissionItem.textContent = '🔊 デバイス一覧を更新（アクセス許可）';
            permissionItem.style.color = '#ffaa00';
            permissionItem.style.fontSize = '0.9em';
            permissionItem.addEventListener('click', async (e) => {
                e.stopPropagation();
                try {
                    if (!navigator.mediaDevices?.getUserMedia) return;
                    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
                    stream.getTracks().forEach(t => t.stop());
                    await updateAudioDevices();
                } catch (err) {
                    console.error('Permission denied:', err);
                }
            });
            elements.devicePopup.appendChild(permissionItem);
        }

        // selectAudioOutput (ブラウザネイティブの選択画面) が使える場合
        if (md.selectAudioOutput) {
            const selectItem = document.createElement('div');
            selectItem.className = 'device-popup-item';
            selectItem.textContent = '📄 システムの選択画面を開く...';
            selectItem.style.borderBottom = '1px solid #334';
            selectItem.addEventListener('click', async (e) => {
                e.stopPropagation();
                try {
                    const device = await md.selectAudioOutput();
                    await setAudioOutput(device.deviceId);
                    updateAudioDevices();
                } catch (err) {
                    if ((err as Error).name !== 'NotAllowedError') console.error('selectAudioOutput error:', err);
                }
            });
            elements.devicePopup.appendChild(selectItem);
        }

        displayDevices.forEach(device => {
            const item = document.createElement('div');
            item.className = 'device-popup-item';

            if ('isVirtual' in device && device.isVirtual) {
                item.style.fontWeight = 'bold';
                item.style.color = '#7289da';
            }

            item.textContent = device.label || `スピーカー ${elements.devicePopup.children.length + 1}`;
            item.dataset.deviceId = device.deviceId;

            if (device.deviceId === activeDeviceId) {
                item.classList.add('active');
            }

            item.addEventListener('click', async () => {
                await applyOutputDeviceChange(item, item.dataset.deviceId);
            });

            if (!('isVirtual' in device)) {
                item.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    showContextMenu(e.pageX, e.pageY, [
                        {
                            label: 'このデバイスを非表示にする',
                            action: () => {
                                const deviceIdToHide = item.dataset.deviceId;
                                const updatedHiddenDevices = [...hiddenDevices, deviceIdToHide];
                                electronAPI.send('save-settings', { hiddenDeviceIds: updatedHiddenDevices });
                                updateAudioDevices();
                            }
                        }
                    ]);
                });
            }
            elements.devicePopup.appendChild(item);
        });
    } catch (error) {
        console.error('オーディオデバイスの取得に失敗しました:', error);
    }
}
