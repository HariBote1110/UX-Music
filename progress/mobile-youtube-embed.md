# iPhone版 YouTube 公式再生（フェーズ1: フォアグラウンド再生）

## 決定事項

### 検索機能は実装しない（デスクトップに存在しないため）
着手前調査で、デスクトップ版に YouTube「検索」機能自体が存在しないことを確認した
（`internal/youtube` にも `src/renderer` にも search 系の実装はなく、`GetYouTubeInfo`
=`GetYouTubeVideoInfo` による URL 貼り付け・解決のみ）。そのため当初想定していた
`/v1/remote/youtube/search` は追加せず、デスクトップと同じ「URL 貼り付け」体験を
`GET /v1/remote/youtube/resolve?url=…`（`server/app_remote_youtube.go`）として LAN API
に追加した。認証は既存の `deviceAuthMiddleware` に乗る（`registerRemoteRoutes` に登録）。
レスポンスは `{videoId, title, author, duration, thumbnail}`。

### iOS側のオリジン回避策: `loadHTMLString(_:baseURL:)`
デスクトップ (`server/embed_host.go`) はエラー153（Referer/origin 欠落）回避のため
`127.0.0.1` ループバック HTTP サーバーでプレイヤーページを配信している。iOS では
常駐 HTTP サーバーを立てず、`WKWebView.loadHTMLString(html, baseURL: URL(string:
"http://127.0.0.1"))` を採用した。`baseURL` 指定はページの `document.location`/
`origin` をその URL に設定するため、実際にその URL へリクエストが飛ばなくても
YouTube IFrame API から見て正当な `http://` オリジンとして扱われる。

`WKURLSchemeHandler` でカスタムスキーム（`ux-embed://` 等）を立てる案も検討したが、
カスタムスキームは `http`/`https` オリジンではないため YouTube 側が引き続き
埋め込みを拒否する可能性が高く、`loadHTMLString(baseURL:)` より実装・保守コストが
高いため採用しなかった。

### JS ブリッジ
`postMessage` ではなく `WKScriptMessageHandler`（`uxYouTube`）でネイティブへイベント
送信、`evaluateJavaScript` 経由の `window.uxYouTubeCommand(...)` でネイティブから
制御する方式に変更した（`postMessage` は親フレームが必要だが WKWebView 単体では
親フレームという概念がなく `WKScriptMessageHandler` の方が自然なため）。
純関数は `UX-Music-Mobile/UX-Music-Mobile/Services/YouTubeEmbedPlayer.swift` に切り出し、
`UX-Music-MobileTests/YouTubeEmbedPlayerTests.swift` でHTML生成のバリデーションと
ブリッジメッセージのパースをテストしている。

### ローカル再生との排他
YouTube 再生を開始する際（`YouTubePlayerScreen` のプレイヤー起動ボタン）に
`AppModel.player.stop()` を呼び、`MusicPlayerService` 側のローカル再生を止めてから
フルスクリーンプレイヤーを開く。EQ・Watch連携・バックグラウンド再生・ダウンロード/
非公式ストリーミングは今回のスコープ外。

## 変更ファイル
- `server/app_remote_youtube.go` / `server/app_remote_youtube_test.go`（新規）
- `server/app_remote.go`（ルート登録）
- `UX-Music-Mobile/UX-Music-Mobile/Services/YouTubeEmbedPlayer.swift`（新規・純関数）
- `UX-Music-Mobile/UX-Music-Mobile/Services/RemoteAPIClient.swift`
  （`RemoteYouTubeVideoInfo` / `resolveYouTubeVideo(url:)`）
- `UX-Music-Mobile/UX-Music-Mobile/Views/YouTubeEmbedPlayerView.swift`（新規・WKWebViewラッパー）
- `UX-Music-Mobile/UX-Music-Mobile/Views/YouTubePlayerScreen.swift`（新規・URL貼り付け→再生画面）
- `UX-Music-Mobile/UX-Music-Mobile/Views/HomeRootView.swift`（YouTubeタブ追加）
- `UX-Music-Mobile/UX-Music-MobileTests/YouTubeEmbedPlayerTests.swift`（新規）
- `UX-Music-Mobile/UX-Music-Mobile.xcodeproj/project.pbxproj`（上記新規ファイルの手動登録）

