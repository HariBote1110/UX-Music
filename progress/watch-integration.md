# Apple Watch 再生機能の UX-Music-Mobile 移植（フェーズ2）

## Decision

- 休眠プロジェクト `UX-Music-Wear/`（WatchApp の AudioPlayer / LocalLibrary /
  WatchConnectivityHandler、iPhoneApp の WatchBridge）を参考実装として読み、
  ロジックを `UX-Music-Mobile.xcodeproj` の `UX-Music-Watch` ターゲット
  （フェーズ1で追加済み、bundle `com.uxlabs.uxMusicMobile.watchkitapp`）に
  移植した。`UX-Music-Wear/` 自体は削除せず読むだけに留めた（削除は次フェーズ）。
- 転送メタデータ `WatchTransferMeta` とライブラリのマージ/削除ロジック
  `WatchLibraryIndex` を `UX-Music-Mobile/Core/WatchTransfer.swift` に置き、
  **iOS ターゲットと watchOS ターゲット両方のメンバーシップ**にした
  （pbxproj で `PBXBuildFile` を2エントリ、`PBXFileReference` を1エントリ作り、
  両ターゲットの Sources ビルドフェーズにそれぞれ登録）。これにより
  WCSession の `transferFile(_:metadata:)` 用メタデータの構築・解析と、
  Watch 側の永続化インデックスの追加/削除/存在チェックが純関数として
  iOS テストターゲット（`UX-Music-MobileTests/WatchTransferTests.swift`）
  から TDD で検証できる。
- iOS 側送信は `WatchTransferBridge`（`Services/WatchTransferBridge.swift`）。
  `DownloadManager.isDownloaded` / `localPathString` を使い、**ローカルに
  ダウンロード済みの曲のみ転送可能**にした。ペアリング状態・転送キューを
  `@Published` で公開し、`LocalLibraryScreen` の曲コンテキストメニュー
  （「Apple Watch に転送」）と `SettingsScreen` の APPLE WATCH セクション
  （ペアリング状態・Watch アプリ有無・転送状況一覧）から利用する。
- watchOS 側受信は `WatchConnectivityReceiver`（`didReceive file:` →
  Application Support 配下の `Audio/` へ移動 → `WatchLocalLibrary.addSong`）。
  `WatchLocalLibrary` は JSON インデックス（`library.json`）を
  Application Support に永続化し、起動時に `WatchLibraryIndex
  .retainingExistingFiles` でファイルが実在する行のみ残す（旧 Wear 実装の
  `LocalLibrary.loadFromDisk` と同じ考え方）。
- 再生は `WatchAudioPlayerService`（AVPlayer + `.playback` AVAudioSession +
  `WKExtendedRuntimeSession`）。旧 Wear の `AudioPlayer.swift` をほぼそのまま
  移植し、`Song` の代わりに `WatchTransferMeta` を扱うようにした。
  バックグラウンド再生ポリシーとして watch ターゲットの Debug/Release 両方に
  `INFOPLIST_KEY_WKBackgroundModes = audio` を追加。
- UI は `WatchSongListView`（一覧・スワイプ削除・タップで
  `WatchNowPlayingView` へ push）、`WatchNowPlayingView`（再生/停止・前後・
  Digital Crown での音量調整）、`WatchRootView`（受信中オーバーレイ）。
  `UXMusicWatchApp` で `WatchLocalLibrary` → `WatchAudioPlayerService` /
  `WatchConnectivityReceiver` の順に注入して依存を成立させた。

## Alternatives considered

- `WatchTransferMeta` を `Song`（iOS 完全版モデル）と共用する案は却下。
  Watch は `path` や `artworkId` など不要なフィールドを扱う必要がなく、
  ペイロードを小さく保ちたいため、旧 Wear と同様に軽量な専用モデルを別途
  定義した。
- Watch 側ライブラリの永続化を `UserDefaults`（旧 Wear 実装）のままにする案は
  据え置き、Application Support 直下の JSON ファイルに変更した。音声ファイル
  自体も同じ Application Support 配下の `Audio/` に統一し、Documents
  ディレクトリ（iCloud バックアップ対象になりうる）を避けた。

