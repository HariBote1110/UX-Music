import CryptoKit
import Foundation

/// Persists lyrics fetched from the desktop Wear API under `DownloadedLyrics/`, keyed by the same stem as downloaded audio (`SHA256(songId)`).
@MainActor
final class LyricsFileStore {
    private let lyricsDirectory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, lyricsDirectoryOverride: URL? = nil) {
        self.fileManager = fileManager
        if let lyricsDirectoryOverride {
            lyricsDirectory = lyricsDirectoryOverride
        } else {
            let doc = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            lyricsDirectory = doc.appendingPathComponent("DownloadedLyrics", isDirectory: true)
        }
        try? fileManager.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
    }

    /// Saves lyrics text; `type` should be `lrc` or `txt` (as returned by `/wear/lyrics`).
    func saveLyrics(_ content: String, wearType: String, songId: String) throws {
        let stem = Self.stem(for: songId)
        let ext = Self.normalisedExtension(wearType)
        removeExistingFiles(forStem: stem)
        let dest = lyricsDirectory.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
        guard let data = content.data(using: .utf8) else { return }
        try data.write(to: dest, options: .atomic)
    }

    func remove(for songId: String) {
        removeExistingFiles(forStem: Self.stem(for: songId))
    }

    func plainTextIfPresent(for songId: String) -> String? {
        let stem = Self.stem(for: songId)
        guard let url = resolvedLyricsURL(stem: stem) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func hasLyrics(for songId: String) -> Bool {
        resolvedLyricsURL(stem: Self.stem(for: songId)) != nil
    }

    private func resolvedLyricsURL(stem: String) -> URL? {
        for ext in ["lrc", "txt"] {
            let u = lyricsDirectory.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func removeExistingFiles(forStem stem: String) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: lyricsDirectory.path) else { return }
        for name in names {
            let base = (name as NSString).deletingPathExtension
            guard base == stem else { continue }
            try? fileManager.removeItem(at: lyricsDirectory.appendingPathComponent(name))
        }
    }

    private static func stem(for songId: String) -> String {
        let digest = SHA256.hash(data: Data(songId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalisedExtension(_ wearType: String) -> String {
        let t = wearType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "lrc" { return "lrc" }
        return "txt"
    }
}
