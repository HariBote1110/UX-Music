import AVFoundation
import Combine
import Foundation

/// Plays the host's YouTube LAN relay stream (`GET /v1/remote/relay`, Phase 3-3 receiver) via
/// `AVPlayer`.
///
/// **Auth**: the relay endpoint only accepts the `Authorization` header — no `?token=` query
/// fallback (see `RemoteAPIClient.relayRequest()`'s doc comment and
/// `server/app_apierror.go`'s `isMediaQueryTokenEndpoint`). So this builds an `AVURLAsset` with
/// `AVURLAssetHTTPHeaderFieldsKey` rather than handing `AVPlayer` a bare authenticated-by-query URL.
///
/// **NEEDS ON-DEVICE VERIFICATION** (see `progress/tvos-relay-reception.md`): the host streams
/// raw chunked ADTS AAC-LC elementary-stream audio (`Content-Type: audio/aac`, no fixed
/// `Content-Length`, no HLS/fMP4 container). `AVURLAssetOverrideMIMETypeKey` is set to hint the
/// container-less MIME type at `AVFoundation`, but whether `AVPlayer` actually decodes a live,
/// container-less ADTS byte stream over plain chunked HTTP (as opposed to HLS) cannot be
/// confirmed in this environment (no real host + tvOS audio pipeline available here). This type
/// is deliberately a thin, swappable seam around `AVPlayer` for exactly that reason — if on-device
/// testing shows `AVPlayer` cannot play this, only this file should need to change (e.g. to a
/// different playback strategy), not the browse UI or `TVRelayModel`. Do NOT expand this into a
/// custom `AudioFileStream` demuxing pipeline without first confirming `AVPlayer` genuinely can't
/// handle it on a real device.
@MainActor
final class TVRelayPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false

    private let client: RemoteAPIClient
    private var player: AVPlayer?

    init(client: RemoteAPIClient) {
        self.client = client
    }

    /// Starts (or restarts) relay playback. Callers are responsible for stopping local
    /// `MusicPlayerService` playback first — this controller only owns the relay `AVPlayer`.
    func start() {
        stop()
        guard let request = try? client.relayRequest(), let url = request.url else { return }
        // `AVURLAssetHTTPHeaderFieldsKey` is not declared in the tvOS SDK's public headers (it is
        // on iOS), but the informal string key is still honoured by `AVURLAsset` on tvOS, so it's
        // passed as a raw string literal here rather than the (unavailable) named constant.
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:],
                AVURLAssetOverrideMIMETypeKey: "audio/aac"
            ]
        )
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        newPlayer.play()
        isPlaying = true
    }

    /// Stops the relay stream, if any. Safe to call when nothing is playing.
    func stop() {
        player?.pause()
        player = nil
        isPlaying = false
    }
}
