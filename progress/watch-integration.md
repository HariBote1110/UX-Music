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

## フェーズ4: 実機での `WCSession has not been activated` 修正（activation gating）

### Decision

- **根本原因**: `WCSession.activate()` は非同期に完了する
  （`activationDidCompleteWith` が実際のシグナル）。旧実装は
  - iOS 側 `WatchTransferBridge.activate()` を `UXMusicMobileApp` の
    `.onAppear`（View 初回描画後）から呼んでおり、かつ `activate()` 内で
    `session.activate()` 呼び出し直後に同期的に `session.isPaired` /
    `isWatchAppInstalled` を読んでいた（`activationDidCompleteWith` を待たず）。
  - watchOS 側 `WatchConnectivityReceiver.activate()` も `WatchRootView` の
    `.onAppear` から呼ばれていた。
  実機のシミュレータより厳密な `wcd` はこの「activate 完了前のセッション参照/
  操作」を `WCSession has not been activated` として拒否し、
  `transferFile` 自体も届かず `Application context data is nil` が併発した
  （シミュレータの `wcd` は緩く、フェーズ3の検証はここが原因で「送信成功」に
  見えていた）。
- **修正方針**: 「activate 完了を待たずに転送要求が来たら即実行せずキューに
  積み、`activationDidCompleteWith` 完了後に flush する」設計に変更。
  - `Services/WatchTransferBridge.swift`:
    - `WatchSessionActivationStatus`（`.notActivated` / `.activating` /
      `.activated` / `.failed(String)`）と、`WCSession` に依存しない純粋
      ゲーティング関数 `WatchTransferActivationGating`
      （`shouldSendImmediately(status:)` / `statusAfterActivationCompletion`）
      を追加。ここだけを `UX-Music-MobileTests/WatchTransferTests.swift` で
      TDD（先にテスト→コンパイルエラーで Red 確認→実装で Green）。
    - `send(_:)` は `shouldSendImmediately` が false なら `pendingSongs` に
      積んで即 return（キュー表示上は `.waiting`）。実際の
      `WCSession.transferFile` 呼び出しは `performTransfer(_:)` に分離。
    - `activationDidCompleteWith` → `handleActivationCompletion` で
      `activationStatus` を更新し、`.activated` なら `pendingSongs` を
      `performTransfer` で flush、`.failed` なら理由付きで `.failed` へ
      遷移させる。`refreshPairingState()`（`isPaired`/`isWatchAppInstalled`
      の読み取り）もこの完了後にのみ行うよう移動（activate 前の早期参照を排除）。
    - `activate()` 自体は冪等化（`activationStatus == .notActivated` の
      ときのみ実行）。
    - `AppModel.init()` の最後で `watchTransferBridge.activate()` を呼ぶよう
      変更し、`UXMusicMobileApp` 側の `.onAppear` からは削除（App 起動＝
      `AppModel` 構築時点で必ず activate される）。
    - `activationStatus` を `@Published` にして `SettingsScreen` の
      APPLE WATCH セクション先頭に「接続状態」行として表示
      （未接続・接続中…・接続済み・接続失敗: <理由>）。
  - `UX-Music-Watch/UXMusicWatchApp.swift`: `connectivity.activate()` を
    `WatchRootView` の `.onAppear` から `init()` 直後へ移動。
    バックグラウンドで wcd がアプリを起こして `didReceive` を呼ぶケースでも、
    delegate 登録が View 描画を待たず完了しているようにするため。
    `WatchConnectivityReceiver` 自体は元から `UXMusicWatchApp` の
    `@StateObject`（App 構造体のプロパティ＝プロセス生存期間で保持）なので、
    delegate の強参照は既に確保されている（`WCSession.delegate` はセッション
    側が保持しないため、呼び出し側が生存させ続ける必要がある点に注意）。

### Alternatives considered

- `WCSession.activate()` の完了を `await` できる API は存在しない
  （delegate コールバックのみ）ため、`AsyncStream` 等でラップして
  `send` を `async` にする案も検討したが、既存の `@discardableResult
  func send(_ song: Song) -> Bool` の呼び出し側（`WatchTransferMenuItems`
  など View 側のボタンアクション）を全て非同期化する必要があり影響範囲が
  大きい。「同期 API のまま内部でキューイングする」現行案の方が変更を
  `WatchTransferBridge` 内に閉じ込められるため採用。
