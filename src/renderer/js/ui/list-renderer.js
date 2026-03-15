// src/renderer/js/ui/list-renderer.js

import { state, elements } from '../core/state.js';
import { playSong } from '../features/playback-manager.js';
import { setVisualizerTarget } from '../features/player.js';
import { VirtualScroller } from './virtual-scroller.js';
import { createSongItem } from './element-factory.js';
import { initColumnResizing } from './column-resizer.js';
import { showContextMenu } from './utils.js';
import { showModalAdvanced } from './modal.js';
import { getVisibleColumns, getGridTemplate, showColumnContextMenu } from './column-config.js';
import { updateGridStyle } from './column-resizer.js';
const electronAPI = window.electronAPI;

/**
 * 曲リストの共通ヘッダーHTMLを作成する（column-config に基づく動的生成）
 */
export function createListHeader() {
    const visibleCols = getVisibleColumns();
    const headerCells = visibleCols.map(col => {
        const content = col.label ? `<span>${col.label}</span>` : '';
        return `<div class="${col.cssClass}">${content}</div>`;
    }).join('\n            ');
    return `
        <div id="music-list-header">
            ${headerCells}
        </div>
    `;
}

/**
 * 曲アイテムのクリックイベントを処理する (再生または複数選択)
 */
function handleSongItemClick(e, song, index, songList, songItem) {
    if (e.metaKey || e.ctrlKey) {
        if (state.selectedSongIds.has(song.id)) {
            state.selectedSongIds.delete(song.id);
            songItem.classList.remove('selected');
        } else {
            state.selectedSongIds.add(song.id);
            songItem.classList.add('selected');
        }
    } else {
        playSong(index, songList);
    }
}

function deleteSongsFromLibrary(songs) {
    console.log('[DeleteSongs] context action invoked', songs);

    const paths = (songs || [])
        .map((s) => {
            if (s?.path) return s.path;
            const resolved = s?.id ? state.libraryById.get(s.id) : null;
            return resolved?.path || '';
        })
        .filter(Boolean);
    console.log('[DeleteSongs] resolved paths:', paths);
    if (paths.length === 0) {
        console.warn('[DeleteSongs] No valid file paths found in selected songs');
        return;
    }

    const targetCount = paths.length;
    const message = targetCount === 1
        ? '選択した1曲をライブラリから削除します。'
        : `選択した${targetCount}曲をライブラリから削除します。`;

    showModalAdvanced({
        title: '曲を削除',
        message,
        requireInput: false,
        okText: '削除',
        cancelText: 'キャンセル',
        onOk: () => {
            if (!window.go?.main?.App?.DeleteSongs) {
                console.error('[DeleteSongs] App.DeleteSongs is not available on window.go.main.App');
                return;
            }

            console.log('[DeleteSongs] invoking backend DeleteSongs');
            let pendingWarnTimer = null;
            let deletePromise;
            try {
                deletePromise = window.go.main.App.DeleteSongs(paths, false);
            } catch (err) {
                console.error('[DeleteSongs] invocation threw:', err);
                return;
            }
            pendingWarnTimer = setTimeout(() => {
                console.warn('[DeleteSongs] backend call is still pending after 5s');
            }, 5000);

            Promise.resolve(deletePromise)
                .then((deletedPaths) => {
                    clearTimeout(pendingWarnTimer);
                    console.log('[DeleteSongs] backend result:', deletedPaths);
                    const normalizedDeleted = Array.isArray(deletedPaths) ? deletedPaths : paths;
                    if (window.runtime?.EventsEmit && normalizedDeleted.length > 0) {
                        window.runtime.EventsEmit('songs-deleted', normalizedDeleted);
                    }
                    if (window.go?.main?.App?.LoadLibrary) {
                        // Always refresh from persisted library in Wails to avoid stale in-memory state.
                        window.go.main.App.LoadLibrary();
                    }
                })
                .catch((err) => {
                    clearTimeout(pendingWarnTimer);
                    console.error('[DeleteSongs] failed:', err);
                });
        }
    });
}

/**
 * VirtualScroller をセットアップし、曲リストを描画する
 */
