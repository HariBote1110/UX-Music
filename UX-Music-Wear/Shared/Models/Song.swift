import Foundation

/// Mirrors the Go scanner.Song struct (JSON schema must remain compatible)
struct Song: Codable, Identifiable, Hashable {
    let id: String
    let path: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let year: Int
    let genre: String
    let duration: Double
    let trackNumber: Int
    let discNumber: Int
    let fileSize: Int64
    let fileType: String
    let sampleRate: Int?
    let bitDepth: Int?

    // artwork is excluded — fetched separately via /wear/artwork/{id}

    enum CodingKeys: String, CodingKey {
        case id, path, title, artist, album, year, genre, duration, fileSize, fileType
        case albumArtist = "albumartist"
        case trackNumber, discNumber, sampleRate, bitDepth
    }

    var displayTitle: String { title.isEmpty ? (path as NSString).lastPathComponent : title }
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }

    var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
