# UX Music Sync 実装計画

## 目的

UX Music Sync は、同一 LAN 上の UX Music 端末間で、ライブラリ、再生履歴、プレイリスト、音源アセット、再生状態を同期するためのローカルファースト機能である。

主な想定環境は、家の大容量 Mac mini を `Library Host` として無圧縮・ロスレス音源の原本を保持し、持ち運び用の MacBook Air を `Portable Client` として圧縮済み音源と必要なメタデータだけを保持する構成とする。ユーザー体験としては、端末が変わっても「同じ音楽ライブラリを聴いている」状態を保ちつつ、保存容量と音質の役割分担を明確にする。

## スコープ

対象:

- 同一 LAN 上の端末発見。
- 6桁コード確認つきペアリング。
- ペア済み端末間の認証済み HTTP / WebSocket 通信。
- ライブラリメタデータの差分同期。
- 再生イベント、再生回数、お気に入り、プレイリストの同期。
- `Library Host` から `Portable Client` への圧縮音源提供。
- 再生中トラック、キュー、再生位置の端末移行。

対象外:

- LAN 外からの同期。
- クラウドバックエンド、NAT 越え、リレーサーバー。
- 複数ユーザー間のライブラリ共有。
- DRM 音源の複製や変換。
- 端末間で同時に別々の編集が大量発生する協調編集機能。

## 役割モデル

端末は固定の親子ではなく、能力値として役割を宣言する。ただし最初の MVP では `Library Host` 1台と `Portable Client` 1台の構成に限定してよい。

| 役割 | 説明 | 例 |
| :--- | :--- | :--- |
| `Library Host` | 原本ライブラリ、ロスレス音源、完全なメタデータを保持する | 1TB Mac mini |
| `Portable Client` | 圧縮音源、選択キャッシュ、外出先の再生履歴を保持する | 256GB MacBook Air |
| `Playback Target` | 他端末から再生移行先として指定できる | Mac mini / MacBook Air |
| `Controller` | 他端末の再生状態を閲覧・操作できる | MacBook Air |

`Library Host` は Single Source of Truth に近い扱いだが、再生イベントやプレイリスト変更は `Portable Client` 側でも発生するため、メタデータは双方向にマージできる設計にする。

## ペアリング設計

ペアリングは Bluetooth の数値確認に近い UX とする。6桁コードは秘密鍵そのものではなく、鍵交換の相手確認に使う短い認証文字列である。

### フロー

1. `Library Host` が LAN 上で `_uxmusic-sync._tcp.local` を mDNS / Bonjour 公開する。
2. `Portable Client` が同一 LAN 上の候補端末を検出する。
3. ユーザーが片方の端末で「ペアリング開始」を押す。
4. 双方が一時鍵を交換し、共有結果から6桁コードを生成する。
5. 両方の画面に同じ6桁コードを表示する。
6. ユーザーが両画面のコード一致を確認して承認する。
7. 長期端末鍵、端末ID、相手端末の公開鍵、能力値を保存する。
8. 以後はペア済み端末として自動認証し、LAN 内で検出された場合に同期候補へ出す。

### 入力型フォールバック

片方の端末でコード確認画面を出せない場合に備え、6桁コード入力型も許可する。ただし MVP では両画面表示の数値確認を優先する。

### セキュリティ要件

- 6桁コードだけを長期秘密として保存しない。
- ペアリング完了後は、長期共有鍵または端末公開鍵に基づく署名で HTTP / WS リクエストを認証する。
- ペアリング開始中の一時セッションには短い期限を設ける。
- LAN 内でも未ペア端末にはライブラリ、音源、再生操作 API を公開しない。
- 既存の Wear API 認証方針と矛盾しないよう、同期 API は独立した `sync` 認証層として実装する。

## 通信レイヤー

HTTP と WebSocket を併用する。

| 用途 | 推奨トランスポート |
| :--- | :--- |
| 端末情報取得 | HTTP |
| ペアリング開始・承認 | HTTP |
| ライブラリ差分取得 | HTTP |
| 再生イベント送信 | HTTP |
| 音源アセット取得 | HTTP |
| 変換ジョブ状態取得 | HTTP / WS |
| オンライン通知 | WebSocket |
| 再生状態通知 | WebSocket |
| 再生移行 | WebSocket |