## 未検証・今後の課題
- シミュレータでは YouTube IFrame の実再生自体が制限される場合があり、実機での
  動画再生確認は未実施。
- iOS の音声セッション（`AVAudioSession`）と `MusicPlayerService` の processTap の
  共存挙動は未検証（今回は `stop()` で明示的に排他するのみ）。
- バックグラウンド再生・Now Playing センター連携は次フェーズ。

## 統合フェーズ: 専用タブ廃止 → 通常ライブラリへの統合

### Decision
デスクトップの「YouTube もライブラリの一員」という方針に合わせ、iPhone の専用
「YouTube」タブを廃止し、Remote ライブラリの通常曲一覧に統合した。

- サーバー: `POST /v1/remote/youtube/add`（`server/app_remote_youtube.go`）を新設し、
  デスクトップの `App.AddYouTubeLink` をそのまま呼ぶ。デスクトップの再生モード設定
  （embed/stream/download）に従って登録され、以後は既存の `GET /v1/remote/songs` が
  そのまま返す（`type`/`sourceURL` フィールドは元々ペイロードに含まれていたため、
  songs ハンドラ自体の変更は不要だった）。
- iPhone `Song` モデルに `sourceType`（JSON キー `type`、未指定は `.local`）と
  `sourceURL` を追加。`isYouTube` 計算プロパティで判定。
- `WatchTransferMenuPolicy.isEligibleForTransfer` / `songsEligibleForBulkTransfer` で
  YouTube 曲を Watch 転送対象から除外。`AppModel.downloadAlbum` /
  `downloadPlaylistSongs` / `albumHasTracksToDownload` / `playlistSongsContainUndownloaded`
  も同様に YouTube 曲をスキップする。
- `RemoteLibraryScreen` の曲行: YouTube 曲は末尾に `play.rectangle.fill` インジケータを
  表示し、タップ／コンテキストメニューから `RemoteYouTubeSongPlayerScreen`
  （旧 `YouTubePlayerScreen` のプレイヤー部分を流用・改称）を全画面表示する。
- URL 追加導線は `RemoteLibraryScreen` のヘッダーに新設した ellipsis メニュー →
  `AddYouTubeLinkSheet`（新規）に移設。追加後は `model.refreshLibrary()` で
  一覧を再取得する。
- `HomeRootView` から `.youtube` タブを削除。`YouTubePlayerScreen.swift` の
  URL 貼り付け UI は削除し、`YouTubeFullScreenPlayer`（internal 化）と
  `RemoteYouTubeSongPlayerScreen`（新規・URL解決→プレイヤー表示のラッパー）のみ残した。

### Alternatives considered
- `Song` に `videoId` を専用フィールドとして持たせる案は見送った。デスクトップの
  ライブラリ JSON には videoId が保存されておらず（`path`/`sourceURL` が動画URL）、
  タップ時に既存の `RemoteAPIClient.resolveYouTubeVideo(url:)` を呼んで解決する
  既存フローをそのまま流用する方がサーバー側の変更を増やさずに済む。

### Constraints / Gotchas
- `/v1/remote/youtube/add` は `deviceAuthMiddleware` に自動的にかかるため、
  ハンドラ自身は認証チェックを持たない（`isPublicLANEndpoint` に含めていない）。
- YouTube 曲のダウンロード除外はダウンロードボタンを隠すだけでなく、
  `AppModel` のアルバム/プレイリスト一括ダウンロードのループからも
  除外している点に注意（ここを忘れると一括ダウンロードが動画URLをファイルとして
  ダウンロードしようとして失敗する）。

## フェーズ3: 実機再生エラー修正（ループバック方式への切り替え）

