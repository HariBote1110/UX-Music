import { state, elements } from '../core/state.js';
import { setVisualizerTarget, disconnectVisualizerObserver } from '../features/player.js';
import {
    createListHeader,
    setupSongListScroller,
    initListHeaderResizing
} from './list-renderer.js';
import {
    renderAlbumView,
    renderArtistView,
    renderSituationView,
    renderPlaylistView
} from './grid-renderer.js';
// ▼▼▼ 追加 ▼▼▼
import {
    renderAlbumDetailView as renderAlbumDetail,
    renderArtistDetailView as renderArtistDetail,
    renderPlaylistDetailView as renderPlaylistDetail
} from './detail-renderer.js';
// ▲▲▲ 追加 ▲▲▲
const electronAPI = window.electronAPI; // renderTrackView が使用

let trackViewScroller = null;
let detailViewScroller = null;
// const lastScrollPositions = {}; // detail-renderer.js に移動

/**
 * メインコンテンツをクリアし、スクローラーを破棄する
 */
export function clearMainContent() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
    if (detailViewScroller) {
        detailViewScroller.destroy();
        detailViewScroller = null;
    }
    disconnectVisualizerObserver();
    elements.mainContent.innerHTML = '';
    state.selectedSongIds.clear();
    state.currentlyViewedSongIds = [];
}

/**
 * トラックビューのスクローラー（もしあれば）を破棄する
 */
export function destroyTrackViewScroller() {
    if (trackViewScroller) {
        trackViewScroller.destroy();
        trackViewScroller = null;
    }
}

/**
 * 曲ビュー用に state.library をアルバム単位でグループ化してソートした配列を返す。
 * - アルバムの出現順はライブラリ内の初登場インデックスで決まる（追加順を維持）
 * - アルバム内はカスタム順 → ディスク番号 → トラック番号の優先度でソート
 */
function buildSortedTrackList() {
    // アルバムの初登場インデックスを収集
    const albumFirstIndex = new Map();
    state.library.forEach((song, i) => {
        const key = song.albumKey || '';
        if (!albumFirstIndex.has(key)) albumFirstIndex.set(key, i);
    });

    // albumKey ごとにグループ化
    const groups = new Map();
    state.library.forEach(song => {
        const key = song.albumKey || '';
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(song);
    });

    // 各グループ内をソート
    for (const songs of groups.values()) {
        const hasCustomOrder = songs.some(s => (s.customOrder ?? 0) > 0);
        if (hasCustomOrder) {
            songs.sort((a, b) => (a.customOrder ?? 9999) - (b.customOrder ?? 9999));
        } else {
            songs.sort((a, b) => {
                const disc = (a.discNumber || 0) - (b.discNumber || 0);
                if (disc !== 0) return disc;
                return (a.trackNumber || 0) - (b.trackNumber || 0);
            });
        }
    }

    // アルバムを初登場順に並べて連結
    return [...albumFirstIndex.keys()]
        .sort((a, b) => albumFirstIndex.get(a) - albumFirstIndex.get(b))
        .flatMap(key => groups.get(key) ?? []);
}

/**
 * 曲一覧（トラックビュー）を描画する
 */
export function renderTrackView() {
    clearMainContent();
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.id = 'track-view';
    viewWrapper.innerHTML = `
        <h1>曲</h1>
        ${createListHeader()}
    `;
    const musicListContainer = document.createElement('div');
    musicListContainer.id = 'music-list';
    viewWrapper.appendChild(musicListContainer);
    elements.mainContent.appendChild(viewWrapper);

    if (state.library.length === 0) {
        musicListContainer.innerHTML = '<div class="placeholder">音楽ファイルやフォルダをここにドラッグ＆ドロップしてください</div>';
        return;
    }

    const sortedSongs = buildSortedTrackList();
    state.currentlyViewedSongIds = sortedSongs.map(s => s.id).filter(Boolean);

    trackViewScroller = setupSongListScroller(musicListContainer, sortedSongs, {
        contextView: 'library'
    });

    initListHeaderResizing(viewWrapper);
}

// ▼▼▼ 追加 (detail-renderer.js へのラッパー関数) ▼▼▼
/**
 * アルバム詳細ビューを描画し、スクローラーを管理する
 * @param {object} album 
 */
export function renderAlbumDetailView(album) {
    detailViewScroller = renderAlbumDetail(album);
}

/**
 * アーティスト詳細ビューを描画し、スクローラーを管理する
 * @param {object} artist 
 */
export function renderArtistDetailView(artist) {
    detailViewScroller = renderArtistDetail(artist); // スクロラが無くても null が返る
}

/**
 * プレイリスト詳細ビューを描画し、スクローラーを管理する
 * @param {object} playlistDetails 
 */
export function renderPlaylistDetailView(playlistDetails) {
    detailViewScroller = renderPlaylistDetail(playlistDetails);
}
// ▲▲▲ 追加 ▲▲▲

// grid-renderer.js からインポートした関数を再エクスポート
export {
    renderAlbumView,
    renderArtistView,
    renderSituationView,
    renderPlaylistView
};
