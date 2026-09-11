# 保存済み LAN 接続のポート復旧

## 決定

- 保存済み `ServerConfig` に、ペアリングしたデスクトップの安定した `serverDeviceId` を追加する。
- QR ペアリング後は、`POST /v1/pairing/redeem` の応答に含まれる `deviceId`（これは iPhone/TV 側のクライアント ID）を使わず、同じ接続先の `GET /v1/identity` からデスクトップ ID を取得して保存する。mDNS ペアリングでは TXT の `deviceId` を保存する。
- 保存ポートへの全ホスト試行が `URLError` になった場合だけ、既存 Bonjour の ID 一致ピアを先に使う。一致ピアがない場合は `8765...8774` を保存ポートを除いて同時探索し、ID がある構成では `/v1/identity.deviceId` の完全一致だけを受け入れる。
- 旧構成に ID がない場合は、identity が `gui` または `headless` のデスクトップ役割を報告し、保存トークンで認証済みの `/v1/remote/state` が成功した候補だけを受け入れる。
- 復旧したポートは iOS の既存 UserDefaults 保存、TV の `TVServerConfigStore` に書き戻してから元の要求を再試行する。HTTP 401/403 やその他の HTTP エラーはポート探索を開始しない。
- 同じ保存構成への同時失敗は `RemoteConnectionRecoveryCoordinator` の単一フライトにまとめ、同じ復旧結果を共有する。復旧候補が見つからなかった場合はキーごとに30秒の負のクールダウンを設け、オフライン中の artwork/lyrics などの要求が Bonjour 待ちとポート総当たりを繰り返さないようにする。

## 実装範囲

- iOS と tvOS の保存済みデスクトップ要求は `RemoteConnectionResolver` の共通 failover を使う。tvOS は接続画面を生成する前に状態取得を行うため、画面内の長寿命 API クライアントにも復旧ポートが反映される。
- tvOS 固有の `UXTV_RELAY_PORT` / `UXTV_LIVE_PORT` はデスクトップ接続とは無関係なので変更しない。
- watchOS 側にはデスクトップへの直接 `RemoteAPIClient` / `ServerConfig` 接続経路がなく、`WatchConnectivity` で iPhone から転送を受ける構成だった。したがって watchOS 専用のポート探索は追加せず、デスクトップ要求を行う iPhone 側で復旧する。

## 制約 / 注意点

- 候補ポートは `AppConstants.serverPortCandidates` に集約し、デスクトップ側のポート定数を複製しない。
- identity は認証不要の公開 endpoint なので、ID を持つ構成では保存トークンだけでは候補を信頼せず、必ずデスクトップ ID を照合する。
- 復旧キーは保存された `serverDeviceId` を優先し、legacy 構成では試行ホスト列・保存ポート・トークンの SHA-256 を組み合わせる。時計はコーディネータの初期化時に注入でき、クールダウンの期限テストを決定的にする。
