import Foundation

/// Mirrors the `type` field the desktop library stores per song (`server/app_youtube.go`'s
/// `buildStreamingSong`/`AddYouTubeLink` write `"youtube"`; ordinary scanned files have no `type`
/// key at all, which decodes to `.local`).
enum SongSourceType: String, Codable, Equatable, Hashable, Sendable {
    case local
    case youtube
}

/// Mirrors the `GET /v1/remote/songs` payload (same keys as Flutter `Song`).
struct Song: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var path: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var year: Int
    var genre: String
    var duration: Double
    var trackNumber: Int
    var discNumber: Int
    var fileSize: Int
    var fileType: String
    var sampleRate: Int?
    var bitDepth: Int?
    var artworkId: String
    var sourceType: SongSourceType
    var sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case id, path, title, artist, album, year, genre, duration
        case trackNumber, discNumber, fileSize, fileType, sampleRate, bitDepth, artworkId
        case albumArtist = "albumartist"
        case sourceType = "type"
        case sourceURL
    }

    init(
        id: String,
        path: String,
        title: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        year: Int = 0,
        genre: String = "",
        duration: Double = 0,
        trackNumber: Int = 0,
        discNumber: Int = 0,
        fileSize: Int = 0,
        fileType: String = "",
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        artworkId: String = "",
        sourceType: SongSourceType = .local,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.genre = genre
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.fileSize = fileSize
        self.fileType = fileType
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.artworkId = artworkId
        self.sourceType = sourceType
        self.sourceURL = sourceURL
    }

    /// `true` for songs registered via `AddYouTubeLink` (embed/stream modes). These have no local
    /// file on the desktop's disk in the same sense a scanned file does, so download and Watch
    /// transfer are not offered for them (see `WatchTransferMenuPolicy`).
    var isYouTube: Bool { sourceType == .youtube }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(albumArtist, forKey: .albumArtist)
        try c.encode(year, forKey: .year)
        try c.encode(genre, forKey: .genre)
        try c.encode(duration, forKey: .duration)
        try c.encode(trackNumber, forKey: .trackNumber)
        try c.encode(discNumber, forKey: .discNumber)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(fileType, forKey: .fileType)
        try c.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try c.encodeIfPresent(bitDepth, forKey: .bitDepth)
        try c.encode(artworkId, forKey: .artworkId)
        try c.encode(sourceType, forKey: .sourceType)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        year = try Self.decodeIntFlexible(c, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        trackNumber = try Self.decodeIntFlexible(c, forKey: .trackNumber)
        discNumber = try Self.decodeIntFlexible(c, forKey: .discNumber)
        fileSize = try Self.decodeIntFlexible(c, forKey: .fileSize)
        fileType = try c.decodeIfPresent(String.self, forKey: .fileType) ?? ""
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
        artworkId = try c.decodeIfPresent(String.self, forKey: .artworkId) ?? ""
        sourceType = try c.decodeIfPresent(SongSourceType.self, forKey: .sourceType) ?? .local
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
    }

    var displayTitle: String { title.isEmpty ? "Unknown Title" : title }
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }

    /// Album bucket matching `Album.fromSongs` (trimmed title, `Unknown Album` when empty).
    var groupingAlbumTitle: String {
        let t = album.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Unknown Album" : t
    }

    /// Flat local-library order: album name, then disc, track, then title when tags tie or are missing.
    static func libraryFlatDisplayOrderAscending(_ a: Song, _ b: Song) -> Bool {
        let albumCmp = a.groupingAlbumTitle.localizedCaseInsensitiveCompare(b.groupingAlbumTitle)
        if albumCmp != .orderedSame {
            return albumCmp == .orderedAscending
        }
        if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
        if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
        return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    func withPath(_ newPath: String) -> Song {
        var s = self
        s.path = newPath
        return s
    }

    private static func decodeIntFlexible(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Int {
        if let v = try c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let d = try c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return 0
    }
}
