import Combine
import Foundation

/// Fetches the library data the Phase 1-3 browse shelves need
/// (`markdown/appletv-servermode-plan.md` §1-3) via the shared `RemoteAPIClient`, and derives
/// albums with the same `Album.fromSongs` grouping the iOS app uses (desktop-parity album keys —
/// see `Models/Album.swift`).
///
/// No "最近再生" (recently played) shelf: `/v1/remote/*` exposes no play-history endpoint as of
/// this writing (only `/v1/remote/songs`, `/v1/remote/playlists`, `/v1/remote/loudness`,
/// `/v1/remote/artwork`, `/v1/remote/file`) — see `progress/tvos-playback.md`. The shelf is
/// omitted rather than faked; add it back if/when a history endpoint ships.
@MainActor
final class TVBrowseModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var songs: [Song] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var playlists: [RemoteDesktopPlaylist] = []

    private let client: RemoteAPIClient

    init(client: RemoteAPIClient) {
        self.client = client
    }

    func reload() async {
        loadState = .loading
        do {
            async let songsResult = client.fetchSongs()
            async let playlistsResult = client.fetchDesktopPlaylists()
            let fetchedSongs = try await songsResult
            let fetchedPlaylists = try await playlistsResult
            songs = fetchedSongs
            albums = Album.fromSongs(fetchedSongs)
            playlists = fetchedPlaylists
            loadState = .loaded
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }
}
