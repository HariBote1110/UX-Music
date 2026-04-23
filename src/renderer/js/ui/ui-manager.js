// uxmusic/src/renderer/js/ui-manager.js

import { state, elements } from '../core/state.js';
import { playSong } from '../features/playback-manager.js';
import { createQueueItem } from './element-factory.js';
import { showView } from '../core/navigation.js';
import { setAudioOutput, setVisualizerTarget, stop as stopPlayer } from '../features/player.js';
import { updateNowPlayingView } from './now-playing.js';
import { loadLyricsForSong } from '../features/lyrics-manager.js';
import { showNotification, hideNotification } from './notification.js';
import { showContextMenu, formatBytes } from './utils.js';
import { eventsOn } from '../core/api/runtime-events.js';
import { musicApi } from '../core/bridge.js';
let lastPlayingQueueIndex = -1;
/** @type {HTMLElement | null} */
let cachedMainPlayingItem = null;

export function rebuildLibraryIndexes() {
    state.libraryById = new Map();
    state.libraryByPath = new Map();

    state.library.forEach((song) => {
        if (!song?.id && song?.path) {
            song.id = song.path;
        }
        if (song?.id) {
            state.libraryById.set(song.id, song);
        }
        if (song?.path) {
            state.libraryByPath.set(song.path, song);
        }
    });
}

export function getSongById(songId) {
    return state.libraryById.get(songId) || null;
}

export function getSongByPath(songPath) {
    return state.libraryByPath.get(songPath) || null;
}

export function resolveSongsByIds(songIds = []) {
    return songIds
        .map((songId) => getSongById(songId))
        .filter(Boolean);
}

export function getAlbumSongs(album) {
    if (!album) return [];
    return resolveSongsByIds(album.songIds || []);
}

export function getArtistSongs(artist) {
    if (!artist) return [];
    return resolveSongsByIds(artist.songIds || []);
}

