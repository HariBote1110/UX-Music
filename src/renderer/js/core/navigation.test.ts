import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    renderArtistView: vi.fn(),
    renderAlbumView: vi.fn(),
    renderAlbumDetailView: vi.fn(),
    renderArtistDetailView: vi.fn(),
}));

vi.mock('../ui/view-renderer.js', () => ({
    renderTrackView: vi.fn(),
    renderAlbumView: mocks.renderAlbumView,
    renderArtistView: mocks.renderArtistView,
    renderPlaylistView: vi.fn(),
    renderAlbumDetailView: mocks.renderAlbumDetailView,
    renderArtistDetailView: mocks.renderArtistDetailView,
    renderPlaylistDetailView: vi.fn(),
    renderSituationView: vi.fn(),
    clearMainContent: vi.fn(),
}));
vi.mock('../features/quiz.js', () => ({ stopQuiz: vi.fn(), renderQuizView: vi.fn() }));
vi.mock('../features/lrc-editor.js', () => ({ stopLrcEditing: vi.fn(), renderLrcEditor: vi.fn() }));
vi.mock('../features/cd-ripper.js', () => ({ renderCdRipView: vi.fn(), stopCDRipView: vi.fn() }));
vi.mock('../features/mtp-browser.js', () => ({ stopMtpBrowser: vi.fn(), renderMtpBrowserView: vi.fn() }));
vi.mock('./bridge.js', () => ({ musicApi: {} }));
vi.mock('../features/normalize-view.js', () => ({ renderNormalizeView: vi.fn() }));
vi.mock('../features/mtp-transfer-view.js', () => ({ renderMtpTransferView: vi.fn() }));

vi.mock('./state.js', () => ({
    state: {
        activeViewId: 'track-view',
        activeListView: 'track-view',
        currentDetailView: { type: null, identifier: null, data: null },
        currentlyViewedSongIds: [],
        albums: new Map(),
        artists: new Map(),
    },
    elements: {
        navLinks: [],
        mainContent: {
            classList: { remove: vi.fn(), add: vi.fn() },
        },
    },
}));

async function setupLibrary() {
    const { state } = await import('./state.js');
    (state as any).albums = new Map([
        ['album-1', { title: 'Test Album', artist: 'Test Artist', songIds: [] }],
    ]);
    (state as any).artists = new Map([
        ['Test Artist', { name: 'Test Artist', songIds: [] }],
    ]);
    return state;
}

describe('ナビゲーション履歴（canGoBack / goBack）', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        vi.resetModules();
        globalThis.document = {
            querySelector: vi.fn(() => null),
        } as unknown as Document;
    });

    it('一覧ビュー表示直後は戻れない', async () => {
        await setupLibrary();
        const nav = await import('./navigation.js');
        await nav.showView('artist-view');
        expect(nav.canGoBack()).toBe(false);
    });

    it('アーティスト詳細→アルバム詳細と進んだ後、goBack で順に元のビューへ戻る', async () => {
        await setupLibrary();
        const nav = await import('./navigation.js');

        await nav.showView('artist-view');
        nav.showArtist('Test Artist');
        expect(nav.canGoBack()).toBe(true);

        nav.showAlbum('album-1');
        expect(nav.canGoBack()).toBe(true);

        mocks.renderArtistDetailView.mockClear();
        await nav.goBack();
        expect(mocks.renderArtistDetailView).toHaveBeenCalledTimes(1);
        expect(nav.canGoBack()).toBe(true);

        mocks.renderArtistView.mockClear();
        await nav.goBack();
        expect(mocks.renderArtistView).toHaveBeenCalledTimes(1);
        expect(nav.canGoBack()).toBe(false);
    });

    it('サイドナビで一覧ビューへ移動すると履歴はクリアされる', async () => {
        await setupLibrary();
        const nav = await import('./navigation.js');

        await nav.showView('artist-view');
        nav.showArtist('Test Artist');
        expect(nav.canGoBack()).toBe(true);

        await nav.showView('album-view');
        expect(nav.canGoBack()).toBe(false);
    });
});
