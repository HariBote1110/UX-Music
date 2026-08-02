# UX-Music-Mobile: LAN API v1 追従

## Decision

- `progress/lan-api-v1.md` のサーバー側改修（`/wear/*` → `/v1/remote/*`・`/v1/pairing/*`・
  `/v1/identity`、Bearer トークン、JSON エラー形式）に Swift 側を追従させた。
- 「wear」命名を Swift 側から全廃：
  `WearAPIClient` → `RemoteAPIClient`、`WearDiscoveryService`/`WearDiscoveryPeer` →
  `LANDiscoveryService`/`LANDiscoveryPeer`、`WearConnectionResolver` →
  `RemoteConnectionResolver`、`WearDownloadError` → `RemoteAPIError`、
  `WearDefaultArtwork` → `RemoteDefaultArtwork`（Assets.xcassets の imageset も改名）。
  ファイル名・Xcode プロジェクト参照（手動登録の project.pbxproj）・テストファイルも追従。
- 認証は `Authorization: Bearer <token>` に一本化。`file`/`artwork` などヘッダを付けられない
  メディア GET のみ `?token=` クエリを許可（サーバー仕様と一致）。
- ペアリングは QR 生トークン埋め込みを廃止し、`uxmusic://pair?host=&port=&secret=` →
  `POST /v1/pairing/redeem` でデバイス別トークンに交換する方式に変更。
  - `ServerConfig.pairingRequest(fromPairingURL:)` が `PairingRequest{host,port,secret}` を返す
    （旧 `fromPairingURL` は `ServerConfig` を直接返していたが、secret は token とは別の一時値
    なので分離した）。
  - `DeviceIdentity`（`Core/DeviceIdentity.swift`）を新設。`deviceId` は
    `UIDevice.identifierForVendor`（無ければ生成 UUID を `UserDefaults` に永続化）、
    `displayName` は `UIDevice.current.name`。
  - `AppModel.redeemPairing(host:port:secret:)` が redeem を実行し、成功時に
    `serverConfig` へトークンを保存、失敗時は `pairingError` にメッセージを格納。
    `applyPairingURL` は QR スキャン/deep link 用の薄いラッパーとして非同期化。
  - Settings 画面の手入力欄はトークンではなく「ペアリングコード（secret）」入力欄に変更し、
    Save/Test 押下時に redeem する（既に有効なトークンがあれば secret 欄が空のまま
    host/port だけの更新も可）。

## Alternatives considered

- `/v1/remote/artwork/{id}` のパス形式（仕様書の対応表どおり）ではなく、従来どおり
  `?id=` クエリ形式を維持した。サーバー実装 (`server/app_remote.go` の
  `remoteArtworkHandler`/`remoteFileHandler`) がクエリ優先でパスにもフォールバックする
  実装になっており、ID にスラッシュを含む旧来の path 由来キーとの相性を考えるとクエリ形式の
  方が安全なため。artwork/file のいずれも `?id=` を使用する。
- `http(s)://…?token=` 形式のペアリング URL パースは廃止（新方式では secret のみを
  `uxmusic://pair` スキームで配布するため）。

## Constraints / Gotchas

- `RemoteAPIError` は `.httpStatus(Int)` と `.server(code:message:)` の2ケース。
  サーバーは非2xxで常に `{"error":{...}}` JSON を返すため実運用では `.server` が主に飛ぶが、
  JSON デコードに失敗した場合のフォールバックとして `.httpStatus` を残している。
  401 判定は両ケースを catch する必要がある（`RemoteConnectionResolver.checkAuthorised` 参照）。
- `UX-Music-Wear/` サブプロジェクトは対象外（今後 Mobile へ統合予定のため touch していない）。
