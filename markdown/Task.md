# Task: UX Sync Phase 5.11 - 自動音源差分同期と接続トースト

## 概要
UX Sync をさらに「接続できたら自然に同期される」挙動へ近づける。Walkman 転送で使っている未転送判定の考え方を流用し、Library Host から音源本体を自動取得する際も、既に `syncSourceDeviceId` / `syncSourceTrackId` 付きで取り込み済みかつ実ファイルが存在する曲は転送しない。また、自動同期が走ったことを右下トーストで分かるようにする。

## 完了条件
- [ ] `AutoSyncPairedDevices()` が `LibraryHost` のペア済み端末から未取得曲だけを pull し、既存曲は skip として数えるテストがあること。
- [ ] `LibraryHost` ではない peer からは音源本体の自動 pull を行わないこと。
- [ ] renderer が `ux-sync-auto-result` を受け取り、接続できたため同期したこと、取得数、既存数、再生回数、ジャケット数を右下トーストに表示できること。

# Task: UX Sync Phase 5.10 - Crescent向けSSH自動同期CLI

## 概要
HariBote（便宜上 Crescent）を検証用 Windows ノードとして使い、SSH から GUI を起動せずにペアリングと接続時自動同期を実行できる導線を追加する。Crescent は普段手元で操作しない検証ノードとして扱うため、初期化、ペアリング、自動同期ワンショットを CLI で完結できることを重視する。

## 完了条件
- [x] `--sync-pair <baseURL>` が6桁コード確認フローを使ってペアリングし、同期トークンと既知 peer の到達URLを保存するテストがあること。
- [x] `--sync-auto-once` が保存済みペア端末に対して `AutoSyncPairedDevices()` を一回実行し、SSH から JSON 結果を確認できるテストがあること。
- [x] Crescent 上で Windows バイナリをビルドし、Mac mini とのペアリングと自動同期ワンショットを実通信で検証できること。

# Task: UX Sync Phase 5.9 - 空き容量安全停止

## 概要
UX Sync の自動同期や音源取得・受信で、保存先ボリュームの空き容量がユーザー指定の最低容量を下回る場合に同期を停止する。母艦と持ち運び端末で容量差が大きい前提のため、容量事故を防ぐ安全弁として扱う。

## 完了条件
- [x] `settings.syncMinFreeSpaceGB` が正の値の場合、`AutoSyncPairedDevices()` が peer 接続前に空き容量を確認し、閾値未満なら `paused` で停止するテストがあること。
- [x] `PullSyncLibraryAssets()` と `/sync/library/import` が同じ空き容量安全停止を通ること。
- [x] UX Sync 専用設定画面の `保存` タブから最低空き容量を GB 単位で保存できること。
- [x] protocol capability に `library.storage-safety.v1` が追加されていること。

# Task: UX Sync Phase 5.8 - ジャケットの自動補完同期

## 概要
UX Sync を「接続できたら同期」に寄せる対象として、再生回数に続きジャケット画像を扱う。音源本体を勝手に大量転送せず、既に同期済みの曲で欠けているジャケットを、ペア済み端末へ接続できた時に軽量補完する。

## 完了条件
- [x] `/sync/assets/{trackId}/artwork` が同期トークン付きで保存済みジャケットを返すテストがあること。
- [x] `AutoSyncPairedDevices()` がペア済み端末から同期済み曲の不足ジャケットを取得し、`Artworks` と `library.json` に反映するテストがあること。
- [x] `/sync/library/snapshot` は巨大な `artwork` blob を直接載せず、`syncArtwork` 参照だけを返すこと。
- [x] multipart import / push で任意の `artwork` part を扱い、受信側の `artwork.full` に安全なファイル名を保存できること。
- [x] protocol capability に `library.artwork.v1` が追加されていること。

# Task: UX Sync Phase 5.7 - 再生回数の自動同期

## 概要
UX Sync を手動push中心から、ペア済み端末へ接続できた時に同期される形へ寄せる。第一段階として、ローカル再生回数を `PlayEvent` として保存し、到達可能なペア済み端末へ自動pushし、受信側は既存 `playcounts` へ冪等に反映する。

## 完了条件
- [x] `IncrementPlayCount` がローカル `sync-play-events` に再生イベントを記録するテストがあること。
- [x] `/sync/library/events` が受信イベントを `playcounts` へ反映し、同じイベント再送では二重加算しないテストがあること。
- [x] `AutoSyncPairedDevices()` が保存済みペア端末へローカル再生イベントを同期トークン付きでpushするテストがあること。
- [x] アプリ起動後に軽量な自動同期ループが開始されること。
- [x] protocol capability に `library.auto-sync.v1` が追加されていること。

# Task: UX Sync Phase 5.6 - 転送進捗表示とMP3 320kbps転送

## 概要
UX Sync の音源転送中に、現在処理しているファイル名、件数、転送量、転送速度を UI へ表示する。加えて、FLAC などのロスレス音源を portable client へ送る際に MP3 320kbps へ変換してから push 転送できるようにする。

## 完了条件
- [x] `PushSyncLibraryAssetsWithOptions(baseURL, limit, { encodingMode: "mp3_320" })` が MP3 320kbps 変換後のファイルと metadata を送るテストがあること。
- [x] MP3 320kbps 転送は一時ファイル生成完了を待たず、エンコード出力を multipart upload へストリーミングするテストがあること。
- [x] push 転送中に `ux-sync-transfer-progress` event としてファイル名、件数、byte数、速度を通知するテストがあること。
- [x] renderer に転送進捗 payload の正規化と、速度・変換モードを含む表示文言のテストがあること。
- [x] UX Sync 専用設定画面の `同期` タブから、原本転送と MP3 320kbps 転送を選べること。
- [x] `markdown/ux-music-sync-protocol.md` に `library.transfer-progress.v1` と `library.transcode.mp3-320.v1` が記載されていること。

