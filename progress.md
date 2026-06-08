## 2026-06-09 — UX Sync Phase 5.5 プロトコルスキーマとバージョンネゴシエーション

### 実施内容
- UX Sync protocol 定数として `ux-music-sync` / `0.2` / `2026-06-09` / capability 一覧を追加した
- `/sync/identity` が `protocolVersion`、`minCompatibleProtocolVersion`、`schemaVersion`、`capabilities`、`negotiation` を返すようにした
- `fetchSyncIdentity` が自分の protocol/schema/capabilities をヘッダで申告し、非互換 major の peer を同期操作前に拒否するようにした
- `/sync/schema` を追加し、endpoint / message / capability / 拡張規則を含む機械可読スキーマを返すようにした
- mDNS TXT に `schemaVersion` と `capabilities` を追加した
- `markdown/ux-music-sync-protocol.md` を追加し、未知フィールド・未知 capability・`extensions` の扱いを含む将来互換方針を明文化した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` をプロトコルスキーマ仕様へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-21a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-18a` に更新

### 検証
- `go test ./server -run 'TestSyncIdentityIncludesSchema|TestFetchSyncIdentitySendsProtocol|TestFetchSyncIdentityRejectsIncompatibleProtocolMajor|TestSyncSchemaEndpoint|TestSyncMDNSAdvertiseInfo' -count=1`
- `go test ./internal/uxsync -count=1`

### 判断
- 多少のバージョン差は unknown field / capability を無視して進め、major 不一致は同期操作前に止める方針を実装した。
- 今後 token と `sourceDeviceId` の対応検証を強める場合は、新しい capability と schema version で段階導入する。

## 2026-06-09 — UX Sync Phase 5.4 音源push転送

### 実施内容
- `/sync/library/import` を追加し、同期トークン認証済みの multipart アップロードを `SyncLibrary` へ取り込めるようにした
- 受信側はアップロードされたメタデータから `syncSourceDeviceId` / `syncSourceTrackId` を保存し、同じ同期元・同じ曲の重複転送を skip するようにした
- `PushSyncLibraryAssets(baseURL, limit)` を追加し、保存済み同期トークンでローカルライブラリの音源をペア済み端末へ転送できるようにした
- UX Sync 専用設定画面の `同期` タブに `1曲転送` / `全曲転送` を追加し、転送結果を転送数・既存数・失敗数と受信側保存先として表示するようにした
- renderer と Wails binding に `PushSyncLibraryAssets` を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を音源push転送の仕様へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-20a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-17a` に更新

### 検証
- `go test ./server -run 'TestSyncLibraryImport|TestPushSyncLibraryAssets' -count=1`
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- Mac mini 側から Windows 側へ能動的に音源を送り込めるため、発見・ペアリング後の同期操作が pull / push の両方向に揃った。

## 2026-06-09 — UX Sync Phase 5.3.1 ペア済み端末復元と同期操作修正

### 実施内容
- `ListSyncDevices()` を追加し、保存済み `syncAuthTokens` と `syncKnownPeers` から同期トークンを返さずペア済み端末一覧を取得できるようにした
- UX Sync 専用設定画面で mDNS discovery 結果とペア済み端末一覧をマージし、画面を閉じた後もペアリング済み状態と同期元候補を復元するようにした
- ペアリング確定後に端末一覧と同期元セレクトを更新し、到達URLを持つペア済み端末では `1曲取得` / `全曲取得` を押せるようにした
- ペア済み peer は `ペアリング済み` と表示し、再ペアリング用の接続ボタンを `接続済み` として無効化するようにした
- renderer と Wails binding に `ListSyncDevices` を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` をペア済み端末復元の仕様へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-19b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-16b` に更新

### 検証
- `go test ./server -run 'TestListSyncDevices' -count=1`
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- ペアリング情報が一時的なUI状態だけに閉じていた問題を解消し、たまに接続される端末でも保存済みペア情報から同期操作へ戻れる状態になった。

## 2026-06-08 — UX Sync Phase 5.3 音源pull GUI

### 実施内容
- UX Sync 専用設定画面の `同期` タブを有効化した
- 発見済み / 既知 peer の到達URLを同期元セレクトへ反映するようにした
- `1曲取得` ボタンから `PullSyncLibraryAssets(baseURL, 1)`、`全曲取得` ボタンから `PullSyncLibraryAssets(baseURL, 0)` を呼ぶようにした
- 音源pull結果を `downloaded` / `skipped` / `failed` と保存先パスとして表示するようにした
- `PullSyncLibraryAssets` binding が無い環境、または同期元未選択時は取得ボタンを無効化するようにした
- renderer に `normaliseSyncPullResult`、`syncPullActionState`、`formatSyncPullResultSummary` のテストを追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を音源pull GUI の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-19a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-16a` に更新