### Decision
`loadHTMLString(_:baseURL:)` の擬似オリジン方式は、シミュレータの一部動画では
動いていたものの実機報告で再生エラーになるケースがあった。原因は WebKit が実際に
`http://127.0.0.1` へリクエストを発行するわけではなく、`document.location`/`origin`
だけをその値に見せかけている点にあり、埋め込み制限のある動画（IFrame API エラー
150/153系）や実機の WebKit 実装差でこの見せかけが通らないケースがあると判断した。
デスクトップ（`server/embed_host.go`）が本物の `127.0.0.1` ループバック HTTP
サーバーで解決済みだったため、iOS 版にも同じ方式を移植した。

- 新規 `UX-Music-Mobile/UX-Music-Mobile/Services/YouTubeEmbedLoopbackServer.swift`:
  `Network.framework` の `NWListener`（`requiredLocalEndpoint = 127.0.0.1:any`）で
  ループバック限定の最小 HTTP/1.1 サーバーを実装。`GET /embed?v=<id>` のみに応答する。
  アプリプロセス内で一度だけ起動し、以後は `YouTubeEmbedPlayerView` が使い回す
  （desktop の `sync.Once` 常駐ホストと同じ設計）。
- `YouTubeEmbedPlayer.loopbackPageURL(port:videoID:)` を追加（`embedHostPageURL`
  のiOS版）。`YouTubeEmbedPlayerView` は `loadHTMLString` ではなく
  `webView.load(URLRequest(url:))` でこの URL を読み込むように変更。
- `YouTubeEmbedPlayer.errorMessage(code:)` を追加し、IFrame API の `onError`
  コード（2/5/100/101/150、および `-1`=ループバックサーバー起動失敗）を日本語の
  エラーメッセージに変換。`RemoteYouTubeSongPlayerScreen`（`YouTubeFullScreenPlayer`）
  で `.error` イベント受信時にこのメッセージを画面に表示するようにした
  （従来は握りつぶされてユーザーには何も表示されなかった）。

### Alternatives considered
- `WKURLSchemeHandler` によるカスタムスキームは、依然として `http`/`https`
  オリジンではないため見送り（フェーズ1と同じ判断を維持）。
- ループバックサーバーをリクエストごとに起動/停止する案は、初回再生の遅延と
  実装の複雑化を招くため、desktop 同様「アプリ起動中は張りっぱなし」を採用。

### Constraints / Gotchas
- `NWListener` の `newConnectionHandler`/`stateUpdateHandler` は `.main` キュー上で
  呼ばれるが、`YouTubeEmbedLoopbackServer` 自体は actor なので、キュー由来のコード
  から actor 内メソッドを呼ぶ際は必ず `Task { await ... }` で橋渡ししている。
- `YouTubeEmbedLoopbackServerTests` はモックを使わず、実際に `NWListener` を
  `127.0.0.1:0`（空きポート）で起動して `URLSession` から本物の HTTP リクエストを
  投げる統合テストにした（`server/embed_host_test.go` と同じ戦略）。
- 本フェーズでは「YouTube 曲をローカルライブラリの通常曲と同列に扱う」という
  ユーザー要望のうち、公式プレイヤーの再生エラー修正（フェーズA）のみを実施した。
  ローカルライブラリへの `メタデータのみ登録` とキュー/お気に入り/プレイリストへの
  完全統合（フェーズB: `DownloadManager` 相当のYouTube用永続化、
  `MusicPlayerService` へのYouTubeバックエンド追加、`NowPlayingView` への埋め込み
  プレイヤー表示、queue の自動次曲送り連携）は本セッションのスコープに含めなかった。
  `MusicPlayerService`（999行）・`NowPlayingView`・`DownloadManager` の永続化構造
  （`isDownloaded` がファイル実在チェックに強く依存している）に踏み込む必要があり、
  安全に TDD で刻むには別セッションでの着手が妥当と判断した。次回着手時は
  `DownloadManager.isDownloaded` とは別の「ライブラリメンバーシップ」概念を先に
  設計してから、`MusicPlayerService` の再生バックエンド切替に着手するとよい。