# Task: UX Sync Phase 5.5 - プロトコルスキーマとバージョンネゴシエーション

## 概要
UX Sync の HTTP / mDNS プロトコルに、機械可読なスキーマ公開、capability 宣言、バージョン自己申告、互換性ネゴシエーションを追加する。将来フィールドが増えても未知フィールドを無視し、多少のバージョン差があっても capability ベースで安全に接続判断できる構造へ寄せる。

## 完了条件
- [x] `/sync/identity` が `protocolVersion`、`minCompatibleProtocolVersion`、`schemaVersion`、`capabilities`、`negotiation` を返すテストがあること。
- [x] `fetchSyncIdentity` が自分の protocol/schema/capabilities をヘッダで申告し、非互換 major の peer を拒否するテストがあること。
- [x] `/sync/schema` が拡張規則、message、endpoint、capability を含む機械可読スキーマを返すテストがあること。
- [x] mDNS TXT に `schemaVersion` と `capabilities` が含まれること。
- [x] `markdown/ux-music-sync-protocol.md` にプロトコルスキーマと拡張規則が記載されていること。
- [x] `go test ./server -run 'TestSyncIdentityIncludesSchema|TestFetchSyncIdentitySendsProtocol|TestFetchSyncIdentityRejectsIncompatibleProtocolMajor|TestSyncSchemaEndpoint|TestSyncMDNSAdvertiseInfo' -count=1` と `go test ./internal/uxsync -count=1` が通ること。
- [x] Windows 向け Wails build が MTP build tag 衝突で失敗しないこと。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-21b` に更新されていること。

# Task: UX Sync Phase 5.4 - 音源push転送

## 概要
UX Sync の音源同期を「相手から取得」だけでなく「こちらから相手へ転送」できるようにする。ペア済み端末へ認証付き multipart で音源とメタデータを送信し、受信側は `SyncLibrary` へ保存して `library.json` に同期元情報付きで取り込む。

## 完了条件
- [x] `/sync/library/import` が同期トークンを要求し、アップロードされた音源を `SyncLibrary` へ取り込むテストがあること。
- [x] `PushSyncLibraryAssets(baseURL, limit)` が保存済み同期トークンでペア済み端末へローカル音源を転送するテストがあること。
- [x] renderer に転送結果の正規化、操作可否、結果サマリのテストがあること。
- [x] UX Sync 専用設定画面の `同期` タブに `1曲転送` / `全曲転送` があり、選択中の相手端末へ転送できること。
- [x] 転送完了後に、転送数・既存数・失敗数と受信側保存先パスを画面へ表示すること。
- [x] `PushSyncLibraryAssets` binding が無い環境、または相手端末未選択の状態では転送ボタンが無効になること。
- [x] `npm test -- --run js/features/ux-sync-settings.test.ts`、`npm run typecheck`、`go test ./server -run 'TestSyncLibraryImport|TestPushSyncLibraryAssets' -count=1` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-20a` に更新されていること。

# Task: UX Sync Phase 5.3.1 - ペア済み端末復元と同期操作修正

## 概要
UX Sync 専用設定画面を閉じてもペアリング済み端末の接続状態が失われず、`同期` タブから保存済みペア端末を同期元として選択して音源pullを実行できるようにする。

## 完了条件
- [x] 保存済み `syncAuthTokens` / `syncKnownPeers` から、同期トークンを漏らさずペア済み端末一覧を返すテストがあること。
- [x] renderer にペア済み端末一覧の正規化、発見 peer とのマージ、ペアリング済み表示のテストがあること。
- [x] `ListSyncDevices()` が Wails binding と bridge から呼べること。
- [x] UX Sync 専用設定画面を開き直しても、保存済みペア端末が `端末` タブと `同期` タブに復元されること。
- [x] ペアリング確定後に端末一覧と同期元セレクトが更新され、到達URLを持つペア済み端末では取得ボタンが有効になること。
- [x] `npm test -- --run js/features/ux-sync-settings.test.ts`、`npm run typecheck`、`go test ./server -run 'TestListSyncDevices' -count=1` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-19b` に更新されていること。

# Task: UX Sync Phase 5.3 - 音源pull GUI

## 概要
SSH CLI で通した Mac mini から Windows への音源pullを、UX Sync 専用設定画面の `同期` タブから実行できるようにする。発見済み / 既知 peer の到達URLを同期元として選択し、1曲取得または全曲取得を GUI から開始して結果を確認できるようにする。

## 完了条件
- [x] renderer に音源pull結果の正規化、操作可否、結果サマリのテストがあること。
- [x] UX Sync 専用設定画面の `同期` タブが有効で、同期元 peer を選択できること。
- [x] `1曲取得` が `PullSyncLibraryAssets(baseURL, 1)` を呼び、`全曲取得` が `PullSyncLibraryAssets(baseURL, 0)` を呼ぶこと。
- [x] 音源pull完了後に、取得数・既存数・失敗数と保存先パスを画面へ表示すること。
- [x] `PullSyncLibraryAssets` binding が無い環境、または同期元未選択の状態では取得ボタンが無効になること。
- [x] `npm test -- --run js/features/ux-sync-settings.test.ts` と `npm run typecheck` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-19a` に更新されていること。

# Task: UX Sync Phase 5.2 - 音源pullとSSH検証CLI