### 検証
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- SSH CLI で通した親から子への音源pullを、UX Sync 専用設定画面から操作できる第一段階に到達した。
- destructive な検証用初期化は誤操作リスクが高いため、GUI には出さず CLI 専用に残した。

## 2026-06-08 — UX Sync Phase 5.2 音源pullとSSH検証CLI

### 実施内容
- Windows 側を検証専用ノードとして扱うため、GUI / WebView2 を起動しない `--sync-reset-test-data`、`--sync-pull-one`、`--sync-pull` の CLI 入口を追加した
- `/sync/library/snapshot` を追加し、同期トークン認証済み端末へアートワーク blob を除いた曲一覧を返すようにした
- `/sync/assets/{trackId}/file` を追加し、同期トークン認証済み端末へ登録済み曲IDの原本ファイルを返すようにした
- `PullSyncLibraryAssets(baseURL, limit)` を追加し、保存済み `syncAuthTokens` を使って親から曲一覧と音源を取得し、子側 `SyncLibrary` 配下へ保存して `library.json` へ取り込むようにした
- 取り込んだ曲には `syncSourceDeviceId` / `syncSourceTrackId` / `syncImportedAt` を付与し、同じ親・同じ曲の再取り込みを避けるようにした
- `ResetSyncTestData` は `syncDeviceId` / `syncAuthTokens` / `syncKnownPeers` を温存し、検証用ライブラリ・再生回数・解析・同期イベント・アートワーク・キャッシュ・プレイリストを初期化し、`libraryPath` を `SyncLibrary` へ向け直す
- Wails binding と renderer bridge に `PullSyncLibraryAssets(baseURL, limit)` を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を音源pull MVP の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-18a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-15a` に更新

### 検証
- `go test ./server -run 'TestSyncLibrarySnapshot|TestSyncAssetFile|TestPullSyncLibraryAssets|TestResetSyncTestData' -count=1`
- Mac 側 `go test ./...`
- Mac 側 `npm test -- --run js/features/ux-sync-settings.test.ts`
- Mac 側 `npm run typecheck`
- Mac 側 `wails build -clean -nopackage`
- Mac 側で新ビルドを `open /Users/yuki/GitHub/UX-Music/build/bin/UX-Music` から起動し、`/sync/identity` が `YukinoMac-mini` を返すことを確認
- Mac 側 `/sync/library/snapshot` が Windows 側保存済み同期トークンで `200` を返し、812曲のスナップショットを返すことを確認
- Windows 側 `go test ./server -run TestSyncLibrarySnapshot^|TestSyncAssetFile^|TestPullSyncLibraryAssets^|TestResetSyncTestData -count=1`
- Windows 側 `npm run typecheck`
- Windows 側 `wails build -clean -nopackage`
- Windows 側 `C:\Users\gzabu\UX-Music-sync-test\build\bin\UX-Music.exe --sync-reset-test-data`
- Windows 側 `C:\Users\gzabu\UX-Music-sync-test\build\bin\UX-Music.exe --sync-pull-one http://192.168.0.226:8765`
- Windows 側 `SyncLibrary` に Mac mini 由来の FLAC 2曲が保存され、`library.json` の `syncSourceDeviceId` / `syncSourceTrackId` とファイルサイズを確認