## Constraints / Gotchas

- pbxproj は手書き編集のため、`PBXBuildFile` の `fileRef` は共有ファイルでも
  ターゲットごとに別エントリが要る（同じ `fileRef` を複数の
  `PBXBuildFile` オブジェクトから参照する形）。`WatchTransfer.swift` は
  fileRef 1つ・buildFile 2つ（iOS 用・watchOS 用）とした。
- `xcodebuild test` はテストのたびに `iPhone Air` シミュレータの複製
  （"Clone 1 of iPhone Air"）を使う。呼び出し前に起動していた
  `E7DC188E-9644-463C-8DE6-BABAAC358C5E` 実機シミュレータ自体は
  テスト後にシャットダウンされるため、`xcrun simctl boot` で明示的に
  Booted 状態へ復元する必要がある。
- WatchConnectivity のテストは Watch 側の `WCSessionDelegate` 実装・
  実機/シミュレータ間のペアリングに依存するため対象外とし（要件どおり）、
  `WatchTransferMeta` の変換ロジックと `WatchLibraryIndex` の純関数のみを
  TDD 対象にした。

## 検証結果

- `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS Simulator' build` → BUILD SUCCEEDED
- `xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air' build` → BUILD SUCCEEDED
- `xcodebuild test -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air'` → TEST SUCCEEDED（新規 `WatchTransferTests` 15件含め全件成功）

## フェーズ3: 転送導線の全画面展開とバックグラウンド受信の不具合修正

### Decision

- **転送導線の一元化**: 「Apple Watch に転送」の判定・実行ロジックを
  `Core/WatchTransferMenuPolicy.swift`（`canShowMenu` / `songsEligibleForBulkTransfer`、
  純関数・テスト済み）と `Views/WatchTransferMenuItems.swift`
  （`WatchTransferSongMenuItem` / `WatchTransferBulkMenuItem`、SwiftUI ラッパー）に
  切り出した。以前は `LocalLibraryScreen` の曲行にしかボタンがなかったが、
  この共通コンポーネントを `.contextMenu` に差し込むだけで済むようにし、
  以下の全画面へ展開した:
  - `LocalLibraryScreen`（曲行・プレイリスト行の一括転送）
  - `AlbumDetailView`（曲行・アルバムヘッダーの一括転送）
  - `PlaylistDetailView`（曲行・ツールバーの「...」メニューから一括転送）
  - `RemotePlaylistDetailView`（曲行・プレイリストヘッダーの一括転送）
  - `RemoteLibraryScreen`（曲行・アルバム/プレイリストのグリッドセルの一括転送）
  - `NowPlayingView`（キューパネル・お気に入りパネルの各行）
  - Watch 未ペア・WatchConnectivity 非対応時はメニュー項目自体を描画しない
    （`WatchTransferMenuPolicy.canShowMenu`）。未ダウンロード曲は既存方針どおり
    ボタンを disabled にする（非表示ではなく無効化）。
- **受信後に一覧が更新されない不具合の根本原因**: `WatchConnectivityReceiver
  .session(_:didReceive:)` が `nonisolated` の同期コールバックであるにも
  関わらず、旧実装はファイルコピーそのものを `Task { @MainActor in ... }`
  の中で行っていた。`WCSessionFile.fileURL` はデリゲート呼び出しが返るまでしか
  有効性を保証されないため、メインアクターへのホップを待つ間に
  WatchConnectivity がトランジェントな受信ファイルを削除してしまい、
  `copyItem` が失敗 → `library.addSong` が一度も呼ばれず、曲が永遠にリストへ
  反映されなかった。