## フェーズB: ライブラリ統合と統一プレイヤー（本セッション）

### Decision: `LibraryMembershipStore` でメンバーシップとファイル実在を分離
`DownloadManager.downloadedSongs` は「メタデータ」と「ファイル実在」を前提が
密結合しており（`isDownloaded` はファイルが実際に存在するかを都度チェックする）、
YouTube曲（ファイルを持たない）をそのまま登録すると壊れる。そこで
`Services/LibraryMembershipStore.swift` を新設し、YouTube曲のメタデータのみを
`UserDefaults`（`youtube_library_songs_meta_v1`）に永続化する専用ストアとした。
`AppModel.librarySongsById`（private computed）が `DownloadManager.downloadedSongs`
と `LibraryMembershipStore.songs` をマージし、`sortedDownloadedSongsForLibrary` /
`resolvedSongs(for:)` / `favouriteSongsForPlayback` / `artworkIdForPlaylist` /
`downloadedSongsEligibleForPlaylist` はすべてこのマージ結果を参照するよう変更した。
`isSongDownloaded`（ファイル実在）とは別に `isLibrarySongMember`（メンバーシップ有無）
を新設し、呼び分けている。

`RemoteLibraryScreen` の `SongRowDownloadTrailing` は YouTube曲について、従来の
静的アイコン表示から「追加」ボタン（未追加時 `plus.circle`）/ チェック表示
（追加済み `checkmark.circle.fill`）に変更。コンテキストメニューにも
追加/削除アクションを追加した。

### Decision: `MusicPlayerService` に第二の再生バックエンドを追加（ファイルの書き換えは最小化）
既存の `AVAudioEngine` タイムライン管理（`currentAudioFile`/`scheduledSegmentStartFrame`
等）は大規模なため全面刷新はせず、`currentSong.isYouTube` で分岐する薄いルーティング層
（`loadActive(_:)`）を `play`/`next`/`previous`/`playQueueItem` の内部呼び出し点に追加した。
YouTube曲用に `youtubeController`（`YouTubePlayerController`、既存の embed 実装から流用）・
`currentYouTubeVideoID`・`resolveYouTubeVideoID`（`AppModel` から注入されるクロージャ、
`resolveYouTubeVideo` LAN APIを叩く）・`handleYouTubeBridgeEvent(_:)` を追加。
IFrame Player API の `onStateChange(ended)` は既存の `advanceAfterEnd()` を呼ぶことで
ローカル曲の自然終了と同じキュー送り経路に合流する。バックエンド切替時は
`stopLocalPlaybackEngineOnly()` / `stopYouTubeBackend()`（どちらも `queue`/`currentSong`
は保持したまま該当バックエンドだけ止める）で相互に排他した。

`NowPlayingView` の `NowPlayingArtworkBlock` は `song.isYouTube` のとき
`YouTubeEmbedPlayerView` をアートワーク領域に表示し、`onEvent` を
`MusicPlayerService.handleYouTubeBridgeEvent` に直結。歌詞ボタンは YouTube曲では無効化。
EQ（`NowPlayingPlaybackSettingsPanel`）側の無効化は本セッションでは未着手（ファイル前提の
機能ではあるが、有効にしても実害はなく — ローカル再生と異なりEQは効かないだけ — 優先度を
下げた）。

### Constraints / Gotchas
- `resolveYouTubeVideoID` は `song.sourceURL ?? song.path` を都度サーバーへ問い合わせる
  （動画IDのキャッシュはしていない）。オフライン時はエラーメッセージを
  `youtubePlaybackErrorMessage` に格納し `NowPlayingView` に表示する。
- `WKWebView` は `NowPlayingView` が表示されているときだけ生成される（`YouTubeEmbedPlayerView`
  は `UIViewRepresentable`）。バックグラウンド/オフスクリーンでの常駐生成は行っていない
  ため、Now Playing シートを閉じると WKWebView は破棄され、IFrame 側の再生も止まる
  （`isPlaying` の状態はサービス側に残るが実体の再生は止まっている）。完全なバックグラウンド
  再生には、アプリのルート階層に常駐する非表示ホストへの置き換えが必要 — 次フェーズの課題。