- `activationStatus` を watchOS 側にも作る案は見送り。watchOS 側の
  `WatchConnectivityReceiver` は「送る」のではなく「受ける」側で、
  activate 前に呼ばれうる自発的な API 呼び出し（`send` 相当）が存在しない
  ため、activate 完了を待つ必要がある操作がそもそもない。

### Constraints / Gotchas

- `refreshPairingState()`（`session.isPaired` 等の読み取り）を activate 完了前に
  呼ぶこと自体が `WCSession has not been activated` の一因だった。activate 系の
  プロパティ・メソッドは「`activationDidCompleteWith` が一度でも呼ばれた後」
  でしか安全に触れないと考えること。
- 実機でしか再現しない類のバグ（シミュレータの `wcd` は寛容）。この修正の
  実機確認はユーザー側で実施する（下記参照）。

### 検証結果

- `xcodebuild test -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air'` → TEST SUCCEEDED（`WatchTransferActivationGating` 向け新規6件を含め全件成功）
- `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS Simulator' build` → BUILD SUCCEEDED
- 実機確認はユーザーが実施予定（本フェーズではシミュレータ検証のみ）。

## フェーズ5: 再生 UI 本格化（ページング化・Digital Crown シーク・システム連携）

実機での再生自体は動くようになったが、ユーザーから3点の不満が出た:
「戻るボタンでLibraryに戻ると再生画面に戻れない」「シークバーが操作不能」
「全体的に機能不足」。これに対応した。

### Decision

- **ナビゲーション構造**: `WatchSongListView` の行から `WatchNowPlayingView` へ
  `NavigationLink` で push する構造（フェーズ2〜4）をやめ、`WatchRootView` を
  `TabView(selection:) { ... }.tabViewStyle(.page)` による **Library ⇄ Now
  Playing の水平ページング**に変更した（`WatchPage` enum で選択状態を管理）。
  watchOS の `.page` スタイルはデフォルトで水平ページング（iOS の縦ドットとは
  挙動が異なる）ため、これが「標準アプリ（Music/Podcasts）のページめくり」と
  同じ体験になる。曲行タップ時は `player.play(...)` に加えて
  `selectedPage = .nowPlaying` を設定して自動遷移させ、Library ページへ戻っても
  Now Playing ページ自体は `TabView` の中に常に存在するため、指1本のスワイプで
  いつでも再生画面へ戻れる（= 元の不満1を解消）。
- **Digital Crown シーク**: watchOS でスライダーのドラッグ操作は当たり判定が
  細く実用的でないため、`WatchNowPlayingView` に `.digitalCrownRotation` を
  `$crownPosition`（0秒〜曲長の秒数レンジ）にバインドしてシーク入力とした。
  回転中は `isSeeking` フラグを立てて `crownPosition` をそのまま表示（進捗バー・
  経過/残り時間ラベル）し、`AVPlayer.seek` は叩かない。回転が 0.4 秒止まったら
  （`Task.sleep` によるデバウンス、回転のたびに前のタスクを `cancel`）
  `player.seek(to:)` を確定コミットする。これで「回転のたびに毎回シークして
  引っかかる」を避けつつ、離した瞬間の反映も速い。曲が切り替わったら
  `crownPosition` を新しい `player.position`（＝0）に同期する。
- **クランプ処理の純関数化**: 「シーク位置は 0〜曲長にクランプする」
  ルールを `Core/WatchPlaybackLogic.swift` の `WatchSeekLogic.clampedPosition`
  として切り出し、`WatchAudioPlayerService.seek(to:)` から呼ぶ形にした。
  合わせて `next()`/`previous()` の曲送り順序（ラップアラウンド）と
  「再生位置が3秒を超えていたら先頭曲へ戻さず現在曲を先頭に戻す」判定も
  `WatchQueueNavigation`（`nextIndex`/`previousIndex`/`shouldRestartOnPrevious`）
  として同じファイルに切り出した。いずれも `WatchTransfer.swift` と同じ手法で
  iOS/watchOS 両ターゲットのメンバーシップにし、
  `UX-Music-MobileTests/WatchPlaybackLogicTests.swift` から TDD で検証。