HTTP はステートレスな同期に使い、WebSocket は短周期の状態変化や再生移行に使う。LAN 外通信は実装しない。

## データモデル

### Device

```json
{
  "deviceId": "dev_mac_mini",
  "displayName": "Living Room Mac mini",
  "roles": ["LibraryHost", "PlaybackTarget"],
  "protocolVersion": "0.1",
  "supportedCodecs": ["alac", "flac", "aac", "opus", "mp3"],
  "libraryClock": 42
}
```

### Track

```json
{
  "trackId": "trk_123",
  "title": "Song Title",
  "album": "Album Title",
  "artist": "Artist Name",
  "albumArtist": "Artist Name",
  "durationMs": 240000,
  "contentHash": "sha256:...",
  "musicBrainzTrackId": null,
  "sourceHostDeviceId": "dev_mac_mini",
  "updatedAt": "2026-06-08T12:00:00+09:00"
}
```

### Audio Asset

```json
{
  "assetId": "ast_123_aac_256",
  "trackId": "trk_123",
  "ownerDeviceId": "dev_mac_mini",
  "quality": "portable",
  "codec": "aac",
  "bitrateKbps": 256,
  "sampleRate": 44100,
  "fileSizeBytes": 8123456,
  "sourceAssetId": "ast_123_lossless",
  "availability": "ready"
}
```

`quality` は `lossless`、`portable`、`streamOnly` を想定する。`Portable Client` は `portable` を通常利用し、ロスレス原本は `Library Host` に残す。

### Play Event

再生回数は単純な数値ではなく、重複排除可能なイベントとして同期する。

```json
{
  "eventId": "evt_20260608_dev_air_0001",
  "trackId": "trk_123",
  "deviceId": "dev_macbook_air",
  "playbackSessionId": "sess_local_air_0007",
  "deviceSequence": 128,
  "playedAt": "2026-06-08T12:34:56+09:00",
  "countedAt": "2026-06-08T12:37:51+09:00",
  "durationPlayedMs": 185000,
  "completed": true
}
```

再生回数は `completed=true` または再生秒数しきい値を満たしたイベントから集計する。これにより、Mac mini と MacBook Air の両方で聴いた履歴を重複なくマージできる。

`eventId` は端末ID、端末内連番、再生セッションIDから生成し、同じイベントを何度プッシュしても親側で1回だけ取り込めるようにする。`playedAt` は再生開始またはカウント対象になった再生時刻、`countedAt` は端末が再生回数として確定した時刻、`deviceSequence` は端末内の単調増加番号とする。端末の時計がずれていても、同一端末内の順序は `deviceSequence` で復元できるようにする。

同じ曲を Mac mini と MacBook Air で同時に再生した場合は、原則として2つの独立した `Play Event` として扱う。これはユーザーが2つの端末で実際に再生した履歴であり、競合として片方を消さない。ハンドオフや再試行で同一再生が二重送信された場合だけ、同じ `eventId` または同じ `playbackSessionId` から派生した重複として排除する。

### Playback Session

```json
{
  "sessionId": "sess_abc",
  "ownerDeviceId": "dev_mac_mini",
  "trackId": "trk_123",
  "queueId": "queue_456",
  "positionMs": 74200,
  "isPlaying": true,
  "updatedAt": "2026-06-08T12:35:10+09:00"
}
```

## API 計画

### Discovery / Pairing

- `GET /sync/identity`
  - 端末名、端末ID、プロトコル版、役割、公開ペアリング状態を返す。
- `POST /sync/pairing/start`
  - 一時ペアリングセッションを開始する。
- `POST /sync/pairing/confirm`
  - 6桁コード確認後、長期ペアリングを確定する。
- `DELETE /sync/devices/{deviceId}`
  - ペア済み端末を解除する。

### Library Sync

- `GET /sync/library/changes?since={clock}`
  - 指定クロック以降の楽曲、アルバム、プレイリスト、アートワーク参照の差分を返す。
- `POST /sync/library/events`
  - 再生イベント、お気に入り変更、プレイリスト変更をバッチ送信する。特に `Portable Client` は、オフライン中に蓄積した再生イベントをこの API で `Library Host` へプッシュする。
- `GET /sync/library/snapshot`
  - 初回同期用の軽量スナップショットを返す。
