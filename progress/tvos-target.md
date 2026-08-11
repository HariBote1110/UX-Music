# tvOS ターゲット `UX-Music-TV` の追加（Phase 1-1）

`markdown/appletv-servermode-plan.md` Phase 1-1（tvOS ターゲットと共有レイヤ）の実装記録。

## Decision

- `UX-Music-Mobile.xcodeproj` に **`UX-Music-TV`**（tvOS 17+、SwiftUI、bundle id
  `com.uxlabs.uxMusicMobile.tv`）と **`UX-Music-TVTests`**（module 名
  `UX_Music_TV`／`UX_Music_TVTests`、`TEST_HOST` で `UX-Music-TV.app` を指す通常の
  xctest ターゲット）を追加した。Watch 統合と同じ「別プロジェクトにしない」路線を踏襲し、
  既存の iOS/watchOS ターゲットと同じ pbxproj 内にネイティブターゲットとして登録した。
- pbxproj は `objectVersion = 63`・同期グループ未使用のため、`UX-Music-TV/`・
  `UX-Music-TVTests/` 配下の新規 `.swift`／フィクスチャは全て手動で
  `PBXFileReference`/`PBXBuildFile`/`PBXSourcesBuildPhase`/`PBXResourcesBuildPhase` に
  登録した（24 桁 hex の一意 ID を新規発番）。
- 共有は「ファイルの重複コピーを作らず、既存 `PBXFileReference` に対して TV ターゲット用の
  `PBXBuildFile` を追加する」方式（Mobile/Watch 間で `AlbumGroupPosition.swift` 等が既に
  この形でターゲットメンバーシップ共有されているのに倣った）。
- TV ターゲットの Sources に追加した既存ファイル（新規ファイルは作成していない）:
  - `RemoteAPIClient.swift` / `RemoteConnectionResolver.swift` / `ConnectionCandidatePolicy.swift`
    / `LANDiscoveryService.swift`（mDNS 発見・接続解決）
  - `DeviceIdentity.swift` / `AppConstants.swift`
  - モデル: `ServerConfig.swift` / `Song.swift` / `Album.swift` / `Playlist.swift` / `Artist.swift`
  - `MusicPlayerService.swift`（AVAudioEngine + 10 バンド EQ + LUFS 正規化の中核）
  - `GraphicEqualiserConfiguration.swift`
  - `Core/WatchPlaybackLogic.swift`（`PlaybackQueueNavigation`/`PlaybackRepeatMode`/
    `PlaybackShuffleLogic` の純粋ロジック部分のみ実質的に共有——後述の `#if` 参照）
  - `Core/PlaybackQueueEditing.swift`（`PlaybackShuffleLogic` の `[Song]` オーバーロード。
    `MusicPlayerService` が実際に呼ぶのはこちら）
  - `Core/DownloadAudioQuality.swift`（`RemoteAPIClient` のダウンロードURL組み立てが参照する
    `DownloadAACBitrate`）
- `AppModel` は計画通り丸ごと共有せず、TV には移植していない（Phase 1-3 以降で TV 専用の
  軽量なコーディネータを別途組む前提）。

## `#if os(tvOS)` 追加箇所（すべて既存ファイルへの最小差分）

tvOS には WebKit（`WKWebView`）が存在しない（計画書 Phase 1-1 の明文化事項）ため、
`MusicPlayerService` が内部で保持する YouTube 埋め込みバックエンド（`YouTubePlaybackHost`
経由）は tvOS では使えない。TV は Phase 1 で YouTube 再生を一切扱わない
（Phase 3 の放送型中継のみ）ため、YouTube 関連コードパス全体を `#if !os(tvOS)` で
除外する形にした。型を分割する広範なリファクタは行わず、既存ファイル内の追加のみ:

- `UX-Music-Mobile/Services/MusicPlayerService.swift`
  - YouTube 関連のストアドプロパティ群（`youtubePlaybackHost`・
    `currentYouTubeVideoID`・`youtubePlaybackErrorMessage` 等・`resolveYouTubeVideoID`・
    `youtubeVideoIDCache`）を `#if !os(tvOS)` で除外。
  - `init()` 内の `youtubePlaybackHost.onEvent` 購読を除外。
  - `togglePlayPause()` の YouTube 分岐（`song.isYouTube` → `toggleYouTubePlayPause()`）を除外。
  - `loadActive(_:)` を `#if !os(tvOS)`（YouTube/ローカル分岐）と `#else`（常にローカル
    `AVAudioEngine` 経路 `loadAndPlay(song)` を呼ぶ）に分割。
  - `seek(to:resumeAfterSeek:)` の YouTube 早期リターン分岐を除外。
  - `stop()` 内の `stopYouTubeBackend()` 呼び出しを除外。
  - 「MARK: - YouTube playback backend」セクション丸ごと（`stopYouTubeBackend`
    `loadAndPlayYouTube` `toggleYouTubePlayPause` `handleYouTubeBridgeEvent`
    `scheduleAutoSkipAfterEmbedRestriction` `openYouTubePlaybackErrorInYouTubeApp`）を
    `#if !os(tvOS) … #endif` で除外。