- **システム統合**: `WatchAudioPlayerService` に
  `MPNowPlayingInfoCenter.default().nowPlayingInfo` の更新（曲変更時・
  0.5秒ごとの再生位置更新時・play/pause 切替時・seek 時）と、
  `MPRemoteCommandCenter.shared()` の `playCommand` /
  `pauseCommand` / `togglePlayPauseCommand` / `nextTrackCommand` /
  `previousTrackCommand` / `changePlaybackPositionCommand` のハンドラ登録を
  追加した。Now Playing 情報の dict 構築自体も
  `WatchNowPlayingInfoBuilder.buildInfo(for:isPlaying:position:)` という純関数
  にして（`MPMediaItemPropertyTitle` 等のキーを使うだけで
  `MPNowPlayingInfoCenter` 自体には触れない）、
  `WatchPlaybackLogicTests` から検証できるようにした。これにより watchOS
  標準の Now Playing グランス・AirPods の再生/一時停止/スキップ操作・
  ペアの iPhone 側コントロールが実再生と連動する。
- **音量の扱い（判断）**: Digital Crown をシーク専用に割り当てたため、
  フェーズ2で実装していた「Crown で音量調整」機能は削除した。
  `WKInterfaceVolumeControl` 相当を別途 UI に追加する案もあったが、
  Crown と競合しない独立した音量 UI を狭い watchOS 画面に増設するより、
  **音量調整は watchOS 標準のサイドボタン操作／Control Center／ペアの
  iPhone に委ねる**（システム任せ）方針とした。これは Apple Music アプリ
  自身も Now Playing 画面では音量スライダーを持たず Crown をシークに
  使う挙動と揃える判断。
- **Library の再生中インジケータ**: `WatchSongListView` の各行に、
  `player.currentSong?.id == meta.id` のときスピーカーアイコン
  （再生中は `speaker.wave.2.fill`、一時停止中は `speaker.fill`）を
  表示するようにした。行タップの実装は `NavigationLink` から
  `Button { player.play(...); selectedPage = .nowPlaying }` に変更（削除の
  swipeActions はそのまま維持）。

### Alternatives considered

- ナビゲーションを「2タブ構造（`TabView` に `.tabItem` でタブバー表示）」に
  する案も検討したが、watchOS はタブバーではなく横スワイプでページを
  めくるのが標準的な体験（Music/Podcasts/Now Playing グランス等）のため、
  `.tabViewStyle(.page)` によるページングを採用した。`.verticalPage`
  （縦スクロールでページをめくるスタイル）は要件で明示的に除外されていた
  こともあり不採用。
- シーク UI として `Slider` + `.focusable().digitalCrownRotation` を
  スライダーの見た目のまま Crown で動かす案も検討したが、watchOS では
  スライダーの視覚的なつまみが小さく操作感の向上に寄与しないため、
  進捗バー（`ProgressView`、非操作）+ Crown 直結という Podcasts アプリに
  近い構成にした。
- Crown シークを「回転量の相対的なデルタ」で実装する案（現在位置に
  加算していく）も検討したが、`.digitalCrownRotation` はバインドした
  `Double` を直接ドライブする絶対値 API のため、素直に「0〜曲長」の
  レンジへ直接バインドする方が実装・テストともにシンプルだった。

### Constraints / Gotchas

- `.digitalCrownRotation` の `through:` に曲の長さ（`Double`）をそのまま
  渡すため、`WatchTransferMeta.duration` が 0 の曲（メタデータ欠損）では
  レンジが 0 になり Crown が効かない。`duration` の下限を `max(_, 1)` で
  ガードしている（`WatchNowPlayingView.duration`）。
- `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` はシングルトンで
  グローバル状態を持つため、`WatchAudioPlayerService` の
  ユニットテストは意図的に作らなかった（実機/シミュレータの `MediaPlayer`
  フレームワーク状態に依存し、TDD 対象としての価値が低い）。代わりに
  「渡す dict の中身が正しいか」だけを `WatchNowPlayingInfoBuilder`
  という純関数として切り出しテストで担保する方針にした
  （`Core/WatchPlaybackLogic.swift` 参照）。
- 転送メタデータ `WatchTransferMeta` にアートワークのフィールドが
  存在しない（フェーズ2の決定どおり軽量ペイロード優先）ため、
  Now Playing 画面のアートワーク表示は本フェーズでは見送った
  （音符アイコンのプレースホルダーのまま）。アートワークを追加するには
  `WatchTransferBridge` の転送ペイロードに画像データを追加する必要があり、
  ペイロードサイズ・転送時間とのトレードオフになるため別途判断が必要。

### 検証結果

