// src/renderer/js/ui/list-renderer.js

import { state, elements } from '../state.js';
import { playSong } from '../playback-manager.js';
import { setVisualizerTarget } from '../player.js';
import { VirtualScroller } from '../virtual-scroller.js';
import { createSongItem } from './element-factory.js';
import { initColumnResizing } from './column-resizer.js';
import { showContextMenu } from './utils.js';
const electronAPI = window.electronAPI;
const isWails = window.go !== undefined;

/**
 * 曲リストの共通ヘッダーHTMLを作成する
 */
export function createListHeader() {
    return `
        <div id="music-list-header">
            <div class="song-index">#</div>
            <div class="song-artwork-col"></div>
            <div class="song-title"><span>タイトル</span></div>
            <div class="song-artist"><span>アーティスト</span></div>
            <div class="song-album"><span>アルバム</span></div>
            <div class="song-hires">HR</div>
            <div class="song-duration"><span>時間</span></div>
            <div class="song-play-count"><span>回数</span></div>
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
        if (currentPlayingSong && currentPlayingSong.id === song.id) {
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

            if (isWails) {
                // Wails 環境: JavaScript ベースのコンテキストメニュー
                const menuItems = [
                    {
                        label: '再生',
                        action: () => playSong(index, songList)
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
    const headerEl = viewWrapper.querySelector('#music-list-header');
    if (headerEl) {
        initColumnResizing(headerEl);
    }
}