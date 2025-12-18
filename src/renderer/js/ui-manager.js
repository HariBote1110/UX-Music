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
    showView(state.activeViewId, state.currentDetailView);
    renderQueueView();
}

/**
 * 再生中の曲の表示（ハイライトやイコライザー）を更新する
 */
export function updatePlayingIndicators() {
    const currentPlayingSong = state.playbackQueue[state.currentSongIndex];

    const oldPlayingItems = document.querySelectorAll('.main-content .song-item.playing');
    oldPlayingItems.forEach(item => item.classList.remove('playing'));

    if (currentPlayingSong) {
        try {
            const safeId = CSS.escape(currentPlayingSong.id);
            const newPlayingItem = document.querySelector(`.main-content .song-item[data-song-id="${safeId}"]`);
            if (newPlayingItem) {
                newPlayingItem.classList.add('playing');
                setVisualizerTarget(newPlayingItem);
            }
        } catch (e) {
            console.error('Error selecting song item:', e);
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
    window.observeNewArtworks(elements.queueList);
}

export function initUI() {
    elements.sidebarTabs.forEach(tab => {
        tab.addEventListener('click', () => {
            elements.sidebarTabs.forEach(t => t.classList.remove('active'));
            elements.sidebarTabContents.forEach(c => c.classList.remove('active'));
            tab.classList.add('active');
            document.getElementById(tab.dataset.tab).classList.add('active');
            renderQueueView();
        });
    });

    // MTPデバイスボタンのクリックイベント
    elements.mtpDeviceButton.addEventListener('click', (e) => {
        e.stopPropagation();
        elements.mtpDevicePopup.classList.toggle('active');
        elements.devicePopup.classList.remove('active');
    });

    // MTPデバイスポップアップの外側をクリックしたら閉じる
    document.addEventListener('click', (e) => {
        if (!elements.mtpDevicePopup.contains(e.target) && !elements.mtpDeviceButton.contains(e.target)) {
            elements.mtpDevicePopup.classList.remove('active');
        }
    });
    
    // メインプロセスからのMTPデバイス状態変更通知を受け取る
    ipcRenderer.on('mtp-device-status', (event, device) => {
        console.log('[MTP-LOG] レンダラーが "mtp-device-status" イベントを受信しました。デバイス情報:', device);
        updateMtpDeviceView(device);
    });
    console.log('[MTP-LOG] initUI完了。MTPデバイスのリスナーを設定しました。');

    // MTPポップアップの「キューを転送」ボタンのクリックイベント
    elements.mtpTransferQueueBtn.addEventListener('click', () => {
        elements.mainContent.classList.add('hidden');
        elements.mtpTransferView.classList.remove('hidden');
        elements.mtpDevicePopup.classList.remove('active');
        console.log('[MTP-LOG] 転送ビューを開きました。');
    });

    // 転送ビューの「閉じる」ボタンのクリックイベント
    elements.mtpTransferCloseBtn.addEventListener('click', () => {
        elements.mtpTransferView.classList.add('hidden');
        elements.mainContent.classList.remove('hidden');
        console.log('[MTP-LOG] 転送ビューを閉じました。');
    });
}

/**
 * MTPデバイスUIの状態を更新する
 */
function updateMtpDeviceView(device) {
    console.log('[MTP-LOG] updateMtpDeviceView が呼ばれました。デバイス:', device ? device.name : 'null');

    if (device) {
        elements.mtpDeviceButton.classList.remove('hidden'); 
        elements.mtpDeviceName.textContent = device.name || 'MTP Device';
        elements.mtpTransferDeviceName.textContent = device.name || 'MTP Device';
        
        console.log('[MTP-LOG] ボタンの "hidden" クラスを削除しました。'); 
        
        if (device.storage && device.storage.total > 0) {
            const { free, total } = device.storage;
            const used = total - free;
            const usedPercent = (used / total) * 100;
            
            const fBytes = typeof formatBytes === 'function' ? formatBytes : (b) => `${(b / 1024**3).toFixed(1)} GB`;

            elements.mtpStorageUsed.style.width = `${usedPercent}%`;
            elements.mtpStorageLabel.textContent = `${fBytes(free)} 空き (${fBytes(used)} / ${fBytes(total)})`;
        } else {
            console.warn('[MTP-LOG] デバイスのストレージ情報が利用できません。', device.storage);
            elements.mtpStorageUsed.style.width = '0%';
            elements.mtpStorageLabel.textContent = 'ストレージ情報なし';
        }
    } else {
        elements.mtpDeviceButton.classList.add('hidden');
        elements.mtpDevicePopup.classList.remove('active');
        console.log('[MTP-LOG] ボタンに "hidden" クラスを追加しました (切断)。');
        
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
        console.log('[Migration Check] Old artwork format detected. Migration needed.');
        state.albums.clear(); 
    } else if (albums) {
        state.albums = new Map(Object.entries(albums));
    }

    if (songs && songs.length > 0) {
        const libraryMap = new Map();
        state.library.forEach(song => libraryMap.set(song.path, song));

        songs.forEach(newSong => {
            if (libraryMap.has(newSong.path)) {
                // 既存の曲: プロパティを更新
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
    console.time('Renderer: groupLibraryByAlbum');
    
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
    
    console.timeEnd('Renderer: groupLibraryByAlbum');
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

        // --- ▼▼▼ 修正: 仮想デバイス(Direct Link)を追加 ▼▼▼ ---
        const directLinkDevice = {
            deviceId: 'ux-direct-link',
            label: 'UX Audio Router (Direct)',
            isVirtual: true
        };
        // リストの先頭に追加
        const displayDevices = [directLinkDevice, ...audioDevices];
        // --- ▲▲▲ 修正ここまで ▲▲▲ ---

        displayDevices.forEach(device => {
            const item = document.createElement('div');
            item.className = 'device-popup-item';
            
            // 仮想デバイスのスタイルリング
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

            // 仮想デバイス以外のみコンテキストメニュー
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
                                showNotification(`「${item.textContent}」を非表示にしました。`);
                                hideNotification(3000);
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