- `GET /sync/library/event-acks?deviceId={deviceId}`
  - 親側が取り込み済みの端末内連番またはイベントIDを返し、子側の送信待ちイベント削除に使う。

### Asset Sync

- `GET /sync/assets?trackId={trackId}`
  - 利用可能なロスレス・圧縮アセットの一覧を返す。
- `POST /sync/assets/prepare`
  - `Portable Client` 向け圧縮アセットの作成を要求する。
- `GET /sync/assets/{assetId}/file`
  - 認証済み端末へ音源ファイルを返す。

### Playback Handoff

- `GET /sync/playback/state`
  - 現在の再生状態を返す。
- `POST /sync/playback/command`
  - 再生、一時停止、シーク、キュー操作を送信する。
- `WS /sync/ws`
  - 再生状態、ハンドオフ要求、変換ジョブ進捗、端末オンライン状態を通知する。

## 再生移行

Spotify Connect / AirPlay に近い体験を目指す。ユーザーは再生中の曲を別端末へ移し、移行先で同じキューと再生位置から続き再生できる。

### ハンドオフ要求

```json
{
  "type": "handoff_request",
  "sessionId": "sess_abc",
  "trackId": "trk_123",
  "positionMs": 74200,
  "queueId": "queue_456",
  "fromDeviceId": "dev_mac_mini",
  "toDeviceId": "dev_macbook_air"
}
```

`toDeviceId` が対象曲の `portable` アセットを持っていない場合は、次の優先順位で処理する。

1. 既存の圧縮アセットを取得してから再生する。
2. `Library Host` に圧縮アセット作成を要求し、準備完了後に再生する。
3. 一時的に `streamOnly` として `Library Host` から配信する。

MVP では 1 と 2 を優先し、3 は後続に回してよい。

## キャッシュ方針

`Portable Client` は保存容量が限られるため、明示的な同期ポリシーを持つ。

- お気に入り曲を常時保持。
- 指定プレイリストを常時保持。
- 最近よく聴く曲を自動保持。
- 空き容量しきい値を下回ったら、最後に再生・参照した時刻が古い圧縮アセットから削除。
- 削除してもメタデータ、再生イベント、プレイリスト所属は残す。

MacBook Air のような 256GB 端末では、既定で `portable` アセットのみを保持する。ロスレスの手動持ち出しは将来拡張とする。

## オフライン前提の同期

`Portable Client` は頻繁に `Library Host` へ接続されない可能性を前提にする。外出先では単体で再生、再生イベント記録、プレイリスト編集、お気に入り変更を継続でき、同一 LAN で親を発見したときにまとめて同期する。

### 子側アウトボックス

`Portable Client` は同期対象のローカル変更をアウトボックスに保存する。

- 再生イベント。
- お気に入り追加・解除。
- ローカルプレイリスト変更。
- 圧縮アセット取得要求。

アウトボックスのイベントは、親から取り込み確認を受けるまで削除しない。送信失敗、アプリ終了、ネットワーク切断が起きても、次回接続時に同じイベントを再送する。親側は `eventId` で冪等に受け付けるため、再送による再生回数の二重加算を防げる。

### 同期方向

基本の同期方向は双方向だが、役割ごとに責務を分ける。

| 方向 | 内容 |
| :--- | :--- |
| 子から親へプッシュ | 再生イベント、外出先のお気に入り変更、プレイリスト変更、キャッシュ要求 |
| 親から子へプル | ライブラリ差分、アートワーク参照、圧縮アセット、親側で更新されたプレイリスト |
| 双方向マージ | 再生履歴、お気に入り、プレイリスト変更ログ |

`Library Host` は全体集計の基準になるが、`Portable Client` の再生回数は子側で完結させず、接続時に必ず親へプッシュする。親は取り込み後に新しい集計結果を差分として返し、子側の表示も親の集計へ収束させる。

### たまに接続される端末の扱い

- 同期は常時接続を前提にしない。
- 子側は最後に親へ送信済みの `deviceSequence` または `eventId` を保存する。
- 親側は各子端末ごとに取り込み済みカーソルを保存する。
- 初回または長期間未接続の場合は、イベント送信後にライブラリスナップショットまたは大きめの差分を取得する。
- 大量の未送信イベントがある場合は、ページングされたバッチ送信にする。
- 時計ずれが疑われる場合でも、イベントIDと端末内連番で重複排除し、表示用時刻だけ `playedAt` を使う。

