import Foundation

/// Picks a file extension for a Wear **original** download so `AVURLAsset` can open the file.
/// When everything was stored as `.m4a`, FLAC/MP3 bytes were mis-labelled and failed with “Cannot Open”.
enum DownloadedTrackFormatSniffer {
    /// First bytes of the completed download; `libraryPath` / `fileType` are Wear metadata fallbacks.
    static func preferredExtension(header: Data, libraryPath: String, fileType: String) -> String {
        if let sniffed = sniff(header) { return sniffed }
        if let fb = fallbackExtension(fromLibraryPath: libraryPath, fileType: fileType) { return fb }
        return "m4a"
    }

    static func sniff(_ header: Data) -> String? {
        guard !header.isEmpty else { return nil }
        if header.count >= 4, header.starts(with: Data("fLaC".utf8)) { return "flac" }
        if header.count >= 3, header.starts(with: Data("ID3".utf8)) { return "mp3" }
        if header.count >= 2 {
            let b0 = header[0], b1 = header[1]
            if b0 == 0xFF, (b1 & 0xE0) == 0xE0 { return "mp3" }
        }
        if header.count >= 8 {
            let ftyp = header.subdata(in: 4 ..< 8)
            if ftyp == Data("ftyp".utf8) { return "m4a" }
        }
        if header.count >= 4, header.starts(with: Data("OggS".utf8)) { return "ogg" }
        if header.count >= 12, header.starts(with: Data("RIFF".utf8)) {
            let wave = header.subdata(in: 8 ..< 12)
            if wave == Data("WAVE".utf8) { return "wav" }
        }
        return nil
    }

    private static let allowedFallbackExtensions: Set<String> = [
        "m4a", "mp3", "flac", "wav", "aac", "ogg", "opus", "mp4", "oga", "aif", "aiff", "caf", "wma"
    ]

    static func fallbackExtension(fromLibraryPath path: String, fileType: String) -> String? {
        let pe = (path as NSString).pathExtension.lowercased()
        if allowedFallbackExtensions.contains(pe) {
            return pe == "mp4" ? "m4a" : pe
        }
        let ft = fileType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ftNorm = ft.hasPrefix(".") ? String(ft.dropFirst()) : ft
        if allowedFallbackExtensions.contains(ftNorm) {
            return ftNorm == "mp4" ? "m4a" : ftNorm
        }
        return nil
    }
}