- `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS Simulator' build` → BUILD SUCCEEDED
- `xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air' build` → BUILD SUCCEEDED
- `xcodebuild test -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air'` → TEST SUCCEEDED（`WatchPlaybackLogicTests` 新規16件を含め全件成功）

## フェーズ6: 再生スタッター修正・アートワーク対応・Walkman世代ギャップ解消

### 決定1: 再生スタッターの原因と対策

**原因**: `WatchAudioPlayerService` は `currentSong`/`isPlaying`/`position` を
すべて同一の `ObservableObject` の `@Published` として持っていた。
`addPeriodicTimeObserver`（0.5秒毎）が `position` を更新するたび、その
`ObservableObject` を `@EnvironmentObject` として参照している **すべての
View**（Library ページを含む）が SwiftUI の差分検出により再描画されていた
——実際に `position` を読んでいない `WatchSongListView` も、同じ
ObservableObject を購読しているだけで巻き添えになる。加えて
`updateNowPlayingInfo()`（`MPNowPlayingInfoCenter.default().nowPlayingInfo`
辞書の再構築）もこのティック毎に呼ばれており、二重に無駄なコストが
乗っていた。Library⇄Now Playing のページ切替時に体感できる音声スタッター
（描画スレッドの詰まりが AVFoundation の再生キューにも影響）はここに起因
すると判断した。

**対策**: `position` だけを別の軽量 `ObservableObject`
（`WatchPlaybackProgress`、`WatchAudioPlayerService.swift` に同居）に切り出し、
`WatchNowPlayingView` だけがこれを `@EnvironmentObject` として購読する構造に
変更。Library ページは `WatchPlaybackProgress` を一切知らないため、0.5秒
ティックで再描画されなくなった。あわせて `updateNowPlayingInfo()` の呼び出し
をティック毎から「状態が変化する操作（load/play/pause/seek/next/previous/
曲終端）」のみに限定した。`MPNowPlayingInfoPropertyElapsedPlaybackTime` +
`MPNowPlayingInfoPropertyPlaybackRate` の組はシステム側で経過時間を補間する
設計のため、毎ティックの辞書再構築は本来不要だった。

### 決定2: アートワーク転送方式

`WatchTransferMeta` の `wcMetadata`（`transferFile` の metadata 引数）には
サイズ上限があり画像バイト列を直接載せるのは不適切なため、フェーズ2の
決定どおり **音声と同じ仕組みで別ファイルとして転送** する方式を採用した。
- iOS 側: `DownloadManager.localArtworkFileURLIfPresent(artworkId:)` で
  ローカルにダウンロード済みのジャケットを取得し、`UIGraphicsImageRenderer`
  で長辺 400px にダウンスケール、JPEG（圧縮率0.6, 目安 ~50KB）に再エンコード
  して一時ファイルに書き出し、`kind: "artwork"` を付けた metadata で
  2本目の `transferFile` として送信する。
- `WatchTransferMeta` に `artworkFileName`（任意）を追加したが、実際の
  保存先ファイル名は `id` から決定的に導出する
  `WatchTransferMeta.storedArtworkFileName(forId:)` を使う。
  `artworkFileName` フィールドはメタデータ上「アートワークが存在する」
  ことを示すマーカーとして持たせているが、受信側は `id` だけで解決できる
  ため、フィールドの有無に依存しない堅牢な設計にした。
- watchOS 側: `WatchConnectivityReceiver.didReceive` で
  `WatchTransferMeta.isArtworkWcMetadata` を先にチェックし、アートワーク
  転送なら `WatchAudioStorage.artworkFileURL(forId:)` にコピーして即
  return（曲メタデータとしてのパースは行わない）。
- 既に転送済み（アートワーク無し）の曲は、iPhone 側から再転送すれば
  アートワークが付与される（フェーズ2で決めた「同じ id は追加スキップ」
  の `WatchLibraryIndex.adding` はこの再転送の音声側には影響するが、
  アートワークは曲メタデータの index とは独立したファイルなので
  再転送時は問題なく上書きされる）。

### 決定3: リピート/シャッフル/レジューム

Walkman S313 世代とのギャップのうち実装したもの:
- **リピートモード**: `WatchRepeatMode`（off/all/one）を
  `Core/WatchPlaybackLogic.swift` に追加。`.next()` で
  off→all→one→off と巡回。曲終端の挙動は `WatchQueueNavigation.autoAdvance`
  （純関数）で off の場合は最後の曲で停止するよう変更した
  （従来は暗黙に無限ループしていた）。