## 概要
Windows 側を検証専用ノードとして SSH から扱いやすくし、GUI / WebView2 起動に頼らず UX Sync のテストデータ初期化と Mac mini からの音源pullを実行できるようにする。音源転送の MVP として、親側の既存ライブラリ原本を同期専用 HTTP API で返し、子側はアプリ管理下の `SyncLibrary` に保存して `library.json` へ取り込む。

## 完了条件
- [x] `/sync/library/snapshot` が同期トークンを要求し、アートワーク blob を除いた曲一覧を返すテストがあること。
- [x] `/sync/assets/{trackId}/file` が同期トークンを要求し、登録済み曲IDの原本ファイルだけを返すテストがあること。
- [x] `PullSyncLibraryAssets(baseURL, limit)` が保存済み同期トークンで親から曲一覧と音源を取得し、子側 `SyncLibrary` 配下へ保存して `library.json` に `syncSourceDeviceId` / `syncSourceTrackId` 付きで取り込むこと。
- [x] `--sync-reset-test-data` が `syncAuthTokens` / `syncKnownPeers` / `syncDeviceId` を温存しつつ、検証用のライブラリ・再生回数・解析・同期イベント・アートワーク・キャッシュ・プレイリストを初期化すること。
- [x] `--sync-pull-one` / `--sync-pull` で SSH 経由でも GUI を起動せず音源pullを実行できること。
- [x] Windows 側バイナリを更新し、`mainpc` から `--sync-reset-test-data` と `--sync-pull-one http://192.168.0.226:8765` の実通信検証が成功すること。
- [x] `go test ./server -run 'TestSyncLibrarySnapshot|TestSyncAssetFile|TestPullSyncLibraryAssets|TestResetSyncTestData' -count=1` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-18a` に更新されていること。

# Task: UX Sync Phase 5.1 - Windows側発見fallback

## 概要
Windows 側で mDNS discovery が空になり、Mac mini が見えないケースを補正する。Mac 側広告名から `.local` suffix を除去し、さらに mDNS が取れない環境でも、ペアリング時に実通信してきた相手の IP を既知 peer として保存し、発見一覧へ混ぜる。

## 完了条件
- [x] mDNS 広告に使う表示名から `.local` suffix を除去するテストがあること。
- [x] inbound pairing の `/sync/pairing/start` で受け取った相手 `deviceId` / `displayName` / remote address を、confirm 成功後に既知 peer として保存するテストがあること。
- [x] `DiscoverSyncDevices(timeoutMs)` と `/sync/discover` が mDNS 結果と既知 peer をマージすること。
- [x] Mac 側 `dns-sd -B _uxmusic-sync._tcp local` で `YukinoMac-mini` が広告されること。
- [x] `mainPC` から `http://192.168.0.226:8765/sync/identity` が応答すること。
- [x] Windows ビルド用に CGO / gcc / pkg-config / portaudio header を整え、`wails build -clean -nopackage` が成功すること。
- [x] `go test ./...`、`npm test -- --run js/features/ux-sync-settings.test.ts`、`npm run typecheck` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-17b` に更新されていること。

# Task: UX Sync Phase 5 - 専用設定画面

## 概要
通常の設定モーダルに混在していた UX Sync の探索・ペアリング UI を、UX Sync 専用設定画面へ切り出す。通常設定には入口だけを置き、専用画面側に端末検出、peer 一覧、6桁コード確認ペアリングを集約する。

## 完了条件
- [x] renderer に UX Sync 専用設定入口の表示条件テストがあること。
- [x] 通常設定には `UX Sync設定を開く` の入口だけが表示されること。
- [x] Wails sync binding が無い環境では通常設定の UX Sync 入口が非表示になること。
- [x] UX Sync 専用設定画面に端末タブ、探索ボタン、探索状態、peer 一覧、既存のペアリング導線があること。
- [x] `npm test -- --run js/features/ux-sync-settings.test.ts` と `npm run typecheck` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-17a` に更新されていること。

# Task: UX Sync Phase 4 - ペアリングUI

## 概要
設定画面の UX Sync 自動発見一覧から、発見済み端末へ6桁コード確認ペアリングを開始・確定できるようにする。Wails からリモート端末の `/sync/identity`、`/sync/pairing/start`、`/sync/pairing/confirm` を呼び、確定時にリモート端末が発行した同期トークンをローカル設定へ保存する。

