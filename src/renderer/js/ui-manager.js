// uxmusic/src/renderer/js/ui-manager.js

import { state, elements } from './state.js';
import { playSong } from './playback-manager.js';
import { createQueueItem } from './ui/element-factory.js';
import { showView } from './navigation.js';
import { setAudioOutput, setVisualizerTarget, stop as stopPlayer } from './player.js';
import { updateNowPlayingView } from './ui/now-playing.js';
import { loadLyricsForSong } from './lyrics-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';
import { showContextMenu, formatBytes } from './ui/utils.js';
const { ipcRenderer } = require('electron');

/**
 * 現在アクティブなビューの内容を再描画する
 */
export function renderCurrentView() {
    console.log(`[Debug:UI] renderCurrentView 実行 - ViewId: ${state.activeViewId}`);
    showView(state.activeViewId, state.currentDetailView);
    renderQueueView();
}

/**
 * 再生中の曲の表示（ハイライトやイコライザー）を更新する
 */
export function updatePlayingIndicators() {
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
    console.log(`[Debug:UI] updatePlayingIndicators 実行 - SongID: ${currentPlayingSong?.id}`);

    const oldPlayingItems = document.querySelectorAll('.main-content .song-item.playing');
    oldPlayingItems.forEach(item => item.classList.remove('playing'));

    if (currentPlayingSong) {
        try {
            const safeId = CSS.escape(currentPlayingSong.id);
            const selector = `.main-content .song-item[data-song-id="${safeId}"]`;
            const newPlayingItem = document.querySelector(selector);

            if (newPlayingItem) {
                console.log('[Debug:UI] 該当する song-item を発見しました。ハイライトを適用します。');
                newPlayingItem.classList.add('playing');
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

    renderQueueView();
}

/**
 * 指定された曲の再生回数表示を更新する
 */
export function updatePlayCountDisplay(songPath, count) {
    try {
        const safePath = CSS.escape(songPath);
        const songItem = document.querySelector(`.main-content .song-item[data-song-path="${safePath}"]`);
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

function renderQueueView() {
    elements.queueList.innerHTML = '';
    if (state.playbackQueue.length === 0) {
        elements.queueList.innerHTML = '<p class="no-lyrics">再生キューは空です</p>';
        return;
    }
    state.playbackQueue.forEach((song, index) => {
        const isPlaying = index === state.currentSongIndex;
        const queueItem = createQueueItem(song, isPlaying, ipcRenderer);
        queueItem.addEventListener('click', () => playSong(index));
        elements.queueList.appendChild(queueItem);
    });

    if (typeof window.observeNewArtworks === 'function') {
        window.observeNewArtworks(elements.queueList);
    }
}

export function initUI() {
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
        e.stopPropagation();
        elements.mtpDevicePopup.classList.toggle('active');
        elements.devicePopup.classList.remove('active');
    });

    document.addEventListener('click', (e) => {
        if (!elements.mtpDevicePopup.contains(e.target) && !elements.mtpDeviceButton.contains(e.target)) {
            elements.mtpDevicePopup.classList.remove('active');
        }
    });

    ipcRenderer.on('mtp-device-status', (event, device) => {
        console.log('[MTP-LOG] MTPデバイスステータス受信:', device);
        updateMtpDeviceView(device);
    });

    elements.mtpTransferQueueBtn.addEventListener('click', () => {
        elements.mainContent.classList.add('hidden');
        elements.mtpTransferView.classList.remove('hidden');
        elements.mtpDevicePopup.classList.remove('active');
    });

    elements.mtpTransferCloseBtn.addEventListener('click', () => {
        elements.mtpTransferView.classList.add('hidden');
        elements.mainContent.classList.remove('hidden');
    });

    // MTPストレージを参照ボタン
    if (elements.mtpBrowseStorageBtn) {
        elements.mtpBrowseStorageBtn.addEventListener('click', () => {
            elements.mtpDevicePopup.classList.remove('active');

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                showNotification('ストレージ情報がありません');
                hideNotification(3000);
                return;
            }

            // ナビゲーションを使用してMTPブラウザビューを表示
            showView('mtp-browser-view', {
                storageId: state.mtpStorages[0].id,
                initialPath: '/'
            });
        });
    }

    // 未転送曲検出ボタン
    const detectBtn = document.getElementById('mtp-detect-untransferred-btn');
    if (detectBtn) {
        detectBtn.addEventListener('click', detectUntransferredSongs);
    }

    // すべて転送ボタン
    const transferAllBtn = document.getElementById('mtp-transfer-all-btn');
    if (transferAllBtn) {
        transferAllBtn.addEventListener('click', transferAllUntransferred);
    }
}

/**
 * 未転送曲を検出
 */
async function detectUntransferredSongs() {
    const statusEl = document.getElementById('mtp-sync-status');
    const listEl = document.getElementById('mtp-untransferred-list');
    const actionsEl = document.getElementById('mtp-sync-actions');
    const countEl = document.getElementById('mtp-untransferred-count');
    const detectBtn = document.getElementById('mtp-detect-untransferred-btn');

    if (!state.mtpStorages || state.mtpStorages.length === 0) {
        statusEl.textContent = '❌ デバイスが接続されていません';
        return;
    }

    detectBtn.disabled = true;
    statusEl.textContent = '🔍 デバイス内の曲をスキャン中...';
    listEl.classList.add('hidden');
    actionsEl.classList.add('hidden');

    try {
        // Walkman内の全音楽ファイルを取得
        const result = await ipcRenderer.invoke('mtp-scan-all-music', {
            storageId: state.mtpStorages[0].id,
            basePath: '/Music'
        });

        if (result.error) {
            statusEl.textContent = `❌ スキャンエラー: ${result.error}`;
            detectBtn.disabled = false;
            return;
        }

        const deviceFiles = result.files || [];
        const deviceFileNames = new Set(deviceFiles.map(f => f.name.toLowerCase()));

        // ライブラリと比較して未転送曲を検出
        const untransferred = state.library.filter(song => {
            const fileName = song.path.split('/').pop().toLowerCase();
            return !deviceFileNames.has(fileName);
        });

        state.untransferredSongs = untransferred;

        if (untransferred.length === 0) {
            statusEl.textContent = '✅ すべての曲が転送済みです';
            listEl.classList.add('hidden');
            actionsEl.classList.add('hidden');
        } else {
            statusEl.textContent = `📋 ${untransferred.length}件の未転送曲が見つかりました`;

            // リストを表示
            listEl.innerHTML = untransferred.slice(0, 50).map(song => `
                <div class="untransferred-item">
                    <span class="song-title">${escapeHtml(song.title || song.path.split('/').pop())}</span>
                    <span class="song-artist">${escapeHtml(song.artist || '不明なアーティスト')}</span>
                </div>
            `).join('');

            if (untransferred.length > 50) {
                listEl.innerHTML += `<div class="untransferred-item">... 他${untransferred.length - 50}件</div>`;
            }

            listEl.classList.remove('hidden');
            actionsEl.classList.remove('hidden');
            countEl.textContent = `${untransferred.length}曲`;
        }

    } catch (err) {
        statusEl.textContent = `❌ エラー: ${err.message}`;
    } finally {
        detectBtn.disabled = false;
    }
}

/**
 * 未転送曲をすべて転送
 */
async function transferAllUntransferred() {
    if (!state.untransferredSongs || state.untransferredSongs.length === 0) {
        showNotification('転送する曲がありません');
        hideNotification(3000);
        return;
    }

    if (!state.mtpStorages || state.mtpStorages.length === 0) {
        showNotification('デバイスが接続されていません');
        hideNotification(3000);
        return;
    }

    const count = state.untransferredSongs.length;
    if (!confirm(`${count}曲をデバイスに転送しますか？`)) {
        return;
    }

    const paths = state.untransferredSongs.map(song => song.path);
    const storageId = state.mtpStorages[0].id;

    showNotification(`${count}曲の転送を開始します...`);

    try {
        // request-mtp-transfer を使用して転送
        ipcRenderer.send('request-mtp-transfer', {
            filePaths: paths,
            storageId: storageId,
            destinationPath: '/Music/'
        });

        // 転送完了後は再スキャンを促す
        showNotification('転送を開始しました。完了後は再スキャンしてください。');
        hideNotification(5000);

    } catch (err) {
        showNotification(`転送エラー: ${err.message}`);
        hideNotification(3000);
    }
}

/**
 * HTMLエスケープ
 */
function escapeHtml(str) {
    if (!str) return '';
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

function updateMtpDeviceView(device) {
    if (device) {
        elements.mtpDeviceButton.classList.remove('hidden');
        elements.mtpDeviceName.textContent = device.name || 'MTP Device';
        elements.mtpTransferDeviceName.textContent = device.name || 'MTP Device';

        if (device.storage && device.storage.total > 0) {
            const { free, total } = device.storage;
            const used = total - free;
            const usedPercent = (used / total) * 100;
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

        if (!elements.mtpTransferView.classList.contains('hidden')) {
            elements.mtpTransferView.classList.add('hidden');
            elements.mainContent.classList.remove('hidden');
            showNotification('MTPデバイスが切断されました。', 'error');
            hideNotification(3000);
        }
    }
}

export function addSongsToLibrary({ songs, albums }) {
    console.time('Renderer: Process Library Data');
    let migrationNeeded = false;

    if (albums && Object.keys(albums).length === 0 && songs && songs.length > 0 && songs[0].artwork && typeof songs[0].artwork !== 'object') {
        migrationNeeded = true;
        state.albums.clear();
    } else if (albums) {
        state.albums = new Map(Object.entries(albums));
    }

    if (songs && songs.length > 0) {
        const libraryMap = new Map();
        state.library.forEach(song => libraryMap.set(song.path, song));

        songs.forEach(newSong => {
            if (libraryMap.has(newSong.path)) {
                const existingSong = libraryMap.get(newSong.path);
                Object.assign(existingSong, newSong);
            } else {
                state.library.push(newSong);
            }
        });
    }

    groupLibraryByAlbum(migrationNeeded);
    groupLibraryByArtist();
    if (migrationNeeded) {
        const albumsToSave = Object.fromEntries(state.albums.entries());
        ipcRenderer.send('save-migrated-data', { songs: state.library, albums: albumsToSave });
    }
    renderCurrentView();
    console.timeEnd('Renderer: Process Library Data');
}

function groupLibraryByAlbum(isMigration = false) {
    const tempAlbumGroups = new Map();
    const localSongs = state.library.filter(song => !song.sourceURL);

    localSongs.forEach(song => {
        const albumTitle = song.album || 'Unknown Album';

        if (!tempAlbumGroups.has(albumTitle)) {
            tempAlbumGroups.set(albumTitle, {
                songs: [],
                artistSet: new Set(),
                artwork: null
            });
        }

        const albumGroup = tempAlbumGroups.get(albumTitle);
        albumGroup.songs.push(song);
        const artist = song.albumartist || song.artist;
        if (artist) {
            albumGroup.artistSet.add(artist);
        }

        if (albumTitle !== 'Unknown Album' && !albumGroup.artwork && song.artwork) {
            albumGroup.artwork = song.artwork;
        }
    });

    const oldAlbums = new Map(state.albums);
    state.albums.clear();

    for (const [albumTitle, albumData] of tempAlbumGroups.entries()) {
        let representativeArtist;
        if (albumData.artistSet.size === 1) {
            representativeArtist = [...albumData.artistSet][0];
        } else {
            representativeArtist = 'Unknown Artist';
        }

        const albumKey = `${albumTitle}---${representativeArtist}`;
        albumData.songs.forEach(song => {
            song.albumKey = albumKey;
        });

        let finalArtwork = albumData.artwork;
        if (!finalArtwork) {
            for (const oldAlbum of oldAlbums.values()) {
                if (oldAlbum.title === albumTitle && oldAlbum.artwork) {
                    finalArtwork = oldAlbum.artwork;
                    break;
                }
            }
        }

        state.albums.set(albumKey, {
            title: albumTitle,
            artist: representativeArtist,
            songs: albumData.songs,
            artwork: finalArtwork
        });
    }

    if (isMigration) {
        state.library.forEach(song => {
            delete song.artwork;
        });
    }
}

function groupLibraryByArtist() {
    state.artists.clear();
    const tempArtistGroups = new Map();
    const localSongs = state.library.filter(song => !song.sourceURL);
    localSongs.forEach(song => {
        const artistName = song.albumartist || song.artist || 'Unknown Artist';
        if (!tempArtistGroups.has(artistName)) {
            tempArtistGroups.set(artistName, []);
        }
        tempArtistGroups.get(artistName).push(song);
    });
    for (const [artistName, songs] of tempArtistGroups.entries()) {
        const firstAlbumKey = songs[0]?.albumKey;
        const representativeAlbum = state.albums.get(firstAlbumKey);
        state.artists.set(artistName, {
            name: artistName,
            artwork: representativeAlbum?.artwork || null,
            songs: songs
        });
    }
}

export async function updateAudioDevices() {
    try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const settings = await ipcRenderer.invoke('get-settings');
        const hiddenDevices = settings.hiddenDeviceIds || [];

        const audioDevices = devices.filter(device =>
            device.kind === 'audiooutput' && !hiddenDevices.includes(device.deviceId)
        );

        elements.devicePopup.innerHTML = '';
        const activeDeviceId = settings.audioOutputId || 'default';

        const directLinkDevice = {
            deviceId: 'ux-direct-link',
            label: 'UX Audio Router (Direct)',
            isVirtual: true
        };
        const displayDevices = [directLinkDevice, ...audioDevices];

        displayDevices.forEach(device => {
            const item = document.createElement('div');
            item.className = 'device-popup-item';

            if (device.isVirtual) {
                item.style.fontWeight = 'bold';
                item.style.color = '#7289da';
            }

            item.textContent = device.label || `スピーカー ${elements.devicePopup.children.length + 1}`;
            item.dataset.deviceId = device.deviceId;

            if (device.deviceId === activeDeviceId) {
                item.classList.add('active');
            }

            item.addEventListener('click', async () => {
                const newDeviceId = item.dataset.deviceId;
                await stopPlayer();
                state.currentSongIndex = -1;
                updateNowPlayingView(null);
                loadLyricsForSong(null);
                updatePlayingIndicators();
                await setAudioOutput(newDeviceId);
                elements.devicePopup.querySelectorAll('.device-popup-item').forEach(i => i.classList.remove('active'));
                item.classList.add('active');
                elements.devicePopup.classList.remove('active');
            });

            if (!device.isVirtual) {
                item.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    showContextMenu(e.pageX, e.pageY, [
                        {
                            label: 'このデバイスを非表示にする',
                            action: () => {
                                const deviceIdToHide = item.dataset.deviceId;
                                const updatedHiddenDevices = [...hiddenDevices, deviceIdToHide];
                                ipcRenderer.send('save-settings', { hiddenDeviceIds: updatedHiddenDevices });
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