export function setCurrentViewSongs(songs = []) {
    state.currentlyViewedSongIds = songs.map((song) => song.id).filter(Boolean);
}

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
    const playingIdentifier = currentPlayingSong?.id || currentPlayingSong?.path;
    console.log(`[Debug:UI] updatePlayingIndicators 実行 - SongID: ${playingIdentifier}`);

    if (cachedMainPlayingItem) {
        cachedMainPlayingItem.classList.remove('playing');
        cachedMainPlayingItem = null;
    }

    if (currentPlayingSong && playingIdentifier) {
        try {
            const safeId = CSS.escape(playingIdentifier);
            const selector = `.main-content .song-item[data-song-id="${safeId}"]`;
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

export function initUI() {
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

    eventsOn('mtp-device-connected', (payload) => {
        console.log('[MTP-LOG] mtp-device-connected 受信:', payload);
        // payload: { device: { name, ... }, storages: [...] }
        updateMtpDeviceView(payload);
    });

    eventsOn('mtp-device-disconnected', () => {
        console.log('[MTP-LOG] mtp-device-disconnected 受信');
        updateMtpDeviceView(null);
    });

    elements.mtpTransferQueueBtn.addEventListener('click', () => {
        elements.mainContent.classList.add('hidden');
        elements.mtpTransferView.classList.remove('hidden');
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
            showView('mtp-browser-view', {
                storageId: state.mtpStorages[0].id,
                initialPath: '/'
            });
        });
    };
}

function updateMtpDeviceView(payload) {
    if (payload && payload.device) {
        const device = payload.device;
        const storages = payload.storages;

        elements.mtpDeviceButton.classList.remove('hidden');
        elements.mtpDeviceName.textContent = device.name || 'MTP Device';
        elements.mtpTransferDeviceName.textContent = device.name || 'MTP Device';

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
        // Electron 移行用 save-migrated-data は Wails では不要（ライブラリは Go 側が永続化）
    }
    renderCurrentView();
    console.timeEnd('Renderer: Process Library Data');
}

function normaliseTagText(value, fallback = '') {
    if (typeof value !== 'string') {
        return fallback;
    }
    const trimmed = value.trim();
    return trimmed || fallback;
}

function groupLibraryByAlbum(isMigration = false) {
    const tempAlbumGroups = new Map();
    const localSongs = state.library.filter(song => !song.sourceURL);

    const albumMetaByTitle = new Map();
    localSongs.forEach(song => {
        const albumTitle = normaliseTagText(song.album, 'Unknown Album');
        if (!albumMetaByTitle.has(albumTitle)) {
            albumMetaByTitle.set(albumTitle, { albumArtists: new Set(), artists: new Set() });
        }

        const albumMeta = albumMetaByTitle.get(albumTitle);
        const albumArtistFromTag = normaliseTagText(song.albumartist);
        if (albumArtistFromTag) {
            albumMeta.albumArtists.add(albumArtistFromTag);
        }
        albumMeta.artists.add(normaliseTagText(song.artist, 'Unknown Artist'));
    });

    const resolveRepresentativeArtist = (albumTitle) => {
        const albumMeta = albumMetaByTitle.get(albumTitle);
        if (!albumMeta) {
            return 'Unknown Artist';
        }

        if (albumMeta.albumArtists.size === 1) {
            return [...albumMeta.albumArtists][0];
        }
        if (albumMeta.albumArtists.size > 1) {
            return 'Various Artists';
        }

        if (albumMeta.artists.size === 1) {
            return [...albumMeta.artists][0];
        }
        if (albumMeta.artists.size > 1) {
            return 'Various Artists';
        }

        return 'Unknown Artist';
    };

    localSongs.forEach(song => {
        const albumTitle = normaliseTagText(song.album, 'Unknown Album');
        const groupKey = albumTitle;

        if (!tempAlbumGroups.has(groupKey)) {
            tempAlbumGroups.set(groupKey, {
                title: albumTitle,
                artist: resolveRepresentativeArtist(albumTitle),
                songIds: [],
                artwork: null
            });
        }

        const albumGroup = tempAlbumGroups.get(groupKey);
        albumGroup.songIds.push(song.id);

        if (albumTitle !== 'Unknown Album' && !albumGroup.artwork && song.artwork) {
            albumGroup.artwork = song.artwork;
        }
    });

    const oldAlbums = new Map(state.albums);
    state.albums.clear();

    for (const [groupKey, albumData] of tempAlbumGroups.entries()) {
        const albumTitle = albumData.title;
        const albumKey = groupKey;
        resolveSongsByIds(albumData.songIds).forEach(song => {
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
            artist: albumData.artist,
            songIds: albumData.songIds,
            artwork: finalArtwork
        });
    }

    if (isMigration) {
        state.library.forEach(song => {
            delete song.artwork;
        });
    }
}

function upsertAlbumForSong(song) {
    const albumTitle = normaliseTagText(song.album, 'Unknown Album');
    const albumKey = albumTitle;
    const existingAlbum = state.albums.get(albumKey);
    const songIds = existingAlbum?.songIds ? [...existingAlbum.songIds] : [];

    if (!songIds.includes(song.id)) {
        songIds.push(song.id);
    }

    song.albumKey = albumKey;

    const albumArtist = normaliseTagText(song.albumartist);
    let artist = albumArtist || normaliseTagText(song.artist, 'Unknown Artist');
    if (existingAlbum?.artist && existingAlbum.artist !== artist) {
        artist = 'Various Artists';
    }

    state.albums.set(albumKey, {
        title: albumTitle,
        artist,
        songIds,
        artwork: existingAlbum?.artwork || song.artwork || null
    });
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
        tempArtistGroups.get(artistName).push(song.id);
    });
    for (const [artistName, songIds] of tempArtistGroups.entries()) {
        const firstSong = getSongById(songIds[0]);
        const firstAlbumKey = firstSong?.albumKey;
        const representativeAlbum = state.albums.get(firstAlbumKey);
        state.artists.set(artistName, {
            name: artistName,
            artwork: representativeAlbum?.artwork || null,
            songIds: songIds
        });
    }
}

function upsertArtistForSong(song) {
    const artistName = song.albumartist || song.artist || 'Unknown Artist';
    const existingArtist = state.artists.get(artistName);
    const songIds = existingArtist?.songIds ? [...existingArtist.songIds] : [];

    if (!songIds.includes(song.id)) {
        songIds.push(song.id);
    }

    const representativeAlbum = state.albums.get(song.albumKey);
    state.artists.set(artistName, {
        name: artistName,
        artwork: existingArtist?.artwork || representativeAlbum?.artwork || null,
        songIds
    });
}

export function regroupLibraryCollections() {
    groupLibraryByAlbum(false);
    groupLibraryByArtist();
}