- **シャッフル**: `WatchShuffleLogic.applyShuffle` （純関数、乱数生成は
  呼び出し側の `Array.shuffled()` に任せてテスト容易性を確保）で、現在の
  再生曲を先頭に固定したままキューを並べ替える。オフに戻すと
  `originalQueue`（`WatchAudioPlayerService` が保持する未シャッフルの
  元順序）に復元する。
- **レジューム**: `WatchPlaybackResumeState`（Codable）に曲ID・位置・
  シャッフル後キュー/元キューの曲ID列・リピートモード・シャッフル状態を
  保存し、`WatchResumeStorage`（Application Support 配下の JSON）に永続化。
  状態が変化する操作のたびに保存するため、プロセスが不意にkillされても
  ロストは最後の1操作分に限られる。アプリ起動時
  （`UXMusicWatchApp.init`）に `restoreResumeState()` を呼び、曲・位置・
  キュー・モードを復元するが **再生は自動開始しない**（`loadWithoutAutoplay`
  を使い、`AVPlayer.play()` を呼ばない）。

キュー順序・シャッフル・リピート遷移・レジューム状態の encode/decode は
すべて `Core/WatchPlaybackLogic.swift` の純関数として実装し、
`UX-Music-MobileTests/WatchPlaybackLogicTests.swift` に Red→Green で
テストを追加した（`WatchRepeatModeTests`, `autoAdvance`, `applyShuffle`,
`WatchResumeLogic`, `WatchPlaybackResumeState` の JSON ラウンドトリップ）。

### 一般的な音楽プレイヤーとの機能ギャップ一覧（今回見送り）

ユーザー指示により実装を見送り、分析のみ記録:
- **EQ/音質効果**: iPhone 版にはグラフィカルイコライザー機能があるが、
  Watch 版には無い。watchOS の `AVAudioEngine` でのリアルタイム
  イコライジングは電池消費・実装コストが大きく、Watch という利用文脈
  （運動中など）を考えると優先度は低いと判断。
- **A-B リピート**: 特定区間のループ再生。Digital Crown シークとの
  UI 設計の相性が課題（区間の始点・終点をどう指定するか）。
- **歌詞表示**: iPhone 版は LRC 歌詞表示に対応しているが、Watch の
  画面サイズでは実用的な体験を作るのが難しく、`WatchTransferMeta` にも
  歌詞データを持たせていない。
- **フォルダ階層 / プレイリスト**: 現状 Watch 側は単一のフラットな
  曲リストのみ。iPhone 側のプレイリスト/フォルダ構造を転送・表示する
  仕組みは無い。
- **FM ラジオ**: 物理 Walkman の FM チューナー相当機能。UX Music は
  ストリーミング/ローカル再生専用アプリのためスコープ外。
- **曲情報の長押し詳細表示**: アルバム名は Now Playing に表示済みだが、
  長さ・ファイル形式などの詳細を長押しで見るモーダルは今回は
  実装しなかった（無理に追加しない、との指示どおり）。

### Constraints / Gotchas

- SwiftUI で `@EnvironmentObject` を複数 View 間で共有する場合、
  「同じオブジェクトを見ているが読んでいないプロパティの変化」でも
  そのオブジェクトを参照している View は再描画される。頻繁に変わる値
  （進捗など）は、それを実際に必要とする View だけが購読する別
  ObservableObject に切り出すのが定石。
- `player.repeatMode.systemImageName` を `Image(systemName:)` の引数に
  直接三項演算子の色と組み合わせて書くと、Swift の型チェッカーが
  タイムアウトする（`the compiler is unable to type-check this
  expression in reasonable time`）。`let` で中間変数に分けて型注釈を
  与えることで回避した。
- watchOS でも `UIImage`/`UIGraphicsImageRenderer` は利用可能（UIKit の
  サブセットが watchOS にもリンクされている）ため、iOS 側と同じ API で
  ダウンスケール処理を書けた。

### 検証結果

- `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS Simulator' build` → BUILD SUCCEEDED
- `xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air' build` → BUILD SUCCEEDED
- `xcodebuild test -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air'` → TEST SUCCEEDED（190件全成功、フェーズ6で新規24件追加）

## フェーズ7: ページスワイプ/削除スワイプ競合・バックグラウンド再生・アルバム階層