### 判断
- 圧縮アセット生成は未実装だが、親 Mac mini の既存原本を子 Windows の管理ライブラリへ pull する縦串は、ローカルテストと `mainpc` への実通信検証の両方で通った。
- `--sync-pull-one` は既存取り込み済み曲を skip し、次の未取得曲を1曲 download する挙動として動作した。

## 2026-06-08 — UX Sync Phase 5.1 Windows側発見fallback

### 実施内容
- Mac 側から Windows peer は見えるが、Windows 側の mDNS discovery が空になって Mac mini を見つけられない非対称状態を調査
- `mainPC` から `http://192.168.0.226:8765/sync/identity` が応答することを確認し、HTTP 到達性ではなく discovery の問題だと切り分けた
- mDNS 広告に使う表示名から `.local` suffix を除去し、`YukinoMac-mini.local` ではなく `YukinoMac-mini` として広告するようにした
- inbound pairing confirm 成功時に、相手 `deviceId`、表示名、実通信元 IP から既知 peer を `settings.syncKnownPeers` へ保存するようにした
- `DiscoverSyncDevices(timeoutMs)` と `/sync/discover` が mDNS 結果と既知 peer をマージするようにした
- mainpc 側のビルド環境に `gcc` / `pkg-config` / portaudio header と `.pc` を用意し、Windows バイナリを再ビルドできる状態にした
- 既に古いバイナリでペアリング済みだった Windows 設定へ、Mac mini の `syncKnownPeers` を一度だけ補完した

### 検証
- Mac 側 `dns-sd -B _uxmusic-sync._tcp local` で `YukinoMac-mini` が複数 interface に広告されることを確認
- `mainPC` から `http://192.168.0.226:8765/sync/identity` が応答することを確認
- Windows 側 `npm test -- --run js/features/ux-sync-settings.test.ts`
- Windows 側 `npm run typecheck`
- Windows 側 `go test ./server -run "TestSyncPairingConfirmStoresKnownPeer|TestMergeSyncKnownPeers|TestSyncMDNSAdvertiseInfo|TestNormaliseSyncDisplayName" -count=1`
- Windows 側 `wails build -clean -nopackage`
- Windows 側 `settings.json` に `syncKnownPeers` として `YukinoMac-mini` / `http://192.168.0.226:8765` が保存されたことを確認
- Mac 側 `go test ./...`
- Mac 側 `npm test -- --run js/features/ux-sync-settings.test.ts`
- Mac 側 `npm run typecheck`

### 判断
- Windows の mDNS browse 自体は SSH 上の Go smoke で空のままだが、ペアリング済み端末は既知 peer fallback で発見一覧へ補完できる構造になった。
- SSH 経由で Windows GUI を起動すると WebView2 が `Invalid window handle` で落ちるため、更新済み `C:\Users\gzabu\UX-Music-sync-test\build\bin\UX-Music.exe` は Windows のデスクトップ側から起動して確認する。

## 2026-06-08 — UX Sync Phase 5 専用設定画面

### 実施内容
- 通常設定モーダルに混在していた UX Sync の探索・ペアリング UI を、UX Sync 専用設定画面へ切り出した
- 通常設定には `UX Sync設定を開く` の入口だけを表示するようにした
- Wails sync binding が無い renderer 単体環境では UX Sync 入口を非表示にする状態判定を追加
- UX Sync 専用設定画面の `端末` タブに探索ボタン、探索状態、peer 一覧、6桁コード確認ペアリング導線を集約した
- 後続の同期状態・保存ポリシー設定を載せるため、`同期` と `保存` のタブ枠を追加した
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を UX Sync 専用設定画面の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-17a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-14a` に更新

### 検証
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- UX Sync は通常設定の一項目ではなく、専用画面で端末・同期・保存を管理していく形へ移行した。

## 2026-06-08 — UX Sync Phase 4 ペアリングUI

### 実施内容
- Wails 向けに `StartSyncPairing(baseURL)` と `ConfirmSyncPairing(baseURL, sessionID, code, expectedRemoteDeviceID)` を追加
- `StartSyncPairing` はリモート `/sync/identity` で端末情報を取得し、ローカル `deviceId` を使って `/sync/pairing/start` を呼ぶ
- `ConfirmSyncPairing` はリモート `/sync/pairing/confirm` が返したトークンを、リモート `deviceId` 宛の同期トークンとしてローカル設定へ保存する
- ペアリング開始時の `remoteDeviceId` と確定時に再取得した `deviceId` が異なる場合は、トークンを保存せず失敗させる
- 設定画面の UX Sync peer カードに「接続」ボタンを追加し、6桁コード表示、確定、キャンセル、ペアリング済み表示まで進めるようにした
- `reachableBaseUrl` を優先し、未取得時は `host` / `hosts` と `port` からペアリング用 URL を構成する renderer ロジックを追加
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を UX Sync ペアリング UI の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-16a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-13a` に更新

