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
