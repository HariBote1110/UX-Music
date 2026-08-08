# UX Music Mobile: 発見ピア選択の疎通確認とフェイルオーバー

## Decision

- mDNS で発見した相手先ホストを設定に保存する経路（`SettingsScreen.selectDiscoveredPeer`）が
  疎通確認なしで `model.serverConfig` を書き換えていたのが根本原因。デスクトップが
  VPN の utun など複数インターフェースの IPv4 アドレスを広告すると、
  `WearDiscoveryPeer.host`（先頭候補）が到達不能な IP になることがあり、
  Remote タブ「Failed to load library」・Control タブ「Desktop unreachable」が
  断続的に発生していた。
- `WearConnectionResolver.resolve(candidates:ping:)` を新設し、候補ホストを順に ping して
  最初に成功したものだけを返す実装に一本化した。`SettingsScreen.testConnection`（元々
  正しく疎通確認していた実装）と `selectDiscoveredPeer`（疎通確認していなかった実装）の
  両方をこの resolver 経由にリファクタし、ピア選択時にも必ず疎通確認が入るようにした。
- `ServerConfig.fallbackHosts` を追加し、疎通確認・接続テストに成功した際、失敗した／
  試さなかった残りの候補ホストを保存する。`AppModel.withFailover` は、まず
  `serverConfig.host` で操作を実行し、`URLError`（到達不能・タイムアウト系）の場合のみ
  `fallbackHosts` を順に再試行し、成功したホストを `serverConfig.host` に昇格・元のホストを
  `fallbackHosts` に降格する。`AppModel.refreshLibrary` / `refreshLoudnessOnly` /
  `fetchDesktopPlaylistsPreview` / `importDesktopPlaylists` / `downloadSong` /
  `cacheArtworkAfterDownloadIfNeeded` / `fetchAndStoreLyricsIfAvailable` と
  `RemoteControlScreen` の `send` / `pollOnce` / シークコマンドをこの経路に統一した。
- `ServerConfig.Equatable` は `host` と `port` のみを比較するようにした（`fallbackHosts` は
  無視）。理由: `SettingsScreen` は `model.serverConfig == peer.serverConfig` で「選択中の
  発見ピア」にチェックマークを表示している。フェイルオーバーで `fallbackHosts` の中身が
  変化しても、これが選択中ピアの判定に影響してはならない。
- `ServerConfig` の `Codable` 合成実装は使わず、`init(from:)` をカスタム実装して
  `fallbackHosts` を `decodeIfPresent` で読む。Swift の自動合成 `Codable` は既定値付き
  プロパティでもキー不在でデコード失敗するため、既存の永続化データ（`fallbackHosts` キー
  なし）との後方互換に必須。

## Alternatives considered

- 「発見ピアの `host` を選ぶ順序を変える（プライベート IP を優先するなど）」も検討したが、
  ネットワーク構成次第で確実性がなく、疎通確認そのものを行わない限り再発しうるため見送った。
  疎通確認 + フェイルオーバーの組み合わせで恒久対応とする。

## Constraints / Gotchas

- `AppModel.withFailover` は HTTP ステータスエラー（`WearDownloadError.httpStatus`）では
  フェイルオーバーしない。サーバーに到達できている＝ホストは正しいので、フェイルオーバー
  対象ではなくアプリ側のエラーとして扱うべきだから。
- テストは `AppModel.urlSession`（テスト用に注入可能にした `URLSession`）と
  `MockURLProtocol` を使い、実ネットワークなしでフェイルオーバー挙動を検証している
  （`UX-Music-MobileTests/AppModelFailoverTests.swift`）。
- Xcode プロジェクトはファイルシステム同期グループを使っておらず、新規 `.swift` ファイルは
  `project.pbxproj` に手動で `PBXBuildFile` / `PBXFileReference` / グループ / Sources
  ビルドフェーズの4箇所を追加しないとビルド対象に入らない。

## 第2の根本原因: 認証トークン欠落（401 で全データ取得が失敗）

- 疎通確認・フェイルオーバーを直しても、`server/app_wear.go:652` の `wearAuthMiddleware` が
  `/wear/ping` と `/wear/mobile` 以外の全エンドポイントを認証必須にしているため、依然として
  同期が失敗していた。トークンは `?token=` クエリ／`X-UX-Music-Token` ヘッダー／
  `Authorization: Bearer` のいずれかで受理されるが、iOS アプリはどの経路でもトークンを
  送っておらず、`fetchSongs` / `fetchState` / `downloadFile` などが軒並み 401 になっていた。
  QR ペアリング URL `uxmusic://pair?host=&port=&token=` の `token` クエリも
  `ServerConfig.fromPairingURL` が読み捨てていた。
- `ServerConfig` に `token: String = ""` を追加し、`fallbackHosts` と同じ理由でカスタム
  `init(from:)` に `decodeIfPresent` で後方互換デコードを実装した。`fromPairingURL` は
  `uxmusic://` と `http(s)://` の両スキームで `token` クエリを読むようにした。
  `Equatable` は `fallbackHosts` と同様 `token` も無視する（比較対象は `host`/`port` のみ）
  ——設定画面の「選択中ピア」チェックマークが、トークンの再入力や再ペアリングで壊れないため。
