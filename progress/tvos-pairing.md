# tvOS 発見・ペアリング（Phase 1-2）

`markdown/appletv-servermode-plan.md` Phase 1-2（TV は QR を読めないため mDNS 発見 + 既存
デスクトップ間 6 桁コードフローを流用）の実装記録。

## Decision

- **trust model の実地調査結果**: `server/app_pairing.go` の `POST /v1/pairing/start` は、
  呼び出し元に 6 桁コードを直接レスポンスで返す。`POST /v1/pairing/confirm` は同じ
  `sessionId`/`code` を知っている者なら誰でも呼べ、ホスト側の人間による個別承認ステップは
  実装上**存在しない**。デスクトップ設定画面（`src/renderer/js/utils/init-settings.ts` の
  `renderUxSyncPairingStart`/`renderUxSyncPairingConfirm`）も、開始と確定を同一 UI・同一操作者が
  連続して行っており、画面上のコード表示は「もう一方の画面のコードと目視で一致するか確認する」
  ためのものであって、別デバイスでの承認ゲートではない。認証境界は「LAN 上でホストの
  `/v1/pairing/*`（公開・認証不要）に到達できること」自体である（`progress/lan-api-v1.md` の
  「identity と pairing のみ公開」方針どおり）。
- 上記の実地確認により、計画書 1-2 が想定していた「TV がコードを表示 → ユーザーが Host の
  GUI で承認」という**別デバイスでの人手承認ステップは既存コードのどこにも存在しない**と判明。
  そのため「既存フローがそのまま使えるなら流用する」という指示に従い、**サーバー側の追加実装は
  一切行わず**、TV も同じ start→confirm を自動連続実行する形で実装した:
  1. TV が選んだ Host へ `POST /v1/pairing/start`（`deviceId`/`displayName` は
     `DeviceIdentity` を流用）。
  2. 返ってきた 6 桁コードを大画面に表示（`TVPairingCodeView`）。
  3. 表示と同時に同じコードで `POST /v1/pairing/confirm` を自動発行し、トークンを取得・保存。
  - 結果として「Host の GUI を開いておく」運用は不要になった（計画の Phase 1 許容事項より
    さらに単純化）。将来、真の人手承認ゲートが必要になった場合は `syncPairingSessions` に
    「承認待ち」ステータスを追加し、Host 側に承認 API を新設するのが妥当（今回はスコープ外）。
- **discovery**: 既存 `LANDiscoveryService`（`_uxmusic-sync._tcp`）をそのまま TV ターゲットで
  利用（Phase 1-1 で共有済み）。ホスト一覧から選択して `TVAppModel.pair(with:)` を呼ぶ。
- **状態機械**: `TVPairingReducer`（`UX-Music-TV/TVPairing.swift`）に純粋な reducer として
  切り出し、ネットワークなしでテスト可能にした。`idle → starting → awaitingConfirmation →
  confirming → paired / failed` の一方向遷移。
- **トークン永続化**: iOS 版と同じ仕組み（`ServerConfig` を `JSONEncoder` で
  `UserDefaults` に `AppConstants.serverConfigKey` として保存）をそのまま流用する
  `TVServerConfigStore` を新設。TV アプリは iOS と別 bundle id のため `UserDefaults.standard`
  は端末上で自動的に分離されており、キー名の衝突は起きない。テストでは実 `UserDefaults.standard`
  を汚さないよう、名前付きスイートを注入する。
- **`TVAppModel`**: iOS の `AppModel` を丸ごと流用せず、TV の発見・ペアリング画面が必要とする
  状態のみを持つ軽量な `ObservableObject` として新設（計画書の指示どおり）。
  `TVPairingClient` プロトコルでネットワーク呼び出しをシームにし、テストではスタブに差し替え。

## Alternatives considered

- **Host 側に TV 専用の承認 API を新設する**（計画書が本来想定していた形）: 実地調査の結果、
  デスクトップ間フローにも承認ゲートが存在しないことが分かったため、TV だけに非対称な
  安全策を追加する理由がなくなった。Phase 3 で Mobile 経由の承認 UI を検討する際に、
  その時点の要件に応じて `syncPairingSessions` を拡張する形で再検討する。
- **QR 用 `pairing/redeem` フロー（secret 事前生成）を TV にも使う**: secret は Host の GUI が
  開いている間しか有効な QR を出さない設計であり、そもそも TV は QR を読めないため不採用
  （計画書の前提どおり）。

## Constraints / Gotchas

- 6 桁コードの画面表示は現状「セキュリティ境界」ではなく「目視確認用の UX」に留まる。
  LAN に参加できる端末なら誰でも `/v1/pairing/start` を叩いてコードを得られるため、真の
  不正ペアリング対策は「LAN 自体を信頼境界とする」という `lan-api-v1.md` の既定方針に
  委ねられている。
- `TVAppModel`/`TVPairingReducer`/`TVServerConfigStore`/`TVPairingCodeView` 等は
  `UX-Music-Mobile.xcodeproj`（`objectVersion = 63`・同期グループ未使用）に手動登録が必要。
  今回追加した 7 ファイル（`UX-Music-TV/` 4・`UX-Music-TVTests/` 3）はすべて
  `PBXFileReference`/`PBXBuildFile`/グループ/`PBXSourcesBuildPhase` に手動追加済み。
- サーバー側 (`server/`) の変更は行っていない。`go build`/`go test` の実行は不要（差分なし）。

## ビルド/テスト結果

- `xcodebuild -project UX-Music-Mobile.xcodeproj -scheme UX-Music-TV -destination
  'platform=tvOS Simulator,name=Apple TV' test` → **TEST SUCCEEDED**
  （`TVPairingReducerTests` 7件・`TVServerConfigStoreTests` 3件・
  `TVAppModelPairingFlowTests` 4件・既存 `MusicPlayerServicePlaybackSpikeTests` 1件、全PASS）。
- `xcodebuild -project UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -destination
  'platform=iOS Simulator,name=iPhone 17' build` → **BUILD SUCCEEDED**（既存 iOS ターゲットに
  リグレッションなし）。
