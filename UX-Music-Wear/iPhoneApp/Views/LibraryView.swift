import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var watchBridge: WatchBridge

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .idle:
                    ContentUnavailableView(
                        "No Server Connected",
                        systemImage: "wifi.slash",
                        description: Text("Configure the UX Music server address in Settings, then tap Refresh.")
                    )

                case .loading:
                    ProgressView("Loading library…")

                case .loaded(let songs):
                    songList(songs)

                case .error(let message):
                    ContentUnavailableView(
                        "Connection Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("UX Music Wear")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { Task { await store.refresh() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.state == .loading)
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    if case .loaded(let songs) = store.state {
                        Button("Send All") {
                            watchBridge.enqueueAll(songs)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func songList(_ songs: [Song]) -> some View {
        List(songs) { song in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.displayTitle)
                        .font(.body)
                    Text("\(song.displayArtist) — \(song.displayAlbum)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    watchBridge.enqueue(song)
                } label: {
                    Image(systemName: "applewatch.and.arrow.forward")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - LibraryStore

@MainActor
final class LibraryStore: ObservableObject {

    enum State: Equatable {
        case idle, loading
        case loaded([Song])
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case (.loaded(let a), .loaded(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var state: State = .idle

    private var client: MusicServerClient?

    func configure(with settings: WearSettings) {
        guard let url = settings.baseURL else { return }
        client = MusicServerClient(baseURL: url)
    }

    func refresh() async {
        guard let client else {
            let settings = WearSettings.load()
            guard let url = settings.baseURL else {
                state = .error("No server URL configured")
                return
            }
            self.client = MusicServerClient(baseURL: url)
            await refresh()
            return
        }
        state = .loading
        do {
            let songs = try await client.fetchSongs()
            state = .loaded(songs)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