- テストは `LibraryMembershipStoreTests`（永続化ラウンドトリップ）を追加。
  `MusicPlayerService` のYouTubeバックエンド分岐はWKWebView/ネットワーク依存が強く、
  既存の `YouTubeEmbedPlayerTests`（純関数レイヤー）でカバーされる範囲を超える単体テストは
  今回追加していない（`resolveYouTubeVideoID` や `handleYouTubeBridgeEvent` の呼び出し
  経路は手動/シミュレータでの動作確認に依存）。

## フェーズB追補: WKWebViewの常駐化・EQ無効化・videoIDキャッシュ

### Decision: `YouTubePlaybackHost` でWKWebViewをサービスレベルに常駐させる
従来 `NowPlayingView` が `YouTubeEmbedPlayerView`（`UIViewRepresentable`）を直接生成しており、
Now Playingを閉じると`WKWebView`ごと破棄され、YouTube曲の再生がその場で止まっていた
（ローカル曲は`AVAudioEngine`がバックグラウンドで鳴り続けるのと非対称だった）。
`Services/YouTubePlaybackHost.swift`（新規、`NSObject & WKScriptMessageHandler`）を
`MusicPlayerService.youtubePlaybackHost`として常駐させ、`WKWebView`をアプリプロセスの
生存期間中ずっと保持するようにした。`Views/YouTubeEmbedHostContainerView.swift`（新規）は
この単一のWKWebViewインスタンスを「借りて表示」するだけの`UIViewRepresentable`で、
表示中は現在のコンテナに`addSubview`、`dismantleUIView`では単に`removeFromSuperview`する
だけで**破棄はしない**。WKWebViewインスタンス自体が生き続け、JS/IFrame再生状態も維持される
ため、Now Playingを閉じてLocal Libraryに戻ってもYouTube曲の音が鳴り続け、ミニプレイヤー/
リモートコマンドからのpause/nextも引き続き効く。

`loadAndPlayYouTube`は`youtubePlaybackHost.load(videoID:)`を直接呼ぶよう変更し、
「NowPlayingViewが表示された結果としてWKWebViewが生成され再生が始まる」という以前の
（ビューの生成に再生開始が依存する）暗黙の前提を解消した — 再生開始はサービス層の
`play()`呼び出し時点で決まり、ビューの表示・非表示とは独立している。

共有の`YouTubeEmbedLoopbackServer`は`.shared`という静的プロパティに変更し、常駐ホストと
（ライブラリ追加前のプレビュー用に残した）`YouTubeEmbedPlayerView`の使い捨てWKWebViewの
両方が同じループバックサーバーを使う。

### Decision: EQパネルはYouTube曲再生中は無効化
`NowPlayingPlaybackSettingsPanel`のEqualiserセクションに`.disabled(isYouTubeSong)`を付与し、
footerに「YouTube曲の再生には適用されません。」を表示。EQは`AVAudioUnitEQ`経由でローカル
再生のみに効くため、YouTube曲では操作しても無意味であることを明示した。

### Decision: `resolveYouTubeVideoID`の結果をメモリキャッシュ
`MusicPlayerService.youtubeVideoIDCache: [String: String]`（songId→videoId）を追加。
同じYouTube曲を再度再生する際はサーバーへ問い合わせず、キャッシュ済みのvideoIdを
そのまま`youtubePlaybackHost.load(videoID:)`に渡す。プロセス内メモリのみ（永続化はしない）。

### Constraints / Gotchas
- `YouTubePlaybackHost.userContentController(_:didReceive:)`は`nonisolated`にした上で
  `MainActor.assumeIsolated`経由で`onEvent`を呼ぶ（`WKScriptMessageHandler`はメインスレッドで
  呼ばれる契約だが、プロトコル要件自体は`@MainActor`ではないため）。
