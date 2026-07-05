import { state, elements } from './state.js';
import {
    renderTrackView,
    renderAlbumView,
    renderArtistView,
    renderPlaylistView,
    renderAlbumDetailView,
    renderArtistDetailView,
    renderPlaylistDetailView,
    renderSituationView,
    clearMainContent
} from '../ui/view-renderer.js';
import { stopQuiz } from '../features/quiz.js';
import { stopLrcEditing, renderLrcEditor } from '../features/lrc-editor.js';
import { renderCdRipView, stopCDRipView } from '../features/cd-ripper.js';
import { stopMtpBrowser, renderMtpBrowserView } from '../features/mtp-browser.js';
import { musicApi } from './bridge.js';
import { renderNormalizeView } from '../features/normalize-view.js';
import { renderQuizView } from '../features/quiz.js';
import { renderMtpTransferView } from '../features/mtp-transfer-view.js';

/**
 * ナビ上は一覧ではなく、直前の一覧ビューのハイライトを維持する ID
 * （MTP ブラウザはサイドの nav-link があるが isOverlayNav 扱い）
 */
const OVERLAY_NAV_VIEWS = new Set([
    'normalize-view',
    'quiz-view',
    'lrc-editor-view',
    'cd-rip-view',
    'mtp-browser-view',
    'mtp-transfer-view',
]);

/** 戻るボタンの対象となる詳細ビュー */
const DETAIL_VIEWS = new Set([
    'album-detail-view',
    'artist-detail-view',
    'playlist-detail-view',
]);

interface ViewHistoryEntry {
    viewId: string;
    options: Record<string, unknown>;
}

/** 詳細ビューへ遷移した際の遷移元を積むナビゲーション履歴 */
const viewHistory: ViewHistoryEntry[] = [];
let currentViewEntry: ViewHistoryEntry | null = null;

export function canGoBack() {
    return viewHistory.length > 0;
}

/** 履歴上の一つ前のビューへ戻る */
export async function goBack() {
    const entry = viewHistory.pop();
    if (!entry) return;
    await showView(entry.viewId, { ...entry.options, isBackNavigation: true });
}

let viewSessionAbort: AbortController | null = null;

function newViewSessionSignal(): AbortSignal {
    viewSessionAbort?.abort();
    viewSessionAbort = new AbortController();
    return viewSessionAbort.signal;
}

type ViewHandler = (opts: Record<string, unknown> & { signal: AbortSignal }) => void | Promise<void>;

const VIEW_HANDLERS: Record<string, ViewHandler> = {
    'track-view': async () => {
        renderTrackView();
    },
    'album-view': () => {
        renderAlbumView();
    },
    'artist-view': () => {
        renderArtistView();
    },
    'situation-view': async () => {
        await renderSituationView();
    },
    'playlist-view': () => {
        renderPlaylistView();
    },
    'album-detail-view': (opts) => {
        renderAlbumDetailView(opts.data);
    },
    'artist-detail-view': (opts) => {
        renderArtistDetailView(opts.data);
    },
    'playlist-detail-view': (opts) => {
        renderPlaylistDetailView(opts.data);
    },
    'normalize-view': (opts) => {
        renderNormalizeView(elements.mainContent, { signal: opts.signal });
    },
    'quiz-view': (opts) => {
        renderQuizView(elements.mainContent, { signal: opts.signal });
    },
    'lrc-editor-view': async (opts) => {
        const song = opts.track;
        if (!song) {
            console.warn('[Navigation] lrc-editor-view: missing track in options');
            return;
        }
        await renderLrcEditor(elements.mainContent, song, { signal: opts.signal });
    },
    'cd-rip-view': async () => {
        await renderCdRipView(elements.mainContent);
    },
    'mtp-browser-view': async (opts) => {
        await renderMtpBrowserView(elements.mainContent, {
            storageId: opts.storageId as number,
            initialPath: (opts.initialPath as string) || '/',
        });
    },
    'mtp-transfer-view': () => {
        renderMtpTransferView(elements.mainContent);
    },
};

/**
 * 指定されたIDのビューを表示する
 * @param {string} viewId
 * @param {object} options
 */