## 完了条件
- [x] Wails 向けに `StartSyncPairing(baseURL)` と `ConfirmSyncPairing(baseURL, sessionID, code, expectedRemoteDeviceID)` があること。
- [x] `StartSyncPairing` がローカル `deviceId` を使ってリモート `/sync/pairing/start` を呼び、リモート端末名・端末ID・6桁コードを返すこと。
- [x] `ConfirmSyncPairing` がリモート `/sync/pairing/confirm` のトークンを、リモート `deviceId` 宛の同期トークンとして保存すること。
- [x] `ConfirmSyncPairing` が開始時のリモート `deviceId` と確定時のリモート `deviceId` の不一致を拒否すること。
- [x] renderer にペアリング開始・確定応答の正規化と、到達可能URL選択のテストがあること。
- [x] 設定画面の UX Sync peer カードから「接続」→6桁コード表示→「確定」まで進めること。
- [x] `go test ./server -run 'TestStartSyncPairing|TestConfirmSyncPairing|TestSyncPairing' -count=1`、`npm test -- --run js/features/ux-sync-settings.test.ts`、`npm run typecheck` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-16a` に更新されていること。

# Task: UX Sync Phase 3.1 - macOS mDNS fallback

## 概要
複数 VLAN / 複数 NIC の Mac で、OS の `dns-sd` では Windows 側 `mainPC` の `_uxmusic-sync._tcp.local` が見える一方、Go の `grandcat/zeroconf` discovery が一部 peer を取りこぼすケースを補正する。macOS では `zeroconf` の結果と `dns-sd -B/-L` の結果をマージし、既存 UI が同じ `DiscoverSyncDevices(timeoutMs)` から peer を得られるようにする。

## 完了条件
- [x] `dns-sd -B` の browse 出力から UX Sync instance を抽出するテストがあること。
- [x] `dns-sd -L` の resolve 出力から `deviceId`、`displayName`、`hostName`、`port`、`roles` を持つ `MDNSPeer` を復元するテストがあること。
- [x] macOS では `zeroconf` discovery と `dns-sd` fallback の結果をマージすること。
- [x] 半自動テストで `mainPC` が `reachableBaseUrl=http://mainPC.local:8765` として発見できること。
- [x] `go test ./internal/uxsync` と `go test ./...` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-15b` に更新されていること。

# Task: UX Sync Phase 3 - 自動発見UI

## 概要
設定画面から同一 LAN 上の UX Music 端末を探索し、複数 NIC 環境でも到達可能 URL と候補アドレスを確認できる UI を追加する。Wails binding が無い renderer 単体開発環境では UX Sync セクションを非表示にし、末端側の特別な操作なしで自動発見の結果を見られるようにする。

## 完了条件
- [x] renderer に発見 peer の正規化と接続候補表示のテストがあること。
- [x] 設定画面に UX Sync セクションと「同期端末を探す」ボタンがあること。
- [x] `DiscoverSyncDevices(timeoutMs)` の結果から `reachableBaseUrl`、役割、複数 `hosts` 候補を表示できること。
- [x] Wails binding が無い環境では UX Sync セクションが非表示になり、通常の設定画面を壊さないこと。
- [x] `npm test -- --run js/features/ux-sync-settings.test.ts` と `npm run typecheck` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-15a` に更新されていること。

# Task: UX Sync Phase 2 - mDNS 自動発見基盤

## 概要
同一 LAN 上の UX Music 端末を自動発見できるよう、`_uxmusic-sync._tcp.local.` の mDNS / Bonjour 広告と探索を実装する。複数 NIC 環境では代表アドレスだけに依存せず、発見した peer に複数の到達候補アドレスを保持する。

## 完了条件
- [x] `internal/uxsync` に mDNS サービス種別、TXT レコード生成、発見 peer 正規化のテストがあること。
- [x] `github.com/grandcat/zeroconf` を使い、UX Sync mDNS 広告と探索を実装していること。
- [x] LAN HTTP サーバー起動時に `_uxmusic-sync._tcp.local.` を広告すること。
- [x] Wails から呼べる `DiscoverSyncDevices(timeoutMs)` があり、ローカルUIから mDNS 探索を実行できること。
- [x] 複数 NIC で同じ deviceId の広告が複数アドレスを返す場合、`hosts` に全候補を保持すること。
- [x] macOS の `dns-sd -B _uxmusic-sync._tcp local` で広告を確認すること。
- [x] Go の `uxsync.DiscoverMDNS` で広告を発見し、`hosts` に `192.168.0.226` など複数アドレス候補が含まれることを確認すること。
- [x] 発見 peer の `hosts` 候補へ `/sync/identity` を順番に probe し、到達可能な `reachableBaseUrl` を自動選択できること。
- [x] 末端側は IP 手入力や OS の `dns-sd` などを使わず、アプリ側の mDNS 探索と自動 probe だけで接続候補を得られること。
- [x] `go test ./internal/uxsync ./server` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-14b` に更新されていること。

# Task: UX Sync Phase 1 - ペアリングと再生イベントプッシュ基盤

## 概要
同一 LAN 上の PC 間同期に向けて、6桁コード確認ペアリング、同期専用トークン認証、子側再生イベントの親側プッシュ、同じイベント再送時の冪等マージを実装する。MacBook Air / mainpc のようにたまにしか接続されない端末を想定し、既存 `playcounts` へ直接加算せず、`sync-play-events` のイベントログを同期の Single Source of Truth とする。

## 完了条件
- [x] `internal/uxsync` に `PlayEvent`、イベント重複排除、同時再生の別イベント採用、再生回数集計、アウトボックス ACK pruning の純粋ロジックがあること。
- [x] 6桁のペアリングコード生成と期限付きペアリングセッションのテストがあること。
- [x] `/sync/pairing/start` と `/sync/pairing/confirm` が6桁コード確認フローを提供し、同期専用トークンを発行できること。
- [x] `/sync/library/events` が同期専用トークンを要求し、子側再生イベントを `sync-play-events` へ冪等保存できること。
- [x] Wear 認証と Sync 認証が別 middleware として分離されていること。
- [x] `mainpc` から SSH 経由で、ペアリング開始、confirm、認証付きイベント push、同一イベント再送の実通信検証を行うこと。
- [x] `go test ./...` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-13a` に更新されていること。

# Task: TXT専用歌詞同期の音源候補選択と実ライブラリ検証

## 概要
同期済みLRCを実装入力に使わず、時刻なしTXT歌詞だけを音源へ合わせる用途に寄せて、Python fallbackで元音源ASR / ボーカル分離ASRの候補を試し、参照LRCなしの品質スコアで候補選択できるようにする。`/Users/yuki/doc/uxmusic` と `/Users/yuki/Library/Application Support/UX-Music/Lyrics` の実データは、LRCから時刻を捨てたTXT相当入力と参照時刻によるベンチマークにのみ使う。