- `YouTubeEmbedHostContainerView`の`dismantleUIView`はstaticメソッドで`webView`を直接
  キャプチャできないため、コンテナの`subviews`から`WKWebView`を探して`removeFromSuperview`
  している（同じインスタンスなので実質的に`webView.removeFromSuperview()`と同じ効果）。
- アプリがバックグラウンドに回った場合の挙動（`AVAudioSession`は維持されるが、WKWebViewの
  JS/メディア実行がOS側でどこまで継続されるか）は本追補では未検証。フォアグラウンド内での
  画面遷移（Now Playing ⇄ Library）のみ確認対象とした。

## フェーズC: 「特定動画が埋め込み不可」報告の調査（error 150 の真因特定）

### 症状
実機報告: 特定動画（例: Rick Astley "Never Gonna Give You Up"、videoId
`dQw4w9WgXcQ`）で公式再生が「埋め込み不可」エラーになる。デスクトップ
（`server/embed_host.go`、同一IFrameパラメータ）では同じ動画が再生できる。

### 調査手法
`UXMusicMobileApp.swift`に隠しデバッグフック
`installDebugYouTubeAutoplayHookIfRequested()`を追加（`ProcessInfo.processInfo
.environment["UXM_DEBUG_YT_VIDEO"]`が設定されていれば起動直後にその動画IDで
`youtubePlaybackHost.load(videoID:)`を直接叩き、ブリッジイベントを`NSLog`に出力）。
`xcrun simctl launch --setenv`（正しくは`SIMCTL_CHILD_UXM_DEBUG_YT_VIDEO`環境変数）
+ `xcrun simctl spawn <udid> log show`でイベントを観測した。このフックは実害がない
（環境変数を明示的に設定しない限り何もしない）ため、恒久的に残した。

### 観測結果: エラーコードは150で確定
- `dQw4w9WgXcQ`: `ready` 直後に `error(code: 150)`（「埋め込みが許可されていません」）
- `jNQXAC9IVRw`（制限なし動画、比較対照）: `ready` → `time` が継続、エラーなし

### 検証した仮説と結果（すべて効果なし）
1. **モバイルUAが原因** — `webView.customUserAgent`をmacOS Safari相当に偽装 →
   **効果なし**（150のまま）。最終的にこの変更は撤回した（効果が確認できない
   User-Agent偽装を残す理由がないため）。
2. **`mute:1`/mute-then-unmute autoplayシーケンスの欠如** —
   `server/embed_host.go`はautoplay+`mute:1`で開始し`onReady`で明示的に`player.mute()`
   を呼ぶ（生音漏れ防止のため）のに対し、iOS版はミュートなしのunmuted autoplayだった。
   playerVars・onReadyシーケンスをdesktopと完全一致させても**効果なし**。
   ただしこの変更自体はdesktopとの一貫性のため`YouTubeEmbedPlayer.swift`に維持した。
3. **`window.webkit.messageHandlers`のフレーム越境露出** —
   `WKUserContentController.add(_:name:)`（デフォルトの`.page`ワールド）で追加した
   メッセージハンドラは、そのWKWebView内の**全フレーム**（`youtube.com/embed/<id>`の
   ような別オリジンのiframeも含む）自身の`window`オブジェクトに注入される
   （Appleのセキュリティガイダンスが警告する既知の挙動）。YouTube側のプレイヤー
   スクリプトがこれを検出して「ネイティブアプリのWKWebView内」と判定し再生拒否
   している可能性を疑い、`WKContentWorld.world(name:)`による専用ワールドへの隔離
   （`YouTubePlaybackHost.bridgeContentWorld`）+ `window.postMessage`ベースの
   リレー（`WKUserScript`、desktop方式に一致）へ切り替えたが、**効果なし**
   （150のまま）。この変更自体はセキュリティ上のベストプラクティス
   （ネイティブブリッジの露出範囲最小化）として正当性があるため維持した。