ユーザー報告の3件に対応。

### 決定1: ページスワイプと曲削除スワイプの競合

`WatchRootView` の Library ⇄ Now Playing 水平ページング（`.tabViewStyle(.page)`）と、
`WatchSongListView` の行 `swipeActions`（削除）がどちらも右スワイプのジェスチャー領域を
取り合っていた。**削除を `swipeActions` から長押しの `.contextMenu` に変更**し、行スワイプ
自体を廃止した。ページングは `WatchRootView` 側で変更なく維持。watchOS の
`List` 行では長押しコンテキストメニューが標準的な破壊的操作の導線でもあり、
Music アプリ等とも挙動が近い。

### 決定2: バックグラウンド再生

`WKExtendedRuntimeSession` はワークアウト等の「フォアグラウンド継続が前提の
長時間タスク」向けの API であり、音楽再生の正規ルートではなかった。
`WatchAudioPlayerService` を以下に変更:
- `AVAudioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)`
- `AVAudioSession.activate(options:completionHandler:)`（非同期。初回呼び出し時、
  出力先未接続なら OS が「オーディオ出力を選択」UI を出す）
- `play(_:queue:)` と `togglePlayPause()`（再開側）はこの activation を待ってから
  実際に `AVPlayer` を開始する構造に変更（`activateAudioSession(completion:)`）。
- activation 失敗時（主に Bluetooth 出力未接続）は `@Published var routeError:
  String?` にメッセージを設定し、`WatchNowPlayingView` に赤字で表示。
- `WKExtendedRuntimeSession` / `WKExtendedRuntimeSessionDelegate` 実装・
  `WatchKit` の import を削除。

**重要な制約（コード docコメントにも明記）**: watchOS は長時間のオーディオ再生を
本体スピーカーでは許可しない。Bluetooth 出力（イヤホン/AirPods等）が接続されて
いる必要があり、未接続時は `activate` が失敗して再生が始まらない。

### 決定3: アルバム階層

`Core/WatchPlaybackLogic.swift` に純関数 `WatchAlbumGrouping.albums(from:)` と
`WatchAlbumGroup`（`album`/`songs`/`artworkSong`）を追加。`displayAlbum`
（空文字は "Unknown Album" に丸められる）でグルーピングし、アルバム名の
ロケール比較で昇順ソート。トラック順は「iPhone から受信した順序をそのまま
維持する」（`WatchTransferMeta` にトラック番号フィールドが無いため）。
`UX-Music-MobileTests/WatchPlaybackLogicTests.swift` で TDD（Red→Green）。

UI 側は `WatchSongListView` に "Songs / Albums" のトグル（watchOS は
`.pickerStyle(.segmented)` が使えないため、2つの `Button` を並べた自作の
トグルで代替）を追加。Albums 選択時はアルバム一覧（アートワークサムネイル＋
アルバム名＋曲数）→ タップでそのアルバムの曲一覧（トラック順）→ 曲タップで
そのアルバムをキューとして再生、という階層にした。フラットな全曲リストは
Songs 側にそのまま残した。ページング構造（Library ⇄ Now Playing）はこの
変更の影響を受けない。行の描画・削除コンテキストメニューは `WatchSongRow`
という共有 private View に切り出し、フラットリストとアルバム詳細の両方から
再利用している。

### Alternatives considered

- 削除導線をトグルの「編集モード」ボタンにする案も検討したが、watchOS の
  画面サイズでは長押しコンテキストメニューの方が発見しやすく手数も少ないため
  不採用。
- Songs/Albums の切り替えを別ページ（`TabView` にページを追加）にする案は、
  「Library ⇄ Now Playing」の2ページ構成という既存メンタルモデルを崩すため
  見送り、Library ページ内のセクション切り替えとした。

### Constraints / Gotchas

- `.pickerStyle(.segmented)` は watchOS で unavailable（コンパイルエラー）。
  代替として `HStack` に並べた `Button` 2つで簡易トグルを自作した。
- `AVAudioSession.activate(options:completionHandler:)` は初回呼び出し時に
  システムの出力先選択 UI を出しうるため、シミュレータ単体では実際の
  Bluetooth 出力が無く `routeError` 側に倒れる可能性が高い。**実機で
  Bluetooth イヤホンを接続した状態での確認が必須**（下記参照）。