## 完了条件
- [x] Python fallback が `UX_MUSIC_LYRICS_SYNC_AUDIO_SOURCES=full|vocals|both` を解釈できること。
- [x] `full` ではDemucsを通らず元音源をASRへ渡せること。
- [x] `both` では元音源候補とボーカル候補を評価し、参照LRCを使わない品質スコアで返却候補を選べること。
- [x] `python/tests -m "not heavy"` が通ること。
- [x] `/Users/yuki/doc/uxmusic` の5曲で、LRC時刻を答え合わせ専用にしたTXT入力ベンチを実施し、0.8秒級に届いた曲と届かなかった曲を記録すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-12c` に更新されていること。

# Task: Python fallback Stage3の未来ドリフト修復と0.8秒級同期の検証

## 概要
ローカル完結の自動歌詞同期について、`IGNORE/` の参照セットで0.8秒級まで誤差を減らせるか試行し、Python fallback Stage3で後半の繰り返しフレーズへ吸われる未来ドリフトを修復する。

## 完了条件
- [x] Stage3が大きく未来へ飛んだ場合、時系列上で飛ばされたASRセグメントへ戻す修復テストが追加されていること。
- [x] Stage3がASRセグメントを使った未来ドリフト修復を実装していること。
- [x] 繰り返しブロック末尾の延長補正が単調化後にも再適用されること。
- [x] `IGNORE/` のアムネシア・PROMINENCE・Lone_Wolfで実測し、0.8秒級に届いた条件と届かなかった条件を記録していること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-12b` に更新されていること。

# Task: macOSローカル強制アラインメントによる自動歌詞同期

## 概要
バックエンドAPI課金を避け、macOSローカル環境で既存歌詞を音源へ高精度に同期できるよう、Swift sidecar に Qwen3 Forced Aligner / `speech` CLI 優先経路を追加する。

## 完了条件
- [x] Swift sidecar が `speech align` 互換 CLI を検出できる場合、WhisperKit ASR より先に既存歌詞の強制アラインメントを実行すること。
- [x] `speech align` の単語タイムスタンプ出力を元の歌詞行へ戻し、`AlignedLine` として既存 JSON 契約で返せること。
- [x] `auto` では aligner 失敗時に WhisperKit へフォールバックし、`UX_MUSIC_LYRICS_SYNC_ALIGNER=qwen3|off` で明示制御できること。
- [x] 純粋ロジックの Swift テストが追加され、`swift test --package-path swift/lyrics-sync` が通ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.ts` のバージョンが `0.1.9-Beta-12a` に更新されていること。

# Task: Gitコンフリクトの解消とバージョン更新

## 概要
gitのコンフリクト（手動で残されたマーカーを含む）を解消し、プロジェクトのバージョンを `0.1.9-Beta-9h` に更新する。

## 完了条件
- [x] `Electron_Based_UX-Music/src/main/ipc-handlers.js` のコンフリクトマーカーが解消されていること。
- [x] `markdown/requirement.md` のバージョンが `0.1.9-Beta-9h` に更新されていること。
- [x] `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-9h` に更新されていること。
- [x] プロジェクト全体からコンフリクトマーカーが消えていること（検証済み）。

# Task: Wails 移行の未動作・ギャップ機能の探索とドキュメント化

## 概要
Electron 版では動作していた、または実装済みであったが、Wails 版では現在動作しない、あるいはモック・TODO となっている機能を隅々まで探索し、その内容をまとめる。

## 完了条件
- [x] `src/renderer/` 内のフロントエンドおよび `internal/` , `server/` 内のバックエンド実装を調査し、不一致・未実装機能（Discord RPC連携漏れ、プレイリスト実装など）をリストアップすること。
- [x] 調査結果を `markdown/wails-migration-gaps.md` にまとめること。
- [x] バージョンが `0.1.9-Beta-9g` に更新されること。

# Task: UI用語の英式綴り（British English）統一

## 概要
アプリケーションUI全体で米式綴り（American English）を排し、英式綴り（British English）に統一する。特に「音量ノーマライズ」機能のステータス表示などを対象とする。

## 完了条件
- [x] `src/renderer/js/features/normalize-view.js` 内のステータス文字列が `analysed` に変更されていること。
- [x] `src/renderer/styles/normalize-view.css` のステータスマッチング用セレクタが `.status-analysed` に修正されていること。
- [x] `markdown/requirement.md` 内の用語が英式に統一されていること。
- [x] `src/renderer/js/core/bridge.js` および `markdown/requirement.md` のバージョンが `0.1.9-Beta-9e` に更新されていること。

# Task: パフォーマンス最適化の実施

## 概要
`markdown/optimise.md` の計画に基づき、再生中ホットパス、RAM 常駐構造、ライブラリ更新処理の最適化を実施する。

## 完了条件
- [x] `src/renderer/js/ui/player-ui.js` で音量変更の即時反映と設定保存が分離されていること。
- [x] `src/renderer/js/features/visualizer.js` で Wails の周波数データ取得が毎フレーム実行されないこと。
- [x] `src/renderer/js/features/lyrics-manager.js` で歌詞現在行探索が全走査依存ではなく改善されていること。
- [x] `src/renderer/js/features/audio-graph.js` で AudioGraph キャッシュが無制限に増えないこと。
- [x] `src/renderer/js/ui/ui-manager.js` / `src/renderer/js/ui/detail-renderer.js` / `src/renderer/js/core/navigation.js` などでアルバム・アーティストが `songIds` 中心に扱われること。
- [x] `src/renderer/renderer.js` で `artworkLoadTimes` が固定長化されていること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-9a` に更新されていること。