## 競合解決

| 対象 | 方針 |
| :--- | :--- |
| 再生回数 | `Play Event` をイベントIDと端末内連番で重複排除し、集計で算出する。子側のカウントは接続時に親へプッシュする |
| 同時再生 | 端末ごとの別イベントとして両方を採用する。ハンドオフや再送による同一イベントだけを重複排除する |
| お気に入り | 端末IDつき変更イベントを時刻順に適用する |
| プレイリスト名 | 最終更新時刻を基準にし、衝突時は片方を複製名に退避する |
| プレイリスト曲順 | 初期は最終更新勝ち。後続で順序 CRDT を検討する |
| メタデータ編集 | `Library Host` 優先。`Portable Client` の編集は変更イベントとして Host に送る |
| 音源実体 | `sourceAssetId` と `contentHash` を基準にし、Host の原本を優先する |

## 実装フェーズ

### Phase 1: 契約と保存基盤（実装済み: 2026-06-08）

目的:

- 同期対象のデータ契約を固定する。
- 端末ID、ペア済み端末、再生イベントを永続化できるようにする。

作業:

- `internal/uxsync` パッケージを追加する。
- `Device`, `PairedDevice`, `PlayEvent`, `AudioAsset`, `LibraryChange` の型を定義する。
- store 層に同期用永続データを追加する。
- 再生回数をイベント集計で求める純粋関数を追加する。
- 子側アウトボックス、親側取り込み済みカーソル、端末内連番の保存構造を追加する。

テスト:

- 再生イベントの重複排除。
- 端末IDつきイベントのマージ。
- 同じ曲を複数端末で同時に再生したイベントが、別イベントとして両方集計される。
- 同じ `eventId` の再送が再生回数を二重加算しない。
- 時計ずれがあっても、同一端末内の順序を `deviceSequence` で扱える。
- `Library Host` と `Portable Client` の能力値判定。

### Phase 2: 6桁コード確認ペアリング（基盤実装済み: 2026-06-08）

目的:

- LAN 内で発見した端末と安全にペアリングできるようにする。

作業:

- mDNS / Bonjour で同期サービスを公開・探索する。
- 一時ペアリングセッションを作成する。
- 鍵交換結果から6桁コードを生成する。
- ペアリング確定後に長期端末情報を保存する。
- 設定画面にペアリング開始、コード確認、ペア済み端末解除の UI を追加する。

実装済み:

- `/sync/pairing/start` と `/sync/pairing/confirm` による6桁コード確認と同期専用トークン発行。
- `/sync/identity` による同期端末情報の公開。
- Wear 認証と Sync 認証の middleware 分離。

未実装:

- ペア済み端末解除。
- 実鍵交換に基づく6桁コード導出。

### Phase 2.5: mDNS / Bonjour 自動発見（実装済み: 2026-06-08）

目的:

- 同一 LAN 上の UX Music 端末を `_uxmusic-sync._tcp.local.` で自動発見できるようにする。

実装済み:

- `github.com/grandcat/zeroconf` による mDNS 広告。
- `DiscoverSyncDevices(timeoutMs)` による Wails 向け発見メソッド。
- `deviceId`、`displayName`、`protocolVersion`、`roles` を TXT レコードとして公開。
- 複数 NIC 環境で同一 `deviceId` の複数アドレス候補を `hosts` に保持。
- 発見 peer の `hosts` 候補へ `/sync/identity` を順番に probe し、到達可能な `reachableBaseUrl` を自動選択。
- macOS `dns-sd` と Go の `DiscoverMDNS` による実広告検証。

実装済み:

- 設定画面の UX Sync セクションから `DiscoverSyncDevices(timeoutMs)` を呼び出す自動発見一覧 UI。
- 発見 peer の `reachableBaseUrl`、役割、複数 NIC の候補 `hosts` を表示する renderer 側の整形処理。

### Phase 2.6: 発見 peer からのペアリング UI（実装済み: 2026-06-08）

目的:

- 設定画面の自動発見一覧から、到達可能な UX Music peer と6桁コード確認ペアリングできるようにする。

実装済み:

