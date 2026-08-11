import Foundation

/// User-selectable audio quality for new downloads from the desktop server. Persisted on
/// `AppModel.downloadAudioQuality` (mirrors `LibrarySortOrder`'s `UserDefaults` pattern) — changing
/// it only shapes downloads requested afterwards; songs already downloaded are not touched
/// (see `progress/download-audio-quality.md`).
enum DownloadAudioQuality: String, CaseIterable, Identifiable, Sendable {
    /// Full-quality original bytes only (current/legacy behaviour, and the default).
    case original
    /// AAC-LC 128 kbps transcode only (`GET /v1/remote/file` without `source=original`).
    case aac
    /// Both variants: original for full-quality playback, AAC alongside for a fast Watch transfer.
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return String(localized: "Full Quality")
        case .aac: return String(localized: "AAC (Small)")
        case .both: return String(localized: "Full + AAC")
        }
    }

    /// `AppModel.init`'s restore helper: an unknown or missing raw value falls back to `.original`.
    static func restored(fromRawValue raw: String?) -> DownloadAudioQuality {
        guard let raw, let value = DownloadAudioQuality(rawValue: raw) else { return .original }
        return value
    }
}

/// One HTTP request `AppModel.downloadSong` must perform for a given `DownloadAudioQuality`
/// (see `DownloadRequestPlan.steps`).
struct DownloadRequestStep: Equatable {
    let preferOriginalAudio: Bool
}

/// Derives the download sequence for a `DownloadAudioQuality` — a pure function so the mapping is
/// unit-testable without touching the network or filesystem.
enum DownloadRequestPlan {
    static func steps(for quality: DownloadAudioQuality) -> [DownloadRequestStep] {
        switch quality {
        case .original:
            return [DownloadRequestStep(preferOriginalAudio: true)]
        case .aac:
            return [DownloadRequestStep(preferOriginalAudio: false)]
        case .both:
            return [
                DownloadRequestStep(preferOriginalAudio: true),
                DownloadRequestStep(preferOriginalAudio: false),
            ]
        }
    }
}

/// Decision for `DownloadManager.finalizeDownloadedAACPart`: the desktop server falls back to
/// serving ORIGINAL bytes when its ffmpeg is unavailable, so a download requested as "AAC" may
/// actually be the original file's bytes (flac/mp3/etc). Kept as a pure function so the decision
/// table is unit-testable without touching the filesystem.
enum AACVariantFinalisePlan: Equatable {
    /// Sniffed bytes are m4a — genuinely the AAC variant; store as `<stem>_aac.m4a`.
    case storeAsVariant
    /// Sniffed bytes are not m4a (server fell back to original) and no original file exists yet;
    /// store via the normal original-file path instead.
    case storeAsOriginal
    /// Sniffed bytes are not m4a and an original file is already present; discard the duplicate.
    case discard

    static func plan(sniffedExtension: String, originalAlreadyPresent: Bool) -> AACVariantFinalisePlan {
        guard sniffedExtension.lowercased() == "m4a" else {
            return originalAlreadyPresent ? .discard : .storeAsOriginal
        }
        return .storeAsVariant
    }
}
