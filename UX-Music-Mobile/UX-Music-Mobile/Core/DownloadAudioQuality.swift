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

/// User-selectable AAC bitrate for new AAC downloads from the desktop server (`GET
/// /v1/remote/file?bitrate=…`, only meaningful when `preferOriginalAudio == false`). Persisted on
/// `AppModel.downloadAACBitrate` (mirrors `DownloadAudioQuality`'s `UserDefaults` pattern). Watch
/// transfers are unaffected by this setting: `WatchTransferAudioPolicy` already passes ≤192 kbps m4a
/// through unmodified and re-transcodes anything above that to 128 kbps on-device, so a 256/320 kbps
/// download still ends up at 128 kbps on the Watch (see `progress/download-audio-quality.md`).
enum DownloadAACBitrate: Int, CaseIterable, Identifiable, Sendable {
    case kbps128 = 128
    case kbps192 = 192
    case kbps256 = 256
    case kbps320 = 320

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .kbps128: return String(localized: "128 kbps")
        case .kbps192: return String(localized: "192 kbps")
        case .kbps256: return String(localized: "256 kbps")
        case .kbps320: return String(localized: "320 kbps")
        }
    }

    /// The bitrate used when no valid setting has been persisted yet.
    static let defaultValue: DownloadAACBitrate = .kbps256

    /// `AppModel.init`'s restore helper: an unknown or missing raw value (e.g. `0` from a never-set
    /// `UserDefaults` key) falls back to `defaultValue`.
    static func restored(fromRawValue raw: Int) -> DownloadAACBitrate {
        DownloadAACBitrate(rawValue: raw) ?? .defaultValue
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