# Task: 再生バー音声情報の表示項目をビット数へ変更

## 概要
再生バーの音声情報ツールチップについて、表示項目を「ビットレート」から「ビット数（ビット深度）」へ変更し、再生中楽曲のメタ情報として表示できるようにする。

## 完了条件
- [x] `src/renderer/index.html` の表示ラベルが「ビット数」に変更されていること。
- [x] `src/renderer/js/ui/player-ui.js` が `bitrate` ではなく `bitDepth`（および関連フィールド）を表示すること。
- [x] `internal/scanner/ffprobe.go` で `bits_per_sample` / `bits_per_raw_sample` / `sample_fmt` からビット深度を抽出できること。
- [x] `internal/scanner/scanner.go` と `app_scanner.go` で `bitDepth` が楽曲データに保持・マージされること。
- [x] `internal/scanner/ffprobe_test.go` にビット深度抽出の単体テストが追加されていること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8y` に更新されていること。

# Task: 再生バーの音声情報ツールチップ追加

## 概要
再生バーのシークバーと音量コントロールの間に情報ボタンを追加し、マウスオーバーで再生中楽曲のサンプリングレート・ビットレート・ファイル形式を確認できるようにする。

## 完了条件
- [x] `src/renderer/index.html` に情報ボタンと音声情報ツールチップの要素が追加されていること。
- [x] `src/renderer/styles/components.css` に情報ボタンとツールチップ表示のスタイルが追加されていること。
- [x] `src/renderer/js/ui/player-ui.js` で再生中楽曲の `sampleRate` / `bitrate` / `fileType` を整形し、ホバー時に表示できること。
- [x] `bitrate` が未保持の曲でも `fileSize` と `duration` から推定表示するフォールバックがあること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8x` に更新されていること。

# Task: WAVシーク不能と未解析曲スキップを修正（Wails build互換）

## 概要
WAVファイルでシークが効かない問題と、`wails build` 後に未解析曲を再生しようとすると解析失敗扱いで次曲へスキップされる問題を修正し、再生継続性を確保する。

## 完了条件
- [x] `pkg/audio/player.go` の WAV デコーダが PCM チャンク開始位置を保持し、`Seek` が PCM 基準で正しく動作すること。
- [x] `pkg/audio/player_wav_test.go` に WAV 長さ計算と WAV シーク位置の単体テストが追加されていること。
- [x] `pkg/normalize/normalizer.go` の `ffmpeg/ffprobe` 解決が `PATH` だけでなく `.app/Contents/Resources` と Homebrew 標準パスを探索すること。
- [x] `src/renderer/js/core/ipc.js` でラウドネス解析失敗時に「スキップ」ではなく「ノーマライズなし再生」を行うこと。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8r` に更新されていること。

# Task: Wails build後の m4a/mp4 再生失敗を修正（ffmpeg探索強化）

## 概要
`wails dev` では再生できるが `wails build` 後のアプリで `m4a/mp4` が再生失敗して次曲へスキップされる問題に対応するため、`ffmpeg/ffprobe` コマンド解決を `PATH` 依存からフォールバック探索付きへ強化する。

## 完了条件
- [x] `pkg/audio/player.go` の `resolveCommandPath` が `PATH` だけでなく Homebrew 標準パスを探索すること。
- [x] `.app` 実行時に `Contents/Resources/bin` および `Contents/Resources` 配下のコマンドも探索対象になること。
- [x] 解決結果をキャッシュし、再生中に毎回探索しないこと。
- [x] `ffmpeg/ffprobe` が解決できない場合、`PATH` を含む明示的なエラーメッセージが返ること。
- [x] `src/renderer/js/core/bridge.js` と `markdown/requirement.md` のバージョンが `0.1.9-Beta-8q` に更新されていること。

# Task: Wailsビルド用のアイコン設定

## 概要
Wailsのビルド時に既存のアイコン `src/renderer/assets/ux-music-icon.png` を使用するように設定する。

## 完了条件
- [x] `src/renderer/assets/ux-music-icon.png` が `build/appicon.png` にコピーされていること。
- [x] macOS用の `build/darwin/icon.png` にも同一のアイコンが配置されていること（Wailsの推奨構成）。
- [x] `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8p` に更新されていること。
- [x] `markdown/requirement.md` のバージョンが `0.1.9-Beta-8p` に更新されていること。

# Task: 右サイドバー映像プレビューのWails配信経路修正（file://禁止対応）

## 概要
Wails環境で右サイドバー映像プレビューが `Not allowed to load local resource` になる問題に対応するため、映像プレビューの参照経路を `file://` から `/safe-media/` へ切り替える。

## 完了条件
- [x] `src/renderer/js/ui/now-playing.js` で Wails 実行時の映像プレビュー URL が `/safe-media/...` になること。
- [x] 映像読み込み失敗ログに `songPath` と `sourceURL` が出力され、原因を追跡できること。
- [x] Electron 実行時の既存挙動（`file://`）を維持すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8o` に更新されていること。

# Task: 右サイドバーの映像プレビュー対応（映像付きローカル曲）

## 概要
右サイドバーのジャケット表示領域で、`mp4` など映像付きローカル楽曲を再生中に映像を表示する。Wails 環境では Go バックエンド再生と別にミュート映像プレビューを同期表示し、既存の `16:9` レイアウト切替を活かす。

## 完了条件
- [x] `src/renderer/js/ui/now-playing.js` で再生中楽曲が映像付き（`hasVideo`）の場合、右サイドバーに映像要素を描画できること。
- [x] Wails 環境では `main-player` に依存せず、右サイドバー専用のミュート動画プレビューを作成すること。
- [x] プレビュー映像が再生状態・一時停止状態・シーク位置に追従同期すること。
- [x] 非映像曲へ切替時にプレビューを確実に破棄し、従来どおりジャケット表示へ戻ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8n` に更新されていること。