### 真因: YouTube側のモバイルWeb埋め込み制限（クライアント側では回避不能）
上記いずれの変更でも解消しなかったため、**アプリ/WKWebViewの設定とは無関係の
問題**であることを検証する目的で、シミュレータの実Safari（当アプリを一切介さない）
で同一検証を行った:

1. `https://www.youtube.com/embed/dQw4w9WgXcQ?...`へ直接ナビゲート → 「動画を
   再生できません」表示。
2. 当アプリのループバックサーバー（`YouTubeEmbedLoopbackServer`）が実際に配信する
   `http://127.0.0.1:<port>/embed?v=dQw4w9WgXcQ`ページ（IFrame APIによる入れ子
   iframe構造も含め、当アプリのWKWebViewが読み込むページと完全に同一）へ実Safari
   でナビゲート → **同じく「動画を再生できません」**。

これにより、**未改変の実機モバイルSafariでも同じエラーが再現する**ことが確定した。
つまりWKWebViewの構成（UA・メッセージハンドラ・mute有無等）は無関係で、
YouTubeのサーバー側がこの動画（および同種の動画）についてモバイルWebブラウザ
からの埋め込みを拒否している——正規アプリへの誘導を目的とした、パブリッシャー側
またはYouTube側の意図的な制限である可能性が高い。デスクトップで再生できるのは
デスクトップブラウザ（Wails/WKWebView on macOS）からのアクセスだからであり、
iOS版が「デスクトップと同一パラメータなのに失敗する」のはクライアント実装の
不備ではなく、YouTube側がクライアントのプラットフォームで区別しているため。

### 結論・今後の方針
- クライアント側（JS/WKWebView設定）でのさらなる回避策は、正規の手段では
  見込みが薄いと判断し、本セッションでは追加のなりすまし策（より深いUA/
  Client Hints偽装等）は実施しないこととした。
- `youtubePlaybackErrorMessage`（`YouTubeEmbedPlayer.errorMessage(code:)`の
  101/150文言「この動画は投稿者により埋め込み再生が許可されていません。
  YouTubeアプリでご視聴ください。」）は、この真因に照らして妥当な内容のまま
  据え置いた（変更不要）。
- 隠しデバッグフック（`UXM_DEBUG_YT_VIDEO`環境変数）は今後同種の実機報告調査に
  再利用できるよう残している。

### Constraints / Gotchas
- `xcrun simctl launch --setenv`は無効（`Invalid device: --setenv`）。環境変数は
  呼び出し側シェルで`SIMCTL_CHILD_<NAME>`変数として渡す必要がある
  （`export SIMCTL_CHILD_UXM_DEBUG_YT_VIDEO=<videoId>`してから`simctl launch`）。
- `xcrun simctl spawn <udid> log stream`をバックグラウンドでリダイレクトすると
  バッファリングにより出力が遅延することがある。確実に読むには
  `xcrun simctl spawn <udid> log show --last <N>s --predicate '...'`を都度実行する
  方が確実。

## フェーズD: embed不可(101/150)発生時のフォールバックUX

フェーズCで「クライアント側では回避不能」と結論した embed 不可エラーについて、
再生自体を通す代わりに **ユーザーを公式アプリ/サイトへ誘導する**フォールバックを実装した。

### Decision: 判定・URL生成は`YouTubeEmbedPlayer`の純関数に切り出し
- `YouTubeEmbedPlayer.EmbedFallback`（`.none` / `.openInYouTubeApp`）と
  `embedFallback(forErrorCode:)`: 101/150のみ`.openInYouTubeApp`と判定
  （他コードは再試行不可能なほどの制限ではない、または動画自体が存在しないため
  「YouTubeで開く」を出しても意味がない）。
- `youtubeAppDeepLinkURL(videoID:)`（`youtube://watch?v=<id>`）、
  `youtubeWebFallbackURL(videoID:)`（`https://www.youtube.com/watch?v=<id>`）、
  `urlToOpen(forVideoID:youtubeAppIsAvailable:)`（アプリ有無で切替）を追加。
  `UIApplication.canOpenURL`の結果をBoolでそのまま渡す設計にし、`UIApplication`
  依存を持ち込まずに純関数のままテスト可能にした（`YouTubeEmbedPlayerTests`に
  TDDで先にテストを追加してからこの実装をコミット）。