### 検証
- `go test ./server -run 'TestStartSyncPairing|TestConfirmSyncPairing|TestSyncPairing' -count=1`
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm run typecheck`

### 判断
- UI 上で検出済み peer からペアリング開始・確定まで進める状態になった。
- ペア済み端末一覧と解除 UI、双方独立表示型の数値確認は後続フェーズに残す。

## 2026-06-08 — UX Sync Phase 3.1 macOS mDNS fallback

### 実施内容
- 半自動テストで `dns-sd` では `mainPC` が見える一方、Go の `grandcat/zeroconf` discovery が `mainPC` を取りこぼすことを確認
- macOS では `zeroconf` discovery と OS 標準の `dns-sd -B/-L` の結果をマージするようにした
- `dns-sd` 出力を `MDNSPeer` へ正規化し、既存の `ResolveReachablePeers` で `reachableBaseUrl` を選べるようにした
- `markdown/Task.md` と `markdown/requirement.md` を macOS mDNS fallback の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-15b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-12b` に更新

### 検証
- `dns-sd -B _uxmusic-sync._tcp local` で `mainPC` を確認
- `dns-sd -L mainPC _uxmusic-sync._tcp local` で `mainPC.local.:8765` と TXT レコードを確認
- 半自動 Go smoke で `DiscoverMDNS` → `ResolveReachablePeers` が Mac 自身と `mainPC` / `reachableBaseUrl=http://mainPC.local:8765` を返すことを確認
- `go test ./internal/uxsync`
- `go test ./...`

### 判断
- UI 側が `DiscoverSyncDevices(timeoutMs)` を呼べば、今回の fallback を通って Windows 側 `mainPC` を検出できる状態になった。

## 2026-06-08 — UX Sync Phase 3 自動発見UI

### 実施内容
- renderer に `ux-sync-settings` の peer 正規化・接続候補表示ロジックを追加
- 設定画面に UX Sync セクションと「同期端末を探す」ボタンを追加
- Wails の `DiscoverSyncDevices(timeoutMs)` から得た `reachableBaseUrl`、役割、複数 NIC の候補 `hosts` を一覧表示するようにした
- Wails binding が無い renderer 単体開発環境では UX Sync セクションを非表示にし、通常の設定画面を壊さないようにした
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を UX Sync 自動発見 UI の実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-15a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-12a` に更新

### 検証
- `npm test -- --run js/features/ux-sync-settings.test.ts`
- `npm test -- --run`
- `npm run typecheck`
- `go test ./...`
- `git diff --check`

### 判断
- UI 側の自動発見一覧表示は実装済み。発見 peer から6桁コード確認ペアリングへ進む導線と、ペア済み端末管理 UI は後続フェーズに残す。

## 2026-06-08 — UX Sync Phase 2 mDNS 自動発見基盤

### 実施内容
- `internal/uxsync` に mDNS サービス定義、TXT レコード生成、発見 peer 正規化、複数アドレス保持を追加
- `github.com/grandcat/zeroconf` を導入し、`_uxmusic-sync._tcp.local.` の広告と探索を実装
- LAN HTTP サーバー起動時に UX Sync mDNS 広告を開始し、停止時に shutdown するようにした
- Wails 向けに `DiscoverSyncDevices(timeoutMs)` を追加
- `/sync/identity` に `deviceId` / `displayName` / `roles` を含めるよう更新
- 複数NIC環境で同じ `deviceId` が複数アドレスを返す場合、`hosts` に全候補を保持するようにした
- `hosts` 候補へ `/sync/identity` を順番に probe し、到達可能な `reachableBaseUrl` を自動選択するようにした
- 末端側が IP 手入力や OS の `dns-sd` 操作をしなくても、アプリ側の mDNS 探索と自動 probe で接続候補を得られる方針にした
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を mDNS 実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-14b`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-11b` に更新

### 検証
- `go test ./internal/uxsync`
- `go test ./internal/uxsync ./server`
- 検証用サーバーを `0.0.0.0:9876` で起動し、macOS `dns-sd -B _uxmusic-sync._tcp local` で `UX Music mDNS Test` の広告を確認
- Go の `uxsync.DiscoverMDNS` で広告を発見し、`hosts` に `192.168.1.182`、`192.168.0.226`、`192.168.1.48`、Tailscale / IPv6 候補が含まれることを確認
- Go の `ResolveReachablePeers` で `reachableBaseUrl` が自動設定されることを確認
- SSH 接続した `mainpc` から `http://192.168.0.226:9876/sync/identity` が応答することを確認
- `mainpc` には `dns-sd` が無かったため、Windows 側での mDNS browse は未実施