# Task: YouTube字幕取得のXML互換修正（選択2で字幕なし誤判定）

## 概要
YouTube字幕トラックを明示選択（例: `2`）しても「字幕が見つからない」と表示される問題に対応するため、`timedtext format=3` を含む字幕XML形式へ対応し、選択済みトラックから同期歌詞を生成できるようにする。

## 完了条件
- [x] `internal/youtube/youtube.go` のトラック直取得パーサーが `xml-text`（`<text start dur>`）と `xml-timedtext-body`（`<p t d>`）の両方を扱えること。
- [x] `u74OTPd6W5Q` のように `GetTranscript(lang)` が失敗しても、直取得字幕からLRC生成できること。
- [x] 失敗時ログに字幕レスポンス種別・バイト数・短いスニペットが出力され、原因追跡できること。
- [x] `internal/youtube/youtube_test.go` に字幕XML形式ごとの単体テストが追加されていること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8m` に更新されていること。

# Task: YouTube字幕の選択UI追加と詳細ログ強化

## 概要
YouTube ダウンロード時に「字幕がない」と誤判定された状況の切り分けを容易にするため、字幕候補の選択UIを追加し、選択・取得・変換の詳細ログをコンソールへ出力する。

## 完了条件
- [x] `GetYouTubeInfo` のレスポンスに字幕候補一覧（言語/種別/トラックID）が含まれること。
- [x] `src/renderer/js/core/init-listeners.js` で YouTubeリンク追加時に字幕候補の選択モーダルを表示できること。
- [x] `add-youtube-link` が字幕選択情報（mode/language/vssId）を payload として渡せること。
- [x] `internal/youtube/youtube.go` で字幕選択情報を考慮し、候補評価・取得結果の詳細ログを出力すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8l` に更新されていること。

# Task: YouTube有効化同意ダイアログのWails互換化

## 概要
YouTube機能の有効化時に `confirm()` が Wails 環境で期待どおり動作しないケースに対応するため、アプリ内モーダルで同意取得できるようにする。

## 完了条件
- [x] `src/renderer/js/ui/modal.js` が `onCancel` を扱えること。
- [x] `src/renderer/js/utils/debug-commands.js` の YouTube同意処理が Wails 時にアプリ内モーダルを使うこと。
- [x] 「ライブラリを管理」連打導線と `uxDebug.enableYouTubeFeatures()` の両方で同じ同意処理を共有すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8k` に更新されていること。

# Task: YouTube機能有効化のWails対応（ライブラリ管理ボタン連打）

## 概要
既存の YouTube 機能有効化はデバッグコンソール経由（Electron 前提）だったため、Wails 実行環境でも利用できるように「ライブラリを管理」ボタン連打で有効化導線を提供する。

## 完了条件
- [x] `src/renderer/js/utils/debug-commands.js` の YouTube 有効化処理が共通関数化されていること。
- [x] `src/renderer/js/core/init-listeners.js` で「ライブラリを管理」ボタン連打（7回/2.5秒）時に有効化処理を呼び出すこと。
- [x] 既に有効な場合は重複有効化せず、UI表示だけ整合すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8j` に更新されていること。

# Task: YouTube字幕の同時取得と同期歌詞化

## 概要
YouTube ダウンロード時に字幕も取得し、同期歌詞（`.lrc`）として自動生成・保存する。生成された歌詞は既存の歌詞表示と LRC エディタでそのまま利用できることを目標とする。

## 完了条件
- [x] `internal/youtube/youtube.go` で字幕トラックの優先選択（手動字幕優先、日本語/英語優先）と LRC 変換が実装されていること。
- [x] `app_youtube.go` に `AddYouTubeLink` が実装され、ダウンロード結果をライブラリ保存し、字幕がある場合 `.lrc` を保存すること。
- [x] `src/renderer/js/core/env-setup.js` で `add-youtube-link` が Wails 側 `AddYouTubeLink` を呼び出すこと。
- [x] 字幕がない動画でもダウンロード自体は成功し、ユーザー通知されること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8i` に更新されていること。

# Task: LRCエディタのタイムライン編集化と既存LRC再編集

## 概要
従来の打鍵中心UIに加えて、動画編集ソフトのタイムラインに近い形で歌詞タイミングを調整できるLRCエディタへ拡張する。既存の `.lrc` を読み込んで再編集できることも必須とする。

## 完了条件
- [x] `src/renderer/components/lrc-editor.html` にタイムラインUI（ルーラー・プレイヘッド・クリップ領域）が追加されていること。
- [x] `src/renderer/styles/lrc-editor.css` にタイムライン編集用スタイルが追加されていること。
- [x] `src/renderer/js/features/lrc-editor.js` で、クリップのドラッグ移動による時刻調整が可能であること。
- [x] タイムラインクリックでシークでき、再生位置がプレイヘッドに反映されること。
- [x] 既存 `.lrc` を読み込んで編集し、保存できること（メタタグ保持を含む）。
- [x] `src/renderer/js/features/lyrics-manager.js` の右クリック導線から、既存LRC時もエディタを開けること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-7x` に更新されていること。

# Task: Wails への移行 Phase 1 - プロジェクト初期化と基盤設計

