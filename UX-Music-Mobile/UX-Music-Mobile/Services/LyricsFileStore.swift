import CryptoKit
import Foundation

/// Persists lyrics fetched from the desktop Wear API under `DownloadedLyrics/`, keyed by the same
/// stem as downloaded audio (`SHA256(songId)`). Also persists the optional Japanese translation
/// sidecar (`<stem>.ja.lrc` / `<stem>.ja.txt`), mirroring the desktop's `{base}.ja.lrc` /
/// `{base}.ja.txt` convention.
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

    /// Saves lyrics text; `type` should be `lrc` or `txt` (as returned by `/v1/remote/lyrics`).
    /// Only replaces the main `<stem>.lrc`/`<stem>.txt` file — any translation sidecar for the same
    /// song is left untouched (see `saveTranslation`/`remove(for:)`).
    func saveLyrics(_ content: String, wearType: String, songId: String) throws {
        let stem = Self.stem(for: songId)
        let ext = Self.normalisedExtension(wearType)
        removeMainLyricsFiles(forStem: stem)
        let dest = lyricsDirectory.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
        guard let data = content.data(using: .utf8) else { return }
        try data.write(to: dest, options: .atomic)
    }

    /// Saves the Japanese translation sidecar; `translationFormat` should be `lrc` or `txt` (as
    /// returned by `/v1/remote/lyrics`'s `translationFormat`). Only replaces the translation file —
    /// the main lyrics file is left untouched.
    func saveTranslation(_ content: String, translationFormat: String, songId: String) throws {
        let stem = Self.stem(for: songId)
        let ext = Self.normalisedExtension(translationFormat)
        removeTranslationFiles(forStem: stem)
        let dest = lyricsDirectory.appendingPathComponent("\(stem).ja.\(ext)", isDirectory: false)
        guard let data = content.data(using: .utf8) else { return }
        try data.write(to: dest, options: .atomic)
    }

    /// Removes both the main lyrics file and the translation sidecar (if any) for `songId`.
    func remove(for songId: String) {
        let stem = Self.stem(for: songId)
        removeMainLyricsFiles(forStem: stem)
        removeTranslationFiles(forStem: stem)
    }

    func plainTextIfPresent(for songId: String) -> String? {
        let stem = Self.stem(for: songId)
        guard let url = resolvedMainLyricsURL(stem: stem) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Japanese translation text, if a sidecar was saved for this track.
    func translationPlainTextIfPresent(for songId: String) -> String? {
        let stem = Self.stem(for: songId)
        guard let url = resolvedTranslationURL(stem: stem) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func hasLyrics(for songId: String) -> Bool {
        resolvedMainLyricsURL(stem: Self.stem(for: songId)) != nil
    }

    /// `true` when `DownloadedLyrics/<stem>.lrc` exists (synced timing should be applied).
    func hasLRCFile(for songId: String) -> Bool {
        fileManager.fileExists(atPath: mainFileURL(stem: Self.stem(for: songId), ext: "lrc").path)
    }

    /// `true` when `DownloadedLyrics/<stem>.ja.lrc` exists (timed Japanese translation).
    func hasJaLRCFile(for songId: String) -> Bool {
        fileManager.fileExists(atPath: translationFileURL(stem: Self.stem(for: songId), ext: "lrc").path)
    }

    private func mainFileURL(stem: String, ext: String) -> URL {
        lyricsDirectory.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
    }

    private func translationFileURL(stem: String, ext: String) -> URL {
        lyricsDirectory.appendingPathComponent("\(stem).ja.\(ext)", isDirectory: false)
    }

    private func resolvedMainLyricsURL(stem: String) -> URL? {
        for ext in ["lrc", "txt"] {
            let u = mainFileURL(stem: stem, ext: ext)
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func resolvedTranslationURL(stem: String) -> URL? {
        for ext in ["lrc", "txt"] {
            let u = translationFileURL(stem: stem, ext: ext)
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Removes exactly `<stem>.lrc` / `<stem>.txt` — deliberately not a directory scan keyed on
    /// `deletingPathExtension`, which would only strip the last extension and so could not tell
    /// `<stem>.ja.lrc` (a translation file) apart from `<stem>.lrc` (the main file) correctly.
    private func removeMainLyricsFiles(forStem stem: String) {
        for ext in ["lrc", "txt"] {
            let u = mainFileURL(stem: stem, ext: ext)
            if fileManager.fileExists(atPath: u.path) {
                try? fileManager.removeItem(at: u)
            }
        }
    }

    private func removeTranslationFiles(forStem stem: String) {
        for ext in ["lrc", "txt"] {
            let u = translationFileURL(stem: stem, ext: ext)
            if fileManager.fileExists(atPath: u.path) {
                try? fileManager.removeItem(at: u)
            }
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
