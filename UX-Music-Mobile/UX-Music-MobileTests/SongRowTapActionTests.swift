import Testing
@testable import UX_Music_Mobile

/// `Song.rowTapAction` is the single place that decides what tapping a `SongRowView` row does,
/// shared by every screen that lists songs (Remote list, album detail, playlist detail). This
/// guards the regression where YouTube songs kept the old "download" tap target on screens other
/// than the top-level Remote list.
struct SongRowTapActionTests {
    @Test
    func youTubeSongAlwaysOpensThePlayerRegardlessOfDownloadState() {
        let song = Song(id: "yt-1", path: "", sourceType: .youtube)

        #expect(song.rowTapAction(isDownloaded: false) == .openYouTubePlayer(song))
        #expect(song.rowTapAction(isDownloaded: true) == .openYouTubePlayer(song))
    }

    @Test
    func downloadedLocalSongPlaysLocally() {
        let song = Song(id: "local-1", path: "/tmp/song.flac", sourceType: .local)

        #expect(song.rowTapAction(isDownloaded: true) == .playDownloaded(song))
    }

    @Test
    func notYetDownloadedLocalSongIsInert() {
        let song = Song(id: "local-2", path: "/tmp/song.flac", sourceType: .local)

        #expect(song.rowTapAction(isDownloaded: false) == .none)
    }
}