## 概要
Electron から Wails への移行を開始します。Phase 1 では、Wails プロジェクトの初期化、既存の Go ロジック（`src/go`）の App 構造体への統合、およびレンダラー（`src/renderer`）を Wails のフロントエンドとして動作させるための基盤を構築します。

## 完了条件
- [x] `package.json` のバージョンが `0.1.9-Beta-5s` に更新されていること。
- [x] Wails `App` 構造体への `GetSettings` / `SaveSettings` メソッドの実装
- [x] `bridge.js` の Wails 対応（設定の読み書き）
- [x] フロントエンドの `settings` 関連の `TypeError` を解消（`env-setup.js` の強化）
- [x] `src/renderer` が Wails の `frontend` として機能するためのディレクトリ構成が完了していること。
- [x] フロントエンドから Go のメソッドを呼び出すサンプルが動作すること。
- [x] Wails 環境での音楽ファイルの再生（`/safe-media/`）が動作すること
- [x] Wails 環境でのアートワーク表示（`/safe-artwork/`）が動作すること
- [x] プレイリスト管理機能（取得、詳細表示、作成、削除、名前変更、並び替え、追加）の Wails 移行
- [x] 歌詞表示・保存・追加機能の Wails 移行
- [x] Wails 環境での設定（Settings）の永続化と読み込みが正常に動作すること

# Task: Wails への移行 Phase 2 - Backend Migration & Cleanup

## 概要
Node.js および Electron に依存していたバックエンド処理（CDリッピング、MTP、正規化）を Go に完全移植し、不要になった Node.js/Electron コードを削除します。

## 完了条件
- [x] `pkg/cdrip` パッケージの実装 (MusicBrainz, cdparanoia, ffmpeg)
- [x] `pkg/mtp` パッケージの実装 (Cgo wrapper for kalam.dylib)
- [x] `pkg/normalize` パッケージの実装 (ffmpeg based normalization)
- [x] `app.go` への上記パッケージの統合と IPC メソッドの実装
- [x] `src/sidecars` および `src/main` の削除
- [x] `package.json` からのエレクトロン依存削除

# Task: Python sidecar 自動歌詞同期（v2）

## 概要
`markdown/lyrics-sync-plan.md` に従い、`TXT` 歌詞と音源から `LRC` 編集を支援する。**Python sidecar** が Demucs → faster-whisper → 埋め込み＋音素アラインメントを担当し、Go は stdin/stdout JSON と `lyrics-sync-progress` の中継のみとする。ユーザー表示歌詞は入力歌詞のみ（ASR はタイミング用）。

## 完了条件
- [x] `internal/lyricssync/types.go` の `Request` / `Result` JSON 契約と `App.AutoSyncLyrics` を維持すること。
- [x] `python/lyrics_sync` パイプライン（上記 sidecar）および `python -m lyrics_sync --request` エントリを実装すること。
- [x] `lyrics-auto-sync` invoke ルートおよび LRC エディタの自動同期動線は既存のまま利用できること。
- [x] `lyrics-sync-progress` イベントでステージ・進捗を配信し、LRC エディタで実行中に表示できること。
- [x] モデル初回ダウンロードの同意フローおよび設定画面でのキャッシュ容量確認・削除が可能であること。
- [x] Go 側および Python ダミーモードでのテストが存在すること（`UX_MUSIC_LYRICS_SYNC_DUMMY` 等）。

# Task: macOS 向け自動歌詞同期の Swift / CoreML 最適化

## 概要
`markdown/lyrics-sync-plan.md` に従い、自動歌詞同期の macOS 実行系を **Python 中心**から **Swift + CoreML 中心**へ段階移行する。`Request` / `Result` JSON 契約と UI 導線は維持しつつ、Go 側に sidecar 選択層を導入し、macOS では Swift 実装を差し込める状態にする。

## 完了条件
- [x] `markdown/features.md` / `markdown/requirement.md` / `markdown/lyrics-sync-plan.md` が、macOS 既定を `Swift + CoreML`、非 macOS を `Python fallback` として記述していること。
- [x] `internal/lyricssync` が Python 固定ではなく、ランタイム設定に応じて Swift / Python sidecar を選択できること。
- [x] `swift/lyrics-sync/` に `Request` / `Result` JSON 契約を受ける Swift CLI スケルトンが存在すること。
- [x] 既存の `App.AutoSyncLyrics` / `lyrics-auto-sync` / `lyrics-sync-progress` 契約が維持されること。
- [x] Go テストで sidecar 選択ロジックが検証され、Swift CLI が少なくともビルド可能であること。
- [x] `swift/lyrics-sync/` が `WhisperKit` を用いた ASR セグメント抽出と、歌詞行への簡易単調整列・補間を返せること。
- [x] `auto` 実行時に Swift sidecar の起動系失敗を Python sidecar へフォールバックできること。
- [x] `profile=fast` 既定時に、Swift sidecar が Python 時代より軽いモデル・worker 数で動作すること。
# Task: コンソール向けパフォーマンスモニターを追加

## 概要
GUI を増やさず、5秒ごとの平均負荷をコンソールへ出力できる軽量なパフォーマンスモニターを追加する。

## 完了条件
- [x] Wails バックエンドから `RSS` / `CPU` / `Go heap` を取得できること。
- [x] フロントエンドで 1 秒サンプリング、5 秒平均のコンソール出力が行われること。
- [x] `RSS` / `CPU` / `GoHeap` / `JSHeap` / `FPS` / `DOM` ノード数 / キュー件数 / 歌詞行数が出力されること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-9d` に更新されていること。
