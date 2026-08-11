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

/// Decides whether a progress fraction update (0.0–1.0) is significant enough to publish to
/// `@Observable`/`@Published` state, used to throttle high-frequency progress callbacks —
/// `AppModel.downloadSong`'s URLSession progress handler and `WatchTransferBridge.sendFile`'s KVO
/// observation of `WCSessionFileTransfer.progress.fractionCompleted` both tick many times per
/// second, and publishing every tick re-renders every visible row/label observing the value (see
/// `mobile_perf_research/notes/static-review-2026-08.md` finding 3). Kept as a pure function so the
/// step size is unit-testable without a real network/transfer.
enum ProgressPublishThrottle {
    /// Minimum fractional advance since the last published value before a new update is worth
    /// publishing.
    static let step = 0.01

    /// Floating-point tolerance so a boundary advance that should count as "a full step" (e.g.
    /// `0.11 - 0.1`, which is `0.009999999999999998` in `Double`) is not rejected by binary
    /// floating-point rounding.
    private static let epsilon = 1e-9

    /// - Parameters:
    ///   - previous: The fraction most recently published (or the initial value, typically `0`).
    ///   - next: The newly observed fraction.
    /// - Returns: `true` if `next` should be published — either it advanced by at least `step`, or
    ///   it reached `1.0` (always published so a finished transfer/download never gets stuck
    ///   showing a stale sub-100% value).
    static func shouldPublish(previous: Double, next: Double) -> Bool {
        next >= 1.0 || next - previous >= step - epsilon
    }
}

/// Aggregate state for a bulk download in progress (`AppModel.downloadAlbum`/
/// `downloadPlaylistSongs`), driving the slim capsule banner shown above the Library screens'
/// content while `AppModel.bulkDownloadStatus != nil`. A single-song `AppModel.downloadSong` call
/// made outside a bulk loop never creates one of these — the per-row progress ring is enough there
/// — so the banner only ever appears for a genuine multi-song operation.
struct BulkDownloadStatus: Equatable {
    let totalCount: Int
    let completedCount: Int
    let currentTitle: String
    let currentFraction: Double
}

/// Pure status-transition logic for `BulkDownloadStatus`, extracted out of
/// `AppModel.downloadAlbum`/`downloadPlaylistSongs` so the state machine driving the bulk download
/// banner is unit-testable without a real download/network.
enum BulkDownloadStatusReducer {
    static func start(total: Int) -> BulkDownloadStatus {
        BulkDownloadStatus(totalCount: total, completedCount: 0, currentTitle: "", currentFraction: 0)
    }

    /// The next song in the batch has started: updates the displayed title and resets the
    /// per-song progress fraction back to `0`.
    static func songStarted(_ status: BulkDownloadStatus, title: String) -> BulkDownloadStatus {
        BulkDownloadStatus(totalCount: status.totalCount, completedCount: status.completedCount, currentTitle: title, currentFraction: 0)
    }

    /// A progress tick for the song currently downloading.
    static func progress(_ status: BulkDownloadStatus, fraction: Double) -> BulkDownloadStatus {
        BulkDownloadStatus(totalCount: status.totalCount, completedCount: status.completedCount, currentTitle: status.currentTitle, currentFraction: fraction)
    }

    /// The current song finished (successfully or not — `AppModel.downloadSong` already surfaces
    /// per-song failures via `downloadError`, so the bulk loop simply moves on): increments the
    /// completed count and resets the fraction for the next song.
    static func songFinished(_ status: BulkDownloadStatus) -> BulkDownloadStatus {
        BulkDownloadStatus(totalCount: status.totalCount, completedCount: status.completedCount + 1, currentTitle: status.currentTitle, currentFraction: 0)
    }

    /// The batch is done (including an early exit or error) — clears the banner.
    static func finish(_ status: BulkDownloadStatus) -> BulkDownloadStatus? {
        nil
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
