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
 * 曲一覧（トラックビュー）を描画する
 */
export function renderTrackView() {
    clearMainContent();
    state.currentlyViewedSongIds = state.library.map((song) => song.id).filter(Boolean);
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

    trackViewScroller = setupSongListScroller(musicListContainer, state.library, {
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