- Wails 向け `StartSyncPairing(baseURL)` と `ConfirmSyncPairing(baseURL, sessionID, code, expectedRemoteDeviceID)`。
- `StartSyncPairing` でリモート `/sync/identity` と `/sync/pairing/start` を呼び、ローカル `deviceId`、リモート端末情報、一時セッション、6桁コードを UI に返す処理。
- `ConfirmSyncPairing` でリモート `/sync/pairing/confirm` を呼び、リモートが発行した同期トークンをローカル設定のリモート `deviceId` 宛に保存する処理。
- 確定時に再取得したリモート `deviceId` が開始時の `remoteDeviceId` と異なる場合は、トークン保存を拒否する処理。
- peer カード上の「接続」→6桁コード表示→「確定」→ペアリング済み表示。
- `reachableBaseUrl` を優先し、未取得時は `host` / `hosts` と `port` からペアリングURLを構成する renderer 側の導線。

未実装:

- ペア済み端末の一覧管理と解除 UI。
- 現状の6桁コードはリモート API 応答として開始側に返るため、Bluetooth 数値確認のように双方が独立表示する方式への強化。

### Phase 2.7: UX Sync 専用設定画面（実装済み: 2026-06-08）

目的:

- 通常設定から UX Sync の探索・ペアリング UI を切り離し、同期機能専用の管理画面として拡張できるようにする。

実装済み:

- 通常設定モーダルには `UX Sync設定を開く` の入口だけを表示。
- Wails sync binding が無い renderer 単体環境では UX Sync 入口を非表示にする。
- UX Sync 専用設定画面の `端末` タブに、探索ボタン、探索状態、peer 一覧、6桁コード確認ペアリング導線を集約。
- 後続の差分同期や圧縮キャッシュ設定を載せるため、`同期` と `保存` のタブ枠を追加。

未実装:

- ペア済み端末一覧、解除、信頼状態表示。
- 同期アウトボックス、最終同期時刻、競合状態の表示。
- `Library Host` / `Portable Client` の保存ポリシー設定。

### Phase 2.8: Windows 側発見 fallback（実装済み: 2026-06-08）

目的:

- Mac 側から Windows peer は見えるが、Windows 側の mDNS discovery が空になって Mac mini を見つけられない非対称状態を補正する。

実装済み:

- mDNS 広告に使う表示名から `.local` suffix を除去し、`YukinoMac-mini.local` ではなく `YukinoMac-mini` として広告する。
- inbound pairing confirm 成功時に、相手 `deviceId`、表示名、実通信元 IP から既知 peer を `settings.syncKnownPeers` へ保存する。
- `DiscoverSyncDevices(timeoutMs)` と `/sync/discover` が mDNS 結果と既知 peer をマージする。
- Mac 側 `dns-sd -B _uxmusic-sync._tcp local` で `YukinoMac-mini` が複数 interface に広告されることを確認した。
- `mainPC` から `http://192.168.0.226:8765/sync/identity` が応答することを確認した。

未実装:

- Windows mDNS browse 自体が空になる根本原因の完全解消。
- ペア済み端末一覧から既知 peer を削除する UI。

### Phase 2.9: 音源pull MVP と SSH 検証 CLI（実装済み: 2026-06-08）

目的:

- Windows 側を検証専用ノードとして扱い、GUI / WebView2 を起動せず SSH から初期化と音源転送を検証できるようにする。
- 圧縮アセット生成の前段として、親側の既存ライブラリ原本を同期専用 HTTP API で取得し、子側の管理ライブラリへ取り込む縦串を作る。

実装済み:

