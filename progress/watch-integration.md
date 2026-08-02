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