export function setupSongListScroller(listElement, songList, options = {}) {
    const {
        contextView = 'library',
        playlistName = null,
        initialScrollTop = 0,
        saveScrollPosition // detail-renderer から渡されるコールバック
    } = options;

    /**
     * VirtualScroller が各アイテムを描画するための関数
     */
    const renderItem = (song, index) => {
        const songItem = createSongItem(song, index, songList, {
            groupAlbumArt: state.groupAlbumArt || state.isLightFlightMode
        });

        // 選択状態の復元
        if (state.selectedSongIds.has(song.id)) {
            songItem.classList.add('selected');
        }

        // ▼▼▼ 修正箇所 ▼▼▼
        const currentPlayingSong = state.playbackQueue[state.currentSongIndex];
        const currentIdentifier = currentPlayingSong?.id || currentPlayingSong?.path;
        const rowIdentifier = song?.id || song?.path;
        if (currentPlayingSong && currentIdentifier && rowIdentifier && currentIdentifier === rowIdentifier) {
            songItem.classList.add('playing');

            // このアイテムがDOMに挿入された時点でターゲットに設定
            // (visualizer.js 側で同一要素チェックを行う)
            setVisualizerTarget(songItem);
        }
        // ▲▲▲ 修正箇所 ▲▲▲

        // イベントリスナー
        songItem.addEventListener('click', (e) => handleSongItemClick(e, song, index, songList, songItem));

        songItem.addEventListener('contextmenu', (e) => {
            e.preventDefault();

            if (playlistName && typeof saveScrollPosition === 'function') {
                saveScrollPosition(listElement.scrollTop);
            }

            let songsForMenu = [song];
            if (state.selectedSongIds.size > 0 && state.selectedSongIds.has(song.id)) {
                songsForMenu = songList.filter(s => state.selectedSongIds.has(s.id));
            }

            if (typeof window.go !== 'undefined') {
                // Wails 環境: JavaScript ベースのコンテキストメニュー
                const menuItems = [
                    {
                        label: '再生',
                        action: () => playSong(index, songList)
                    },
                    {
                        label: songsForMenu.length > 1 ? `ライブラリから削除 (${songsForMenu.length}曲)` : 'ライブラリから削除',
                        action: () => deleteSongsFromLibrary(songsForMenu)
                    }
                ];

                // プレイリストがある場合のみサブメニューを追加
                if (state.playlists && state.playlists.length > 0) {
                    const playlistSubmenu = state.playlists.map(playlist => ({
                        label: playlist.name,
                        action: () => {
                            // TODO: プレイリストに曲を追加する処理
                            console.log(`Adding songs to playlist: ${playlist.name}`, songsForMenu);
                        }
                    }));
                    menuItems.push({
                        label: 'プレイリストに追加',
                        submenu: playlistSubmenu
                    });
                }

                showContextMenu(e.pageX, e.pageY, menuItems);
            } else {
                // Electron 環境: メインプロセスにメニュー表示を委譲
                electronAPI.send('show-song-context-menu', {
                    songs: songsForMenu,
                    context: { view: contextView, playlistName }
                });
            }
        });

        window.observeNewArtworks(songItem); // Lazy-load 用
        return songItem;
    };

    // VirtualScroller の初期化
    const scroller = new VirtualScroller({
        element: listElement,
        data: songList,
        itemHeight: 56,
        renderItem: renderItem,
    });

    if (initialScrollTop > 0) {
        requestAnimationFrame(() => {
            listElement.scrollTop = initialScrollTop;
        });
    }

    // ▼▼▼ 削除（renderItem 内に移動したため） ▼▼▼
    // requestAnimationFrame(() => {
    //     const playingItem = listElement.querySelector('.song-item.playing');
    //     if (playingItem) {
    //         setVisualizerTarget(playingItem);
    //     }
    // });
    // ▲▲▲ 削除 ▲▲▲

    return scroller;
}

/**
 * リストヘッダーの列サイズ変更機能を初期化する
 */
export function initListHeaderResizing(viewWrapper) {
    // 可視列に基づいた初期Gridスタイルを適用
    updateGridStyle(getGridTemplate());

    const headerEl = viewWrapper.querySelector('#music-list-header');
    if (headerEl) {
        initColumnResizing(headerEl);

        // ヘッダー右クリックで列の表示/非表示メニューを表示
        headerEl.addEventListener('contextmenu', (e) => {
            // 子要素のコンテキストメニューも捕捉
            e.preventDefault();
            e.stopPropagation();
            showColumnContextMenu(e, () => {
                // コールバック: ビューを再描画して列変更を反映
                import('../ui/ui-manager.js').then(mod => mod.renderCurrentView());
            });
        });
    }
}