- `/sync/library/snapshot` が同期トークンを要求し、アートワーク blob を除いた曲一覧を返す。
- `/sync/assets/{trackId}/file` が同期トークンを要求し、登録済み曲IDの原本ファイルを返す。
- `PullSyncLibraryAssets(baseURL, limit)` が親の `identity`、`library/snapshot`、`assets/{trackId}/file` を呼び、子側 `SyncLibrary` 配下へ音源を保存して `library.json` へ取り込む。
- 取り込んだ曲には `syncSourceDeviceId` と `syncSourceTrackId` を保存し、再実行時に同じ親・同じ曲の二重取り込みを避ける。
- `--sync-reset-test-data` で、`syncDeviceId` / `syncAuthTokens` / `syncKnownPeers` を温存したまま検証用ライブラリ、再生回数、解析、同期イベント、アートワーク、キャッシュ、プレイリストを初期化する。
- `--sync-pull-one` / `--sync-pull` で、SSH 経由でも Wails GUI を起動せず音源pullを実行できる。
- UX Sync 専用設定画面の `同期` タブから同期元 peer を選択し、`1曲取得` または `全曲取得` を実行できる。
- GUI の音源pull完了後に、取得数・既存数・失敗数と保存先パスを表示する。
- `ListSyncDevices()` が保存済み `syncAuthTokens` と `syncKnownPeers` から、同期トークンを返さずペア済み端末一覧を返す。
- UX Sync 専用設定画面は discovery 結果とペア済み端末一覧をマージし、画面を閉じた後や mDNS が空の状態でも同期元候補を復元する。
- `/sync/library/import` が同期トークン必須の multipart 受信口として、ペア済み端末から送られた音源とメタデータを `SyncLibrary` へ取り込む。
- `PushSyncLibraryAssets(baseURL, limit)` により、ローカルライブラリの音源をペア済み相手端末へ転送できる。
- UX Sync 専用設定画面の `同期` タブから `1曲転送` / `全曲転送` を実行し、転送数・既存数・失敗数と受信側保存先を確認できる。
- `/sync/identity` が `protocolVersion`、`minCompatibleProtocolVersion`、`schemaVersion`、`capabilities`、`negotiation` を返す。
- client は `/sync/identity` へ `X-UX-Music-Sync-Protocol-Version`、`X-UX-Music-Sync-Schema-Version`、`X-UX-Music-Sync-Capabilities` を送り、自分の対応状況を申告する。
- `/sync/schema` が endpoint / message / capability / 拡張規則を含む機械可読スキーマを返す。
- mDNS TXT に `schemaVersion` と `capabilities` を追加し、発見段階でも軽量に機能差を確認できるようにする。
- `ux-sync-transfer-progress` event により、pull / push 中のファイル名、件数、転送量、転送速度、変換モードを UI に表示できる。
- `PushSyncLibraryAssetsWithOptions(baseURL, limit, { encodingMode: "mp3_320" })` により、FLAC などのロスレス音源を MP3 320kbps へ変換しながら転送できる。
- UX Sync 専用設定画面の `同期` タブから、原本転送または MP3 320kbps 転送を選択できる。
- `IncrementPlayCount` がローカル `PlayEvent` を記録し、`AutoSyncPairedDevices()` と起動後の軽量自動同期ループで、接続可能なペア済み端末へ再生回数イベントをpushできる。
- `/sync/library/events` は受信した新規 `PlayEvent` を既存 `playcounts` へ冪等に反映する。
- `/sync/assets/{trackId}/artwork` により、保存済みジャケットを同期トークン付きの個別 asset として取得できる。
- `AutoSyncPairedDevices()` は、既に取り込み済みの同期曲で欠けているジャケットを接続可能なペア済み端末から自動補完できる。
- multipart import / push は任意の `artwork` part を扱い、受信側の `Artworks` と `library.json` に安全なファイル名として保存できる。
- `settings.syncMinFreeSpaceGB` により、保存先ボリュームの空き容量が指定GB未満の場合に自動同期、音源取得、音源受信を停止できる。
- UX Sync 専用設定画面の `保存` タブから最低空き容量を設定できる。
- `sync-remote-catalog` に LibraryHost peer の snapshot metadata を保存し、`LoadLibrary()` / `GetUnifiedLibrary()` が local 曲と未取得 remote 曲を表示時に統合できる。
- 統一ライブラリビューでは local 曲を `syncAvailability=local`、remote 曲を `syncAvailability=remote` として返し、remote 曲は `DL可能` 表示とプレースホルダ artwork の対象にする。
- 詳細仕様は `markdown/ux-music-sync-protocol.md` を参照する。

未実装:

- 親側での portable 圧縮アセット生成と再利用。
- 変換済み portable 圧縮アセットの永続キャッシュと再利用。
- 音源本体の自動転送に対する容量ポリシーと端末別同期設定。
- 容量不足時の自動削除ポリシーと失敗時の再試行キュー。

テスト:

- 同じ一時鍵交換結果から同じ6桁コードが生成される。
- 異なる相手ではコードが一致しない。
- 期限切れセッションは確定できない。
- 未ペア端末は同期 API へアクセスできない。

### Phase 3: ライブラリ差分同期

目的:

- 初回スナップショットと差分同期で、端末間のメタデータを揃える。