- `WearAPIClient` は `token` を保持し、`session.data(from:)` 直呼びをやめて
  `URLRequest` を組み立てるヘルパー（`authorizedRequest`）経由に統一、`X-UX-Music-Token`
  ヘッダーを付与するようにした。`artworkURL(artworkId:)` は文字列 URL として画像ローダーに
  渡る経路のためヘッダーが使えず、`token=` をクエリに追加する方式にした（`downloadFile` /
  `downloadArtwork` も同様にクエリ方式）。
- `fetchState()` は元々 HTTP ステータスを見ずに常に JSON デコードを試みていたため、401 の
  ボディが JSON でない場合に不定形のエラーになっていた。他メソッドと同じパターンで
  ステータスチェックを追加し、非 2xx を `WearDownloadError.httpStatus(code)` として
  投げるようにした——これにより「到達はできるが未認証」を判別できるようになった。
- `WearConnectionResolver.checkAuthorised(client:)` を新設。`ping`（`/wear/ping` は認証
  不要）が成功しても認証されているとは限らないため、認証必須の `/wear/state` を叩いて
  `401` なら `false`、それ以外の失敗（オフライン・タイムアウト等）は「未証明であり否定は
  されていない」として `true` を返す。`SettingsScreen.testConnection` /
  `selectDiscoveredPeer` はこれを resolve 成功後に呼び、`pingResult` を
  「Connected to …」（緑）と「Connected but not paired — scan the QR code or enter the
  token」（赤）で出し分ける。
- Settings の SERVER セクションに手動トークン入力欄（`TextField`、自動修正・自動大文字化
  オフ）を追加した。QR スキャンなら自動で埋まるが、手動入力もできるようにする狙い。

## Constraints / Gotchas（トークン対応）

- `pingResult` の色分けは元々 `hasPrefix("Connected")` で緑判定していたため、
  「Connected but not paired」を先にチェックして除外する条件にしないと誤って緑表示になる。
- `AppModel.client()` / `AppModel.withFailover` のフェイルオーバー候補生成でも
  `serverConfig.token` を渡し忘れると、フェイルオーバー後のホストだけ無認証リクエストに
  なってしまう点に注意。

## Decision（接続先ホストの手動選択・固定モード）

- 自動フェイルオーバーだけでは「今どの IP に繋がっているか見えない」「外出先で
  Tailscale IP を明示的に使いたい」というニーズに応えられないため、`ServerConfig` に
  `preferredHost: String?`（既定 `nil` = 自動モード）を追加した。`nil`/空文字なら
  従来どおり `host` → `fallbackHosts` の順に自動フェイルオーバー、非空なら「固定モード」
  としてそのホストのみを試し、失敗してもフェイルオーバーしない（エラーをそのまま表示）。
- 候補ホストの決定ロジックは `ConnectionCandidatePolicy.hostsToTry(primaryHost:
  fallbackHosts:preferredHost:)` という純粋関数に切り出し、`AppModel.withFailover` から
  呼ぶだけにした。ネットワークを一切使わない純粋関数なので、自動/固定の分岐は
  `ConnectionCandidatePolicyTests` で単体テストしている（`AppModelFailoverTests` 側は
  モック `URLProtocol` 越しに固定モードがフェイルオーバーしないことだけを確認）。
- `ServerConfig.activeHost`（`preferredHost` があればそれ、なければ `host`）を新設し、
  `baseURLString` はこれを使うようにした。これにより `AppModel.client()` や
  `artworkURL(for:)` など `withFailover` を経由しない単発リクエストも、固定モード時は
  自動的に `preferredHost` を向く。
- Settings に「接続先の選択」セクションを追加：現在の `activeHost` とモード表示、
  自動/固定のセグメントピッカー、`host`+`fallbackHosts` を統合した既知ホスト一覧
  （`ServerConfig.allKnownHosts`）。各行は `/v1/identity` への軽い到達確認
  （✓/✗/計測中）と Tailscale（100.64.0.0/10 帯）/LAN バッジを表示し、タップすると
  固定モードに切り替えてそのホストを `preferredHost` に設定する。
- `preferredHost` は `fallbackHosts`/`token` と同様 `Equatable` の比較対象から除外した
  （host/port が同じなら「選択中ピア」チェックマークは維持される、というこれまでの方針を
  踏襲）。Codable は他フィールドと同じく `decodeIfPresent` で旧永続化データとの後方互換を
  確保している。

### Alternatives considered

- 「固定モード時は `host` 自体を書き換える」案は採用しなかった：`preferredHost` を
  `host`/`fallbackHosts` とは独立させたほうが、自動モードに戻したときに以前の
  自動フェイルオーバー状態（`host`＝直近成功ホスト、`fallbackHosts`＝残り）をそのまま
  再利用でき、ユーザーが固定⇔自動を行き来しても情報が失われない。