- シミュレータには曲データ転送手段が無く（WatchConnectivity のシミュレータ間
  転送はフェーズ3で不安定と判明済み）、Songs/Albums トグルやアルバム階層UI・
  削除コンテキストメニューの実データでのスクリーンショット確認は本フェーズでは
  行えなかった。ビルド成功・空ライブラリ状態でのアプリ起動・ページドット表示
  までは実機/シミュレータで確認済み。

### 検証結果

- `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS Simulator' build` → BUILD SUCCEEDED
- `xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone Air' build test` → BUILD SUCCEEDED / TEST SUCCEEDED（`WatchAlbumGrouping` 新規4件を含め全件成功）
- watchOS シミュレータ（Apple Watch Series 11 42mm, watchOS 27.0,
  `70E721E0-E9E9-477E-ACEA-FB8D939B74DC`）に単体ビルドをインストール・起動し、
  Library ページ（空状態）とページドットの表示をスクリーンショットで確認。

# フェーズ8: Watch側バグ3件の調査・修正（一括転送/シークバー/スタッター）

## Decision

- **バグ1（アルバム一括転送で1曲目しか届かない）**: `WatchConnectivityReceiver.session(_:didReceive:)`
  はコメントで示唆されていた「並行受信での索引 lost-update」を静的に精査したが、
  再現する欠陥は見つからなかった。ファイルコピー自体は `nonisolated` context で
  同期的に行われ、索引更新（`library.addSong`）は毎回 `Task { @MainActor in ... }`
  でラップされている。この closure は `await` を一切含まないため、Swift の
  MainActor 実行器は「サスペンションポイントなしの job を割り込みなく完了まで
  実行する」という保証により、複数ファイルがほぼ同時に `didReceive` されても
  `songs = WatchLibraryIndex.adding(meta, to: songs)` は必ず直列に、かつ
  互いの結果を上書きせずに実行される（どちらのファイルの Task が先に
  スケジュールされるかに関わらず、両方とも完了まで走り切る）。
  `WatchLibraryIndex.adding` は id ベースの追記のみで副作用を持たない純関数なので、
  到着順序に依存する欠陥もない。
  → 実際に watchOS シミュレータへ `library.json` に2曲（`lonewolf1`/`lonewolf2`,
  ともに album "Lone Wolf"）を直接書き込み、Library ページで2曲とも一覧表示
  されることを目視確認した（受信パイプラインを介さずファイルを置く形での検証。
  `session(_:didReceive:)` 自体を実機なしで駆動する watchOS 側テストターゲットが
  存在しないため、これが実施可能な最も直接的な検証）。
  → 回帰防止として `WatchTransferTests.testAddingRetainsAllEntriesRegardlessOfArrivalOrder`
  を追加: `WatchLibraryIndex.adding` を異なる到着順（正順/逆順/入れ替え）で
  畳み込んでも、全エントリが必ず残ることをピン留めした。将来 `addSong` の実装が
  「スナップショットを読んでから書き戻す」ような非同期な形に変更された場合、
  このテストと上記のアーキテクチャ上の不変条件（MainActor 上でサスペンションなし
  に完結する）の両方を壊さないよう配慮が必要。
  → 現状のコードに再現可能なバグを特定できなかったため、ユーザー報告の症状は
    (a) 過去のビルド（ファイルコピーの nonisolated 化前）のものだった、
    (b) WatchConnectivity 自体の実機特有の転送遅延/ドロップ（アプリコードの
        制御外）のいずれかの可能性が高いと考えられる。実機で再発した場合は
        `WatchConnectivityReceiver` に受信ファイルごとの詳細ログ（`transferFile`
        のメタデータ内容と成功/失敗）を追加し、iOS側の送信ログと突き合わせる
        のが次の診断ステップになる。

- **バグ2a（シークバーが一瞬オレンジ→青になる）**: 真因を特定した。
  `WatchNowPlayingView` は `.onAppear` と `.onChange(of: player.currentSong?.id)`
  で `crownPosition = progress.position` と“同期”のために書き込んでいたが、
  この代入自体が `.onChange(of: crownPosition)` を発火させ、そのハンドラは
  無条件に `isSeeking = true`（→ tint が `.orange`）をセットしてから 400ms の
  デバウンスタスクを起動していた。つまりユーザーが Crown に触れていなくても、
  ページ表示や曲切り替えのたびに「オレンジ→(400ms後)青」のフラッシュが
  発生していた。`isSyncingCrownProgrammatically` フラグを追加し、
  プログラム的な同期の直後の1回だけ `onChange` ハンドラを無視させることで、
  ユーザーの実際の Crown 操作のときだけ tint がオレンジになるよう修正した。