作業:

- `/sync/library/snapshot` と `/sync/library/changes` を追加する。
- `Play Event`、お気に入り、プレイリスト変更の送受信を実装する。
- `libraryClock` または変更ログ ID で差分取得できるようにする。
- `Portable Client` のアウトボックスから `Library Host` へ未送信イベントをバッチプッシュする。
- 親側の取り込み確認を受けて、子側の送信済みアウトボックスを整理する。

テスト:

- 初回スナップショットで曲一覧とアートワーク参照が取得できる。
- `since` 指定で差分だけが返る。
- 再生イベントが重複なくマージされる。
- オフライン中の `Portable Client` のイベントが再接続後に反映される。
- 接続が途中で切れて同じバッチを再送しても、親側の再生回数が増えすぎない。
- 親へプッシュされた子側再生イベントが、次回差分取得で子側表示にも反映される。

### Phase 4: 圧縮アセット提供

目的:

- `Library Host` のロスレス原本から、`Portable Client` 用の圧縮アセットを取得できるようにする。

作業:

- `AudioAsset` 管理を追加する。
- 既存の ffmpeg 解決基盤を使って AAC / Opus などの圧縮アセットを生成する。
- `/sync/assets`、`/sync/assets/prepare`、`/sync/assets/{assetId}/file` を追加する。
- `Portable Client` 側のキャッシュ保存、容量制限、削除方針を実装する。

テスト:

- ロスレス原本から指定 codec / bitrate の圧縮アセットが生成される。
- 同じ条件のアセットは再生成されず再利用される。
- 認証なしではファイルを取得できない。
- 容量しきい値を超えた場合に古いキャッシュから削除される。

### Phase 5: WebSocket と再生移行

目的:

- 再生状態をリアルタイムに通知し、別端末へ再生を移行できるようにする。

作業:

- `/sync/ws` を追加する。
- 再生状態イベント、端末オンラインイベント、ハンドオフ要求を定義する。
- UI に再生先端末の選択導線を追加する。
- 移行先に必要な圧縮アセットがない場合の準備フローを接続する。

テスト:

- 再生状態が WS で通知される。
- ハンドオフ要求で移行先に同じ曲、近い再生位置、同じキューが設定される。
- 移行先にアセットがない場合は準備要求が発行される。
- 移行元の停止と移行先の開始が二重再生にならない。

### Phase 6: UI 仕上げと運用性

目的:

- 日常利用できる設定、状態表示、失敗時の復旧導線を整える。

作業:

- 設定画面に同期デバイス一覧を追加する。
- `Library Host` / `Portable Client` の同期ポリシーを選べる UI を追加する。
- 同期キュー、変換中、転送中、容量不足、認証失敗を通知する。
- 手動の「今すぐ同期」と「このプレイリストを持ち出す」を追加する。

テスト:

- 同期ポリシー変更が永続化される。
- 端末解除後に自動同期と再生操作が停止する。
- 容量不足時にユーザーへ理由が表示される。

## MVP 完了条件

- Mac mini を `Library Host`、MacBook Air を `Portable Client` として6桁コード確認でペアリングできる。
- ペア済み端末だけが同期 API にアクセスできる。
- `Portable Client` が `Library Host` のライブラリスナップショットを取得できる。
- `Portable Client` の再生イベントが `Library Host` へ反映され、再生回数が重複なく集計される。
- `Portable Client` が長期間オフラインでも再生イベントを保持し、再接続時に親へプッシュできる。
- Mac mini と MacBook Air で同じ曲を同時に再生した場合は2回分として集計され、同じイベントの再送だけは重複排除される。
- 指定プレイリストの曲を圧縮アセットとして MacBook Air 側へ保存できる。
- 再生中の曲を Mac mini から MacBook Air、または MacBook Air から Mac mini へ移行できる。

## ドキュメント更新方針

実装着手時は、各フェーズごとに次の文書を更新する。

- `markdown/Task.md`: フェーズ単位の完了条件。
- `markdown/requirement.md`: 実装済みになった同期仕様。
- `markdown/features.md`: ユーザー向け機能説明。
- `markdown/progress.md` とルートの `progress.md`: 実施内容、テスト、判断。

コード変更を伴うフェーズでは、テストを先に追加し、Red / Green / Refactor のコミット単位を守る。
