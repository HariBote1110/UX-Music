# UX Music Mobile (iOS)

Native **Swift + SwiftUI** companion for the desktop UX Music unified LAN API v1 (default port `8765`, path prefix `/v1/remote`; see `progress/lan-api-v1.md`).

The previous Flutter implementation is archived as [`UX-Music-Mobile-Legacy`](../UX-Music-Mobile-Legacy).

### Discovery

UX Music Mobile can discover desktop UX Music instances from the UX Sync mDNS service:

- **Service:** `_uxmusic-sync._tcp.local.`
- **Profile:** the LAN API v1 `/v1/remote/*` namespace is the lightweight mobile/wearable profile of UX Sync.
- **Selection:** Settings lists discovered `LibraryHost` / `WearHost` peers and saves the selected host/port to the existing server configuration.
- **Transport:** LAN requests use a dedicated direct session so local `192.168.x.x:8765` traffic is not sent through system proxy, iCloud relay, or cellular fallback.

### LAN API v1 (phone-oriented)

- **`GET /v1/identity`** — public health/identity check (hostname, `protocolVersion`, `schemaVersion`, roles). No auth required.
- **`POST /v1/pairing/redeem`** — exchanges a one-time QR pairing secret (`{secret, deviceId, displayName}`) for a device-specific auth token (`{deviceId, token}`).
- **`GET /v1/remote/file?id=…&source=original`** — serves the **library file as-is** (no Watch AAC 128k transcode). Omit `source` for the transcoded path.
- **Auth:** every endpoint but `/v1/identity` and `/v1/pairing/*` requires `Authorization: Bearer <token>`; media GET endpoints (`file`, `artwork`) also accept `?token=` for loaders that cannot set headers.
- **Downloaded jackets** — after a track download, the app saves artwork under **`Documents/DownloadedArtwork/*.img`** and `artworkURL(for:)` prefers `file://` when present.

## Open in Xcode

Open `UX-Music-Mobile.xcodeproj`, select an iPhone simulator or device, then Run.

## Requirements

- Xcode 16+ (Swift 5)
- iOS 17 deployment target

## Tests

```bash
xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Adjust the simulator name to one installed on your Mac (`xcrun simctl list devices available`).

### Real-device discovery probe

Run this only when a desktop UX Music instance is open on the same Wi-Fi network. The test is skipped during normal test runs and enabled with a Swift flag:

```bash
xcodebuild -project UX-Music-Mobile.xcodeproj \
  -scheme UX-Music-Mobile \
  -destination 'platform=iOS,id=<device-id>' \
  'OTHER_SWIFT_FLAGS=$(inherited) -DUX_MUSIC_REAL_DEVICE_DISCOVERY_TEST' \
  -only-testing:UX-Music-MobileTests/LANDiscoveryPeerTests/testRealDeviceDiscoversUXSyncMDNSPeer \
  test
```

## Parity with Flutter (Legacy)

The legacy app lives in [`UX-Music-Mobile-Legacy`](../UX-Music-Mobile-Legacy). This target mirrors its main flows: **local library** (downloaded tracks), **remote library** (album/song views, download, album detail), **remote control** (polled desktop state + commands), **settings** (host/port, save, test ping), **mini player** and **now playing** for local `AVPlayer` playback, plus **LUFS-based volume** when `/v1/remote/loudness` is available. The unused Flutter `DownloadsScreen` (not on the tab bar) is not recreated separately.
