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