### 判断
- mDNS 自動発見と到達可能URLの自動選択基盤は実装済み。UI 上の一覧表示と、発見 peer からペアリングへ進む導線は後続フェーズに残す。
- 複数NIC環境では代表 `host` が `mainpc` から到達不能なアドレスになる可能性があるため、後続のペアリングUIでは `reachableBaseUrl` を優先して使う。

## 2026-06-08 — UX Sync Phase 1 ペアリングと再生イベントプッシュ基盤

### 実施内容
- `internal/uxsync` を追加し、`PlayEvent` の重複排除、同時再生の別イベント採用、再生回数集計、アウトボックス ACK pruning、6桁ペアリングコード生成を実装
- `/sync/identity`、`/sync/pairing/start`、`/sync/pairing/confirm`、`/sync/library/events` を既存 LAN HTTP サーバーへ追加
- Wear 認証と Sync 認証を `lanAuthMiddleware` で分離し、Sync は `X-UX-Music-Sync-Token` / Bearer / `syncToken` を受け付けるようにした
- `sync-play-events` をイベントログとして保存し、同じ `eventId` の再送で再生回数が二重加算されない構造にした
- `Store.Save` がユーザーデータディレクトリを自動作成するようにし、一時サーバーや初回起動時の保存失敗を防いだ
- `markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を実装内容へ同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-13a`、`src/renderer/package.json` / `src/renderer/package-lock.json` を `1.0.0-Beta-10a` に更新

### 検証
- `go test ./internal/uxsync`
- `go test ./server -run 'TestSyncPairing|TestSyncAuth|TestLanAuth|TestSyncLibraryEvents' -count=1`
- `go test ./internal/store ./server ./internal/uxsync`
- `go test ./...`
- `mainpc` へ SSH 接続し、`192.168.0.226:9876` の検証用サーバーに対してペアリング開始、6桁コード confirm、認証付き `/sync/library/events` push、同一イベント再送を実行
- 実通信検証では `firstAccepted=1`、`secondAccepted=1`、`ackSequence=1` を確認し、保存された `sync-play-events` は `evt_mainpc_0001` 1件のみであることを確認

### 判断
- `mainpc` から `192.168.1.182` へは到達できなかったが、同じネットワーク上の `192.168.0.226` では到達できた。既存 `GetWearServerAddress()` は最初に見つかった非 loopback IPv4 を返すため、複数NIC環境では表示アドレス選択の改善が後続課題。
- mDNS / Bonjour、自動発見、UI、圧縮アセット、WebSocket 再生移行は後続フェーズに残す。

## 2026-06-08 — UX Music Sync 実装計画を文書化