export async function showView(viewId, options: Record<string, unknown> = {}) {
    if (viewId !== 'quiz-view') stopQuiz();
    if (viewId !== 'lrc-editor-view') stopLrcEditing();
    if (viewId !== 'cd-rip-view') stopCDRipView();
    if (viewId !== 'mtp-browser-view') stopMtpBrowser();

    const signal = newViewSessionSignal();

    // ナビゲーション履歴の更新（オーバーレイ系ビューは履歴に関与しない）
    const isBackNavigation = options.isBackNavigation === true;
    if (!OVERLAY_NAV_VIEWS.has(viewId)) {
        if (isBackNavigation) {
            // goBack 由来: 履歴は goBack 側で pop 済み
        } else if (DETAIL_VIEWS.has(viewId)) {
            if (currentViewEntry) {
                viewHistory.push(currentViewEntry);
            }
        } else {
            // 一覧ビューへの通常遷移では履歴を破棄する
            viewHistory.length = 0;
        }
        currentViewEntry = { viewId, options: { ...options, isBackNavigation: undefined } };
    }

    state.activeViewId = viewId;
    elements.navLinks.forEach((l) => l.classList.remove('active'));
    const mainViewLink = document.querySelector(`.nav-link[data-view="${viewId}"]`);
    const isOverlayNav = OVERLAY_NAV_VIEWS.has(viewId);

    if (mainViewLink && !isOverlayNav) {
        mainViewLink.classList.add('active');
        state.activeListView = viewId;
        state.currentDetailView = { type: null, identifier: null, data: null };
    } else if (!isOverlayNav) {
        state.currentDetailView = {
            type: options.type as string | null,
            identifier: options.identifier as string | null,
            data: options.data,
        };
        const correspondingListViewLink = document.querySelector(`.nav-link[data-view="${options.type}-view"]`);
        if (correspondingListViewLink) {
            correspondingListViewLink.classList.add('active');
        }
    } else {
        state.currentDetailView = { type: null, identifier: null, data: null };
        const lastListViewLink = document.querySelector(`.nav-link[data-view="${state.activeListView}"]`);
        if (lastListViewLink) lastListViewLink.classList.add('active');
    }

    if (elements.mainContent) {
        elements.mainContent.classList.remove('hidden');
    }
    clearMainContent();

    const run = VIEW_HANDLERS[viewId];
    if (run) {
        await run({ ...options, signal });
    } else {
        console.warn(`[Navigation] No handler for view: ${viewId}`);
    }
}

export function initNavigation() {
    elements.navLinks.forEach((link) => {
        if (link.id === 'mtp-device-nav-link') return;

        link.addEventListener('click', (e) => {
            e.preventDefault();
            const v = link.dataset.view;
            void showView(v);
        });
    });
}

export function showSituationPlaylistDetail(playlistDetails) {
    state.currentlyViewedSongIds = (playlistDetails.songs || [])
        .map((song) => song.id)
        .filter(Boolean);
    void showView('playlist-detail-view', { type: 'situation', identifier: playlistDetails.name, data: playlistDetails });
}

export async function showPlaylist(playlistName) {
    try {
        const playlistDetails = await musicApi.getPlaylistDetails(playlistName);
        if (!playlistDetails) {
            console.error('[Navigation] Playlist details are null');
            return;
        }
        state.currentlyViewedSongIds = (playlistDetails.songs || [])
            .map((song) => song.id)
            .filter(Boolean);
        await showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: playlistDetails });
    } catch (error) {
        console.error(`[Navigation] Failed to show playlist: ${playlistName}`, error);
    }
}

export function showAlbum(albumKey) {
    const album = state.albums.get(albumKey);
    if (!album) return;
    state.currentlyViewedSongIds = Array.from((album as Record<string, unknown>).songIds as Iterable<string> || []);
    void showView('album-detail-view', { type: 'album', identifier: albumKey, data: album });
}

export function showArtist(artistName) {
    const artist = state.artists.get(artistName);
    if (!artist) return;
    state.currentlyViewedSongIds = Array.from((artist as Record<string, unknown>).songIds as Iterable<string> || []);
    void showView('artist-detail-view', { type: 'artist', identifier: artistName, data: artist });
}