- `UX-Music-Mobile/Core/WatchPlaybackLogic.swift`
  - `PlaybackShuffleLogic.applyShuffle(queue: [WatchTransferMeta], …)`（Watch 専用の
    `WatchTransferMeta` オーバーロード）を `#if !os(tvOS)` で除外。`MusicPlayerService` が
    実際に呼ぶ `[Song]` オーバーロードは `PlaybackQueueEditing.swift` 側にあるため影響なし。
  - `WatchResumeLogic` 以降（`WatchAlbumGroup`/`WatchAlbumGrouping`/`WatchFlatSongOrder`/
    `WatchNowPlayingInfoBuilder` 等、すべて `WatchTransferMeta`/`AlbumGroupPosition` に依存する
    Watch 専用ヘルパー）をファイル末尾まで `#if !os(tvOS)` で除外。`WatchTransfer.swift`／
    `AlbumGroupPosition.swift` 一式を TV ターゲットに引き込まずに済ませるための切り分け。

いずれも実際のロジック変更はなく、tvOS でコンパイル対象外にするための条件コンパイルのみ。

## Alternatives considered

- **YouTube バックエンドを別プロトコル/型に切り出す**: より「正しい」設計だが、
  Phase 1 の目的（tvOS でのローカル再生スパイクを通す）に対して過剰なリファクタになるため
  見送り。Phase 3 で TV 向け中継受信を実装する際に、その時点の要件に合わせて再検討する。
- **`WatchPlaybackLogic.swift` を Core/Watch 専用ファイルへ分割**: 同様に広範な変更になるため
  見送り、`#if` での除外に留めた。

## Constraints / Gotchas

- tvOS 実行環境（シミュレータ）はこのマシンに未インストールだった。
  `xcodebuild -downloadPlatform tvOS` で tvOS 26.5 Simulator を取得し、
  `xcrun simctl` に既存の "Apple TV" (無印) デバイスを使用してテストを実行した。
- `UIKit`／`AVAudioSession`／`MediaPlayer`（`MPRemoteCommandCenter`・
  `MPNowPlayingInfoCenter`）は tvOS でも利用可能なため、`MusicPlayerService` の
  `import UIKit` や `UIApplication.shared.open` はそのまま tvOS でもコンパイルが通る
  （実際に問題になったのは WebKit 依存の YouTube バックエンドのみ）。
- `RemoteAPIClient.swift` は `DownloadAudioQuality.swift`（`DownloadAACBitrate`）に依存しており、
  当初の共有ファイルリストに入れ忘れてビルドが失敗した。共有ターゲットメンバーシップは
  「その場で使っている型」だけでなく推移的な依存も洗い出す必要がある。

## 再生スパイクの結果（計画の名指しリスク: AVAudioEngine/tvOS 差分）

`UX-Music-TVTests/MusicPlayerServicePlaybackSpikeTests.swift` で
`MusicPlayerService()` を tvOS 上でインスタンス化し、バンドル同梱の 0.5 秒サイン波
WAV フィクスチャ（`UX-Music-TVTests/Fixtures/spike-sine.wav`、440Hz・44.1kHz・モノラル、
Python の `wave` モジュールで生成）を `Song(path:)` 経由で読み込ませ、`play(_:newQueue:)` →
`AVAudioFile` デコード → `AVAudioEngine`/`AVAudioUnitEQ` グラフ起動 → `playerNode.play()`
→ `togglePlayPause()`（pause/engine.stop 経路）まで一気通貫させた。

- `platform=tvOS Simulator,name=Apple TV` で **成功**（`** TEST SUCCEEDED **`、
  `testEnginePipelineInitialisesAndPlaysBundledFixtureOnTVOS` PASS、0.623 秒）。
- `AVAudioSession` のカテゴリ/モード設定（`preparePlaybackSessionIfNeeded`）を含め、
  tvOS 向けの追加分岐は一切不要だった。EQ/LUFS パイプライン自体は iOS と共通コードのまま
  tvOS シミュレータで問題なく初期化・再生できることを確認できたので、計画の名指しリスクは
  Phase 1-1 の時点で解消したとみなす。

## ビルド/テスト結果

- `xcodebuild -project UX-Music-Mobile.xcodeproj -scheme UX-Music-TV -destination
  'platform=tvOS Simulator,name=Apple TV' test` → **TEST SUCCEEDED**。
- `xcodebuild -project UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination
  'platform=iOS Simulator,name=iPhone 17' build` → **BUILD SUCCEEDED**（既存 iOS ターゲットに
  リグレッションなし）。