### 実施内容
- `markdown/ux-music-sync-plan.md` を追加し、同一 LAN 上の UX Music 端末同期の実装計画を整理
- 6桁コード確認つきペアリング、`Library Host` / `Portable Client` の役割、HTTP / WebSocket の使い分け、再生イベント同期、圧縮音源キャッシュ、再生移行を計画に落とし込んだ
- `Portable Client` の再生カウントを親へプッシュするアウトボックス、たまに接続される端末向けの再送・取り込み確認、同時再生時のカウント重複排除方針を追記
- `markdown/roadmap.md`、`markdown/features.md`、`markdown/requirement.md` に UX Sync 計画への参照を追加

### 判断
- 今回は設計ドキュメント作成のみのため、実装コードとテストは追加していない
- 実装着手時はフェーズごとに `markdown/Task.md` へ完了条件を追加し、テスト先行で進める

## 2026-06-08 — TXT専用歌詞同期の音源候補選択と実ライブラリ検証

### 実施内容
- Python fallback に `UX_MUSIC_LYRICS_SYNC_AUDIO_SOURCES=full|vocals|both` を追加
- `full` ではDemucsを通さず元音源を直接 faster-whisper へ渡すようにした
- `both` では元音源候補とボーカル候補をそれぞれTXT行へ整列し、参照LRCを使わない品質スコアで候補選択するようにした
- 結果JSONへ `audioSource` / `alignmentQualityScore` / `candidateScores` を追加

### 検証
- `python/.venv/bin/python -m pytest python/tests -m 'not heavy' -q` → `30 passed, 1 deselected`
- `/Users/yuki/doc/uxmusic` 5曲ベンチ（LRC時刻は答え合わせのみ、入力は時刻なしTXT相当、`base` / `full`）:
  - アムネシア: `MAE(after_tol)=0.734s`
  - PROMINENCE: `81.670s`
  - Lone Wolf: `58.186s`
  - main heroine: `93.846s`
  - Twilight: `28.689s`
- PROMINENCE / `vocals` / `base`: `auto=23.731s`, `ja=69.775s`, `auto-ja=28.219s`
- `/opt/homebrew/bin/speech align` は実行可能だったが、アムネシアのボーカル抽出音声+簡易行復元では `MAE(after_tol)=3.395s`

### 判断
- アムネシアはfull音源ASRで0.8秒級に到達した
- PROMINENCE / Synthion系は反復ブロックとASR欠落が大きく、現行の曲全体一括ASR→後段整列では0.8秒級に届かない
- 次の本命は、セクション分割・複数候補DP・歌詞反復ブロックの構造推定

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12c` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9c` に更新

## 2026-06-08 — Python fallback Stage3の未来ドリフト修復と0.8秒級同期検証

### 実施内容
- `stage3_align` に、後半の繰り返しフレーズへ大きく吸われた行を、飛ばされたASRセグメントへ時系列順で戻す未来ドリフト修復を追加
- 繰り返しブロック末尾の延長補正を、未来ドリフト修復と単調化の後にも再適用するよう調整
- `UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS`（既定 `75.0`）と `UX_MUSIC_SYNC_FORWARD_DRIFT_MAX_ROWS`（既定 `32`）を追加
- `speech` CLI / Qwen3 Forced Aligner は導入済みのまま、今回の実装はバックエンドAPI不要のローカルPython fallback側を改善

### 検証
- `cd python && .venv/bin/python -m pytest tests/ -m 'not heavy' -v`
- `IGNORE/` 実測:
  - アムネシア / `base`: 既存ベースライン `MAE(after_tol)=0.952s`、今回の揺れ込み再測では `17.536s`
  - アムネシア / `medium`: 後段補正のみの理論再計算で `MAE(after_tol)=0.737s`、実パイプライン再推論では `2.564s`
  - PROMINENCE / `base`: `123s`級の全体ドリフトから `20.562s` まで改善したが、採用精度には未達
  - Lone_Wolf / `base`: `109s`級の全体ドリフトから `24.243s` まで改善したが、採用精度には未達

### 判断
- アムネシアでは同一ASR結果への後段補正で0.8秒級に届く条件を確認したが、Demucs / faster-whisper の再推論揺れで実パイプラインの確定値は安定しなかった
- PROMINENCE / Lone_Wolf は破綻を大幅に縮めたものの、0.8秒級には届かない
- これ以上は曲全体一括整列ではなく、チャンク化・複数候補保持・VAD/ASRアンカーによるセクション単位アラインメントが必要と判断し、今回の試行はここで切り上げ

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12b` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9b` に更新