- **修正**: ファイルの実体コピーを `nonisolated` コンテキストのまま同期的に
  実行するよう変更。`WatchLocalLibrary`（`@MainActor` クラス）が持っていた
  ディレクトリ/パス計算を、アクター分離のない `enum WatchAudioStorage`
  （`Core`/`WatchLocalLibrary.swift` 内、iOS・watchOS 両ターゲットではなく
  watchOS のみ）に切り出し、`didReceive file:` から直接呼べるようにした。
  コピーの成否は `WatchFileReceiveResult`（`Core/WatchTransfer.swift`、iOS/watchOS
  共有）で表現し、`WatchFileReceiveHandling.shouldAddToLibrary` という純関数で
  「成功時のみインデックスに追加する」判定をテスト可能にした
  （`WatchTransferTests.testShouldAddToLibraryIsTrueOnSuccess` /
  `testShouldAddToLibraryIsFalseOnFailure`）。`@Published songs` の更新自体は
  引き続き `@MainActor` の `Task` 内で行う。
- **フォアグラウンド復帰時の再読込**: `WatchLocalLibrary` に `reload()` を追加し、
  `WatchRootView` の `.onChange(of: scenePhase)` で `.active` になったタイミングで
  呼び出す。通常は `@Published songs` によるライブ更新で足りるが、サスペンド中に
  完了した転送を取りこぼさないための保険。

### Alternatives considered

- `WatchLocalLibrary` 自体を `nonisolated` にする案は却下。`@Published` な
  `songs` を安全に公開するには `@MainActor` のままにしておきたく、
  パス計算だけを外に出す方が影響範囲が小さい。
- WatchConnectivity の実際の受信・アクターホップの競合を統合テストする案は
  見送り（WatchKit 用のユニットテストターゲットがそもそも存在せず、
  実機/シミュレータのペアリングに依存するため）。代わりに「コピー成功/失敗
  という結果に対して何が起きるべきか」を `WatchFileReceiveHandling` として
  切り出し、その決定ロジックだけを iOS テストターゲットから検証する形にした。

### Constraints / Gotchas

- `WCSessionFile.fileURL` の有効期間はデリゲートコールバックの実行中のみ。
  `nonisolated` なコールバックから `Task { @MainActor in ... }` で後回しに
  した処理の中でこの URL を参照すると、システムが先にファイルを削除している
  可能性があるため踏んではいけない罠。ファイル操作は必ずコールバックの
  同期区間で完結させること。
- 新規ファイル3点（`WatchTransferMenuPolicy.swift` / `WatchTransferMenuItems.swift`
  / `WatchTransferMenuPolicyTests.swift`）は pbxproj に手動登録。
  `WatchTransferMenuPolicy.swift`・`WatchTransferMenuItems.swift` は
  iOS ターゲットのみのメンバーシップ（`AppModel`/`Song` は iOS 専用のため）。

## シミュレータ E2E 検証の記録（フェーズ3後・2026-08-03）

- iPhone Air ⇔ Apple Watch Series 11 (42mm) のペアシミュレータで検証。
- **送信側は成功を確認**: 曲行の長押し →「Apple Watch に転送」→ `WCSession transferFile` が
  `kNoErr` 完了（wcd 受理、FLAC 30MB）。転送メニューは Songs/アルバム詳細で表示を確認。
- **Watch アプリ側への配達は未達**: Watch 側 wcd が `IDS ... fatal error, will not be
  attempting to reconnect` を出しており、シミュレータの WatchConnectivity 転送トランス
  ポート（IDS）がこの環境で機能しない。90秒待機してもファイル未着。
- 重要な前提: `WCErrorCodeWatchAppNotInstalled` を避けるには、Watch アプリを
  **iPhone アプリバンドル内蔵の `Watch/UX-Music-Watch.app` から** `simctl install`
  すること（別 DerivedData の単体ビルドを入れると wcd が companion app と認識しない）。
- シミュレータのタッチ入力（MCP 注入・Simulator.app の実クリックとも）が
  デバイス再起動を跨ぐと死ぬ事象が多発（backboardd 起因、CoreSimulatorService 再起動で回復）。
  タップ検証時は注入先 udid の明示が必須（Watch ブート後はパネルの対象が Watch に切り替わる）。
- **結論: 受信→リアルタイム更新（WCSessionFile 生存期間修正）の end-to-end 確認は実機でのみ可能。**