- `Info.plist`に`LSApplicationQueriesSchemes`として`youtube`を追加。これがないと
  YouTubeアプリがインストールされていても`canOpenURL`が常に`false`を返す
  （iOSの仕様）。

### Decision: `MusicPlayerService`側の状態とキュー自動スキップ
- `youtubePlaybackErrorFallback`・`youtubePlaybackErrorVideoID`を追加。
  `.error(code:)`受信時、`embedFallback`が`.openInYouTubeApp`の場合のみ
  `currentYouTubeVideoID`を`nil`にクリアする（`NowPlayingView`側の表示優先度が
  `currentYouTubeVideoID != nil`→WebView / それ以外→エラーメッセージ、の順の
  ままなので、クリアしないと「読み込み済みだが実際には死んでいるWebView」が
  エラー表示より優先されてしまう。他のエラーコードではこの優先度の問題は
  従来から未解決のまま — 本フェーズのスコープ外として据え置いた）。
- `scheduleAutoSkipAfterEmbedRestriction(generation:)`: 3秒待ってから
  `youtubePlaybackJustSkippedMessage`（トースト文言）をセットして
  `advanceAfterEnd()`を呼ぶ（`queue.count > 1`なら`next()`、単曲キューなら
  停止するだけ、という既存の分岐をそのまま流用）。`generation`
  （`youtubePlaybackGeneration`）で、待機中にユーザーが手動操作した場合は
  スキップしない安全策とした。
- `openYouTubePlaybackErrorInYouTubeApp()`: `youtubePlaybackErrorVideoID`から
  `urlToOpen`でURLを組み立てて`UIApplication.shared.open`する。
  `NowPlayingView`の「YouTube で開く」ボタンから呼ばれる。

### Alternatives considered
- 「スキップした」トーストを`NowPlayingArtworkBlock`内（エラー表示と同じ場所）に
  出す案は不採用。`stopYouTubeBackend`/`loadAndPlayYouTube`は次の曲へ切り替わる
  際に`youtubePlaybackErrorMessage`を即座にクリアするため、エラービュー内に
  ネストしたトーストは次の曲のロードが完了する前に表示領域ごと消えてしまい、
  実質ユーザーの目に触れない。そのため`NowPlayingPlayingShell`（曲種別を問わない
  シェルレベル）にトーストを昇格し、`youtubePlaybackJustSkippedMessage`自体は
  `stopYouTubeBackend`/`loadAndPlayYouTube`では**意図的にクリアしない**
  （自身の3秒タイマーでのみ消える）ようにして、次の曲（ローカル曲でもYouTube曲でも）
  の表示に重ねて数秒だけ見えるようにした。
- 自動スキップの遅延時間は3秒固定とした。「YouTubeで開く」をタップする猶予と、
  キューを長時間止めないことのバランスとして妥当と判断（ユーザー設定化は
  オーバーエンジニアリングと判断し見送り）。

### Constraints / Gotchas
- `handleYouTubeBridgeEvent`・`scheduleAutoSkipAfterEmbedRestriction`・
  `openYouTubePlaybackErrorInYouTubeApp`はWKWebView/UIApplication/実際のキュー
  状態に強く依存するため、フェーズBと同様に単体テストは追加していない
  （純粋ロジック部分の`YouTubeEmbedPlayer`のみTDDでカバー）。動作確認は
  ビルド成功・既存テストスイート全green・コードレビューベース。
- `youtubePlaybackErrorVideoID`は`.error`受信時点の`currentYouTubeVideoID`を
  退避したものであり、`currentYouTubeVideoID`自体は同じタイミングで`nil`に
  クリアされる。両者を混同すると「開く」ボタンがvideoIDを見失うので注意。
