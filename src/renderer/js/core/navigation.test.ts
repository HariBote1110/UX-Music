import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../ui/view-renderer.js', () => ({
    renderTrackView: vi.fn(),
    renderAlbumView: vi.fn(),
    renderArtistView: vi.fn(),
    renderPlaylistView: vi.fn(),
    renderAlbumDetailView: vi.fn(),
    renderArtistDetailView: vi.fn(),
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

describe('showAlbum', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        globalThis.document = {
            querySelector: vi.fn(() => null),
        } as unknown as Document;
    });

    it('アーティスト詳細から遷移した場合、戻り先アーティスト名を currentDetailView.fromArtist に記録する', async () => {
        const { state } = await import('./state.js');
        (state as any).albums = new Map([['album-1', { title: 'Test Album', artist: 'Test Artist', songIds: [] }]]);

        const { showAlbum } = await import('./navigation.js');
        await showAlbum('album-1', { fromArtist: 'Test Artist' });

        expect((state as any).currentDetailView.fromArtist).toBe('Test Artist');
    });

    it('アルバム一覧から直接遷移した場合、fromArtist は設定されない', async () => {
        const { state } = await import('./state.js');
        (state as any).albums = new Map([['album-1', { title: 'Test Album', artist: 'Test Artist', songIds: [] }]]);

        const { showAlbum } = await import('./navigation.js');
        await showAlbum('album-1');

        expect((state as any).currentDetailView.fromArtist).toBeUndefined();
    });
});