- **バグ2b（Series 11 42mm で画面外にはみ出る）**: `WatchNowPlayingView` の
  content を素の `VStack` から `ScrollView` でラップした。既存の固定
  padding/spacing は大きめの画面サイズを前提にしていたと見られ、42mm では
  シャッフル/リピート行が画面下端を割っていた可能性が高い。個々の余白を
  画面サイズ別に微調整するより、内容が収まらない画面では素直にスクロール
  させる方が壊れにくい。シミュレータ実機（Series 11 42mm, watchOS 27.0）で
  再生中の Now Playing 画面を確認し、タイトル・アーティスト・進捗バー・
  トランスポートボタンがすべて画面内に収まることを確認した
  （`progress/../.tmp/watch_nowplaying.png` 相当のスクリーンショットで検証、
  一時ファイルのため成果物には含めていない）。

- **バグ3（ページ往来時のスタッター、残存分）**: `WatchNowPlayingView.artworkImage`
  が **computed property** になっており、body 再評価のたびに（背景ブラー用・
  前景用の計 2 回）ディスクから JPEG を読み直し `UIImage(data:)` でデコードして
  いた。このビューは 0.5 秒ごとに更新される `progress.position` を購読して
  いるため、曲が変わらない間も 0.5 秒ごとに 2 回のディスク I/O + JPEG デコードが
  メインスレッドで走っていたことになる。これはフェーズ5〜7で対処した
  「`WatchPlaybackProgress` を分離して不要な `objectWillChange` を止める」対策
  の効果を一部相殺する、見落とされていた継続的なメインスレッド負荷であり、
  スタッター残存の有力な一因と判断した。`cachedArtworkImage`/`cachedArtworkSongId`
  を `@State` に持たせ、`currentSong.id` が実際に変わったときだけ
  `refreshCachedArtworkIfNeeded()` で再読込するよう変更した。
  - 実機プロファイルで追加確認すべき点（このセッションでは検証できず、
    実機なし・Instruments 未接続のため推測に留まる）:
    - Instruments の Time Profiler / Points of Interest で、ページ切替
      （TabView のスワイプ）前後のメインスレッド使用率と、AVAudioSession の
      再 activate 呼び出し回数（`activateAudioSession` は `play`/`togglePlayPause`
      からのみ呼ばれ、ページ遷移そのものからは呼ばれていないことをコードレベル
      では確認済みだが、実機で本当に再呼び出しが起きていないかは要確認）。
    - `addPeriodicTimeObserver` の 0.5 秒 tick 自体は Now Playing 非表示中も
      止めていない（`WatchAudioPlayerService.loadWithoutAutoplay` で登録した
      ままトラック終了までクリアされない）。処理内容は `progress.position` への
      代入のみで軽量ではあるが、Library ページ表示中に完全に無駄な tick が
      走り続けている点は将来的な最適化余地として残る（今回は「見えている間だけ
      軽くする」効果が薄いと判断し、着手しなかった）。

## Alternatives considered

- バグ1について、`WatchLocalLibrary`/`addSong` を `actor` へ全面移行する案も
  検討したが、既存アーキテクチャ（MainActor 上でのサスペンションなし実行）で
  既に安全性が担保されており、再現する欠陥もない状態で大規模リファクタを
  行うのは過剰対応と判断し見送った。

## Constraints / Gotchas

- `UX-Music-MobileTests` は iOS 側テストターゲットのみで、watchOS 専用の
  `WatchLocalLibrary`/`WatchConnectivityReceiver` 本体を直接ユニットテストする
  ターゲットは存在しない。これらの型を直接駆動する並行性テストを書くには
  watchOS 側テストターゲットの新設が必要（今回はスコープ外として見送り、
  代わりに共有・純粋ロジック `WatchLibraryIndex.adding` の到着順序不変条件を
  ピン留めするテストで代替した）。
- watchOS シミュレータは `xcrun simctl` 単体ではスワイプ/タップの入力注入が
  できない（`simctl io screenshot` は可能だが `simctl ui` 相当の入力コマンドは
  ない）。Now Playing ページの実表示確認には Simulator.app を computer-use で
  操作する必要があった。
