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