export async function updateAudioDevices() {
    try {
        console.log('[AudioDevices] enumerating devices...');

        if (window.go) {
            const settings = await musicApi.getSettings();
            const activeDeviceId = settings.audioOutputId || 'default';
            elements.devicePopup.innerHTML = '';

            try {
                const goDevices = await window.go.main.App.AudioListDevices();
                console.log('[AudioDevices] Go devices:', goDevices);

                goDevices.forEach(d => {
                    const item = document.createElement('div');
                    item.className = 'device-popup-item';
                    item.textContent = d.name;
                    item.dataset.deviceId = d.id;
                    if (d.id === activeDeviceId) item.classList.add('active');

                    item.addEventListener('click', async () => {
                        const newDeviceId = item.dataset.deviceId;
                        await stopPlayer();
                        state.currentSongIndex = -1;
                        updateNowPlayingView(null);
                        loadLyricsForSong(null);
                        updatePlayingIndicators();
                        await setAudioOutput(newDeviceId);
                        // UI更新のために再描画
                        elements.devicePopup.querySelectorAll('.device-popup-item').forEach(i => i.classList.remove('active'));
                        item.classList.add('active');
                        elements.devicePopup.classList.remove('active');
                    });
                    elements.devicePopup.appendChild(item);
                });
            } catch (e) { console.error("Failed to list audio devices via Go:", e); }
            return;
        }

        let devices = await navigator.mediaDevices.enumerateDevices();

        // 権限がない場合 deviceId と label が空文字になる
        // Wails環境では getUserMedia で権限を取得してから再度 enumerateDevices を呼ぶ必要がある
        const hasEmptyDeviceIds = devices.some(d => d.kind === 'audiooutput' && d.deviceId === '');
        if (hasEmptyDeviceIds && window.go) {
            console.log('[AudioDevices] Detected devices with empty IDs, requesting media permission...');
            try {
                const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
                stream.getTracks().forEach(t => t.stop());
                // 権限取得後に再度列挙
                devices = await navigator.mediaDevices.enumerateDevices();
                console.log('[AudioDevices] Devices after permission:', devices.map(d => ({ kind: d.kind, label: d.label, id: d.deviceId })));
            } catch (permErr) {
                console.warn('[AudioDevices] Permission request failed:', permErr);
            }
        }

        console.log('[AudioDevices] all devices found:', devices.map(d => ({ kind: d.kind, label: d.label, id: d.deviceId })));
        const settings = await musicApi.getSettings();
        const hiddenDevices = settings.hiddenDeviceIds || [];

        const audioDevices = devices.filter(device =>
            device.kind === 'audiooutput' && !hiddenDevices.includes(device.deviceId)
        );

        const activeDeviceId = settings.audioOutputId || 'default';
        elements.devicePopup.innerHTML = '';

        if (audioDevices.length === 0 && devices.length > 0) {
            console.log('[AudioDevices] No audiooutput devices found by type filter. Checking all devices...');
            // WebKit 等では kind が正しく取得できない場合や制限されている場合がある
        }

        const directLinkDevice = {
            deviceId: 'ux-direct-link',
            label: 'UX Audio Router (Direct)',
            isVirtual: true
        };
        const displayDevices = [directLinkDevice, ...audioDevices];

        // デバイスが見つからない場合のヘルパー
        if (audioDevices.length === 0 && window.go) {
            const permissionItem = document.createElement('div');
            permissionItem.className = 'device-popup-item permission-prompt';
            permissionItem.textContent = '🔊 デバイス一覧を更新（アクセス許可）';
            permissionItem.style.color = '#ffaa00';
            permissionItem.style.fontSize = '0.9em';
            permissionItem.addEventListener('click', async (e) => {
                e.stopPropagation();
                try {
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
        if (navigator.mediaDevices.selectAudioOutput) {
            const selectItem = document.createElement('div');
            selectItem.className = 'device-popup-item';
            selectItem.textContent = '📄 システムの選択画面を開く...';
            selectItem.style.borderBottom = '1px solid #334';
            selectItem.addEventListener('click', async (e) => {
                e.stopPropagation();
                try {
                    const device = await navigator.mediaDevices.selectAudioOutput();
                    await setAudioOutput(device.deviceId);
                    updateAudioDevices();
                } catch (err) {
                    if (err.name !== 'NotAllowedError') console.error('selectAudioOutput error:', err);
                }
            });
            elements.devicePopup.appendChild(selectItem);
        }

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
                                musicApi.saveSettings({ hiddenDeviceIds: updatedHiddenDevices });
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