## 2026-06-08 — macOSローカル強制アラインメント経路を追加

### 実施内容
- Swift sidecar に `Qwen3 Forced Aligner` / `speech align` 互換 CLI を優先する経路を追加
- `speech align` の単語タイムスタンプ出力を解析し、元のTXT歌詞行へ戻すマッパを実装
- `UX_MUSIC_LYRICS_SYNC_ALIGNER=auto|qwen3|off`、`UX_MUSIC_LYRICS_SYNC_ALIGNER_BIN`、`UX_MUSIC_LYRICS_SYNC_ALIGNER_MODEL` を追加
- `auto` ではローカルalignerが利用可能な場合に優先し、失敗時は既存WhisperKit経路へフォールバック
- Swift純粋ロジックのテストを追加

### 検証
- `swift test --package-path swift/lyrics-sync`
- `go test ./internal/lyricssync`
- `go test ./...`
- `npm run typecheck`（`src/renderer`）
- `npm test`（`src/renderer`）

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12a` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9a` に更新

## 2026-05-28 — レビュー指摘順のセキュリティ・再生修正

### 実施内容
- Wear API に認証トークンを導入し、LAN 上の未認証アクセスを拒否
- `/safe-media/` をライブラリ登録済み曲だけに制限し、`/safe-artwork/` と data URL アートワーク読み込みを安全な解決関数へ統一
- プレイリスト名の traversal を拒否
- ノーマライズ表示のHTMLエスケープを追加
- `profile=fast` で Swift sidecar の軽量モデル選択を尊重
- Wails build で `lyrics-sync-swift` を `.app/Contents/Resources/bin` に同梱
- Wails 再生位置でスキップ統計を記録
- AudioGraph 切替時に EQ 設定を再適用
- `/safe-media/` URL の予約文字を segment ごとにエンコード

### 検証
- `go test ./...`
- `npm test -- --run`
- `npm run typecheck`
- `swift build -c release --package-path swift/lyrics-sync`

---

## 2026-05-27 — リファクタリング G2 / R3 / R5+G6 の判定

### 実施内容
- **G2 完了**: `GetSituationPlaylists` (86 行) を 30 行に短縮
  - `pickRecentlyAdded` / `pickMostPlayed` / `pickRandomPick` を `situation_playlists.go` に切り出し
  - TDD で 8 ケースのテスト (`situation_playlists_test.go`)
  - go test ./... 全パス
- **R3 / R5 / G6 スキップ**: 実コードを精査した結果、Explore エージェントの誤検出だった
  - R3 (querySelector キャッシュ): 対象は呼び出し頻度が低い、または getElementById で O(1)
  - R5 (mtp-browser.ts コメントアウト): 実際にはコメントアウトされたコードブロックなし
  - G6 (wearPairingURLFromParts インライン化): 2 箇所利用＋専用テスト有り。インライン化は逆効果

### 選定理由・判断の根拠
- G2 は本物の責務分離: 3 つの異なるセクション (最近追加・よく聴く・ランダム) を 1 関数に詰め込んでいたため、用途別の純関数化で単体テストが書け、本体側の見通しが圧倒的に改善
- 偽陽性の 3 つは「Don't add features, refactor, or introduce abstractions beyond what the task requires」(CLAUDE.md) の原則に従って積極的にスキップ。「やらないこと」も判断
- スキャン結果は実コードでの再検証必須という教訓

### 残課題・次のステップ
- 今回着手したスキャン候補は全て決着。新規スキャンを行うかは別途判断

---

## 2026-05-27 — fix: ノーマライズ適用が反応しないバグの修正

