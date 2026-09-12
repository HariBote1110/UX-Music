# Watch 初回操作のメインスレッド blocking 静的監査

## 目的/仮説

Apple Watch 実機で「最初に何をしても UI 全体が止まる」と報告され、Songs 画面の初回 layout がタップから約22秒（`[WatchSongListPerf] Song list first layout appeared at t+22306ms`）だった。既存ノートで特定・修正済みの `Canvas` 初回 Metal 初期化は再調査せず、起動・初回 navigation・再生操作の main-thread blocking 候補を静的監査する。

以下はすべて **静的監査のみ・実機未検証** の仮説である。各項目には変更内容と、実機ログで確認する DEBUG breadcrumb を記録する。

1. **仮説1: `WatchLocalLibrary.init` の JSON 読み込み、音声ファイル存在確認、派生 order/grouping が App.init の main actor を止める（静的監査のみ・実機未検証）。**
   `Data(contentsOf:)`、JSON decode、`fileExists`、`WatchFlatSongOrder`/album grouping を detached task 内へ移し、結果だけを main actor で publish した。`reload()` も非同期 trigger とし、`reloadAndWait()` は再開処理から await できるようにした。ロード中の受信 add/remove は snapshot とマージする。
   ロード中は add/remove による index 書き込みを抑止し、マージ後の最新 snapshot だけを一度保存することで、初期 read と WCSession transfer の書き込み競合による既存 library の上書きを防ぐ。
   確認 breadcrumb: `library.reload.begin` → `library.readDisk.begin/end` → `library.reload.publish.begin/end`。

2. **仮説2: `WatchPlaylistLibrary.init` の JSON 読み込みが起動を止める（静的監査のみ・実機未検証）。**
   init を空状態にし、JSON decode を detached task、publish を main actor に移した。アプリ起動時はライブラリの後に `reloadAndWait()` する。
   確認 breadcrumb: `playlistLibrary.reload.detached.begin` → `playlistLibrary.readDisk.begin/end` → `playlistLibrary.reload.publish.end`。

3. **仮説3: AVAudioSession の初回 touch、route 検出、route 表示、通知 handler の route 読み取りが main-thread IPC になる（静的監査のみ・実機未検証）。**
   `AVAudioSession.sharedInstance()`、`currentRoute`、`availableInputs` の読み取りを `audioSessionQueue` に集約し、Bluetooth 判定と route snapshot のみを main actor へ戻す。通知登録は `object: nil` とし、`activate(options:)` は既存仕様どおり long-form のみ、speaker path は `setActive(true)` のままにした。`activationInFlight` の coalescing は保持した。
   確認 breadcrumb: `audio.activate.begin/end`、`audio.activate.bluetoothRead.begin/end`、`audio.activate.plan.begin/end`、`audio.routeSnapshot.begin/end`、`audio.applyRouteOutcome.begin/end`、`audio.interruption.routeRead.begin/end`、`audio.routeChange.routeRead.begin/end`。

4. **仮説4: `WatchVolumeObserver.init` の outputVolume 読み取りと KVO 設定が Now Playing の初回構築を止める（静的監査のみ・実機未検証）。**
   初期 level の読み取りと KVO observation の作成を utility queue へ移し、level と observation token だけを main actor へ publish する。
   確認 breadcrumb: `volumeObserver.setup.begin/end`。

5. **仮説5: `WatchNowPlayingView.refreshCachedArtworkIfNeeded` の disk read と画像 decode が main を止める（静的監査のみ・実機未検証）。**
   `fileExists` と ImageIO thumbnail decode を detached task へ移し、`CGImage` を main actor 側で `UIImage` にラップする。画面サイズを大きく超えない 400px の downsample を使い、song ID を検査して古い decode 結果を破棄する。
   確認 breadcrumb: `nowPlaying.artwork.begin` → `nowPlaying.artwork.detached.begin/end` → `nowPlaying.artwork.end`。

6. **仮説6: `WatchArtworkThumbnail` が detached 前に main actor 上で artwork `fileExists` を実行する（静的監査のみ・実機未検証）。**
   artwork URL 解決と `fileExists` を decode と同じ detached closure 内へ移した。既存の ImageIO thumbnail と memory cache は維持した。
   確認 breadcrumb: `songThumbnail.fileCheckDecode.begin/end`。

7. **仮説7: 再開状態、library/playlist index の JSON encode と atomic write、output preference の UserDefaults write が各操作の main を止める（静的監査のみ・実機未検証）。**
   main actor では値の snapshot だけを作り、直列 background writer へ渡す。writer は pending の最新値を保持して encode/write を coalesce する。UserDefaults の preference read/write も audio-session queue へ移した。
   確認 breadcrumb: `diskWrite.encode.begin/end`、`audioOutputPreference.read.begin/end`、`audioOutputPreference.write.begin/end`。