### 実施内容
- 症状: 解析後、エラー行を外して「ノーマライズを適用」をクリックしてもボタンは押せるが何も起きない
- 原因: 過去コミット e121036 で導入した「id 不一致時に path で照合」フォールバックと、ペイロード narrow 化が、TS 移行 (92d7544) でリグレッション
- 純関数 `findNormalizeFileForResult` / `toJobFilePayload` を `normalize-lookup.ts` に新設 (8 ケースの vitest)
- `normalize-view.ts` の handler と apply 送信箇所を置換

### 選定理由・判断の根拠
- Wails の JSON ブリッジで id 型がゆらぎ `Map.get(id)` が undefined を返すと、handler 冒頭の `if (!file) return` で結果が黙って捨てられていた
- backend (`app_normalize.go`) は既に `path` をイベントに乗せているので、renderer 側で活用するだけで復旧
- 同じ理由で送信時も renderer の余分なフィールド (currentLufs, selected 等) を載せず `{id, path, gain}` に絞り、ブリッジ越しの型強制リスクを下げた

### 残課題・次のステップ
- G2 (GetSituationPlaylists 分割), R3 (querySelector キャッシュ), R5+G6 (デッドコード) に着手

---

## 2026-05-27 — リファクタリング R2: runAutoSync の責務分離

### 実施内容
- スキャン結果のうち R1 (`setupLrcEditorListeners`) はエージェントの計測誤り（実際は 60 行・13 リスナー）と判明し、スキップ
- R2 (`runAutoSync` 117 行) から純関数 2 つを抽出
  - `validateAutoSyncPrereqs`: 4 種の事前検証
  - `applyAlignedTimestamps`: 整列タイムスタンプの正規化＋代入
- 新モジュール `src/renderer/js/features/lrc-auto-sync.ts` に切り出し
- TDD: 11 ケースの vitest を Red → Green → 本体置換、tsc も通過
- 本体は 117 → 103 行 (-14 行) かつ、検証ロジックがテスト可能に

### 選定理由・判断の根拠
- lrc-editor.ts はグローバル変数 28 個と DOM 直操作の塊で全体を一気にテスト化するのは非現実的
- 「DOM/グローバルに触らない純ロジック」だけを切り出してテスト網を張る方針が現実解
- R1 は本来「26 個並列」と報告されていたが実コードを精査して虚偽と判明、 CLAUDE.md「premature abstraction を避ける」方針に従い不要と判断

### 残課題・次のステップ
- 後続候補: G2 (GetSituationPlaylists 96 行の分割), R3 (querySelector キャッシュ), R5 (デッドコード削除)
- lrc-editor.ts には他にも純粋ロジック (payload 構築, result パース) が残るので将来的に同パターンで切り出し可能

---

## 2026-05-27 — リファクタリング G1: store ヘルパー導入

### 実施内容
- 全コードベースをスキャンし、デッドコード/複雑関数/重複/パフォーマンスの観点で候補をリストアップ
- 最重要候補 G1（`store.Instance.Load` の冗長パターン）に着手
- TDD で `store.LoadSlice` / `store.LoadMap` を新設
  - Red: `internal/store/store_test.go` を追加 (6 ケース)
  - Green: `internal/store/store.go` にヘルパー 2 関数を実装
  - Refactor: server/ 14 ファイル, internal/ 2 ファイルの呼び出し側を一括置換 (-126 行)
- `go test ./...` 全パス

### 選定理由・判断の根拠
- 31 箇所で「Load → nil チェック → `interface{}` キャスト」が機械的に繰り返されていた
- スライス型 (library, analysed-queue) とマップ型 (settings, playcounts, loudness) に分かれて型付け可能
- 型付きヘルパーで呼び出し側は 1 行化し、誤って nil をデリファレンスするバグも構造的に防げる
- 代替案: ジェネリクスを使った `Load[T]` も検討したが、JSON Unmarshal 後の型は限定的で、2 関数で十分簡潔と判断

### 残課題・次のステップ
- R1: `lrc-editor.ts` の `setupLrcEditorListeners` (134 行・26 連続 addEventListener) を分割
- R2: `lrc-editor.ts` の `runAutoSync` (118 行・ネスト 4 階層) の責務分離
- 後続候補: G2 (GetSituationPlaylists 分割), G3, R3 (querySelector キャッシュ), R5 (デッドコード削除)