8. **仮説8: play/pause/next/初回 navigation に別の同期 I/O または IPC が残る（静的監査のみ・実機未検証）。**
   `AVPlayer` の file existence check、`AVURLAsset`/`AVPlayerItem`/`AVPlayer` の準備を detached task へ移し、observer 登録と `@Published` mutation は main actor に残した。`WCSession.isSupported`/default session の delegate 設定と activation も utility queue へ移した。`MPRemoteCommandCenter` 初回 touch は App.init の同期呼び出しを避け、最初の run-loop yield 後に遅延登録した。`MPNowPlayingInfoCenter` への最終 publish は system surface との main-actor 境界として残したが、artwork payload の生成はなく、純粋な小さい dictionary 構築だけである。`WCSession` の `didReceive file` での transient inbox の copy と playlist decode は、file URL が delegate callback 中だけ有効という API 契約のため、その callback の（main ではない）queue 上に残した。
   確認 breadcrumb: `player.prepareAsset.begin/end`、`connectivity.activate.begin/end`、`remoteCommands.configure.begin/end`。

## 環境

- リポジトリ: `/Users/yuki/GitHub/UX-Music`
- 対象: `UX-Music-Mobile/UX-Music-Watch`
- deployment target: watchOS 10.0
- 参照 SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.5.sdk`
- 既存実機症状: Songs 初回 layout が `t+22306ms`
- 既存調査: `lazy-navigation-fix-and-instrumentation.md` の Canvas/Metal 原因特定と Shape 置換を前提とした

## 手順

1. 既存の `watch_songlist_perf_research/notes/*.md` と `progress/watch-speaker-output.md` を先に確認した。
2. Watch target 全 Swift ファイルと `WatchConnectivityReceiver`、共有の `WatchTransferMeta`/playback model を静的検索し、JSON、FileManager、AVAudioSession、AVPlayer、MediaPlayer、WCSession の呼び出し位置を列挙した。
3. `WatchTransferMeta`/`WatchPlaylistMeta` が `Sendable` であることを確認した。派生 snapshot と復元状態を安全に渡せるよう、`WatchPlaybackLogic.swift` の値型宣言に `Sendable` を追加した。
4. WatchOS 26.5 SDK header で AVAudioSession の route/volume/activation API と AVFoundation の asset/item API の availability を確認した。
5. 全 Watch Swift ファイルに `swiftc -frontend -parse` を実行した。`xcodebuild` は制約により実行していない。

## 結果

| 候補 | 静的監査 verdict | main-thread blocking 対応 |
|---|---|---|
| 1. Local library init/reload | moved | I/O、存在確認、派生計算を detached、publish は main actor |
| 2. Playlist library init/reload | moved | JSON read/decode を detached、publish は main actor |
| 3. AVAudioSession IPC reads | moved | queue で route/Bluetooth snapshot、main で plan/publish |
| 4. Volume observer | moved | queue で initial read/KVO setup、main で state publish |
| 5. Now Playing artwork | moved | queue で存在確認/ImageIO decode、song ID で stale guard |
| 6. Row artwork `fileExists` | moved | detached closure 内へ移動 |
| 7. Resume/index/UserDefaults writes | moved | snapshot + serial latest-value coalescing writer |
| 8. その他 | 部分的に moved / 一部 left as is | AVPlayer 準備、WCSession activation、remote command 初回登録は移動。MPNowPlayingInfoCenter publish は残置 |

今回の静的検査では、Canvas は対象に含めなかった。これは既存ノートで main-thread の Metal device init/dlopen 原因として特定済みで、Shape 置換済みだからである。

## 結論

起動時に同期していた library/playlist/resume の file read/decode、AVAudioSession の route/volume query、artwork decode、AVPlayer 準備、index/resume write を main actor の外へ移した。`@Published` mutation、SwiftUI の view state、AVPlayer observer の登録は main actor に残し、UI state の thread safety と既存の音声 route semantics を保った。

ただし、これは実機での stall duration、KVO の watchOS 実装挙動、detached AVFoundation object preparation の安全性を確認した結果ではない。DEBUG monitor の `[MainThreadStall]` と各 breadcrumb が、次回の実機 run で残存 stall の位置を特定するための証拠になる。

## 次の一手

- Xcode で Watch target を Debug build し、実機で `[MainThreadStall]` と breadcrumb を採取する。
- 起動直後、Songs navigation、Now Playing 表示、play/pause、next、speaker/Bluetooth 切替を各2〜3回試す。
- `[MainThreadStall]` の開始行と `ended total=...` を、直前の `breadcrumb`/`sinceBreadcrumb` と対応づける。
- `player.prepareAsset` 後に再生開始が遅い、または `AVPlayer` の thread-safety に関する runtime issue が出た場合は、asset/item だけを detached にし、AVPlayer の生成を main actor に戻す比較を行う。
- SDK と toolchain の build 番号を Xcode と一致させた環境で Watch target を build/test し、actor/Sendable diagnostics を確認する。
