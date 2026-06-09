# UX Music Sync Protocol Schema

## 目的
UX Sync は同一 LAN 上の UX Music 端末同士が、発見・ペアリング・再生イベント同期・音源取得・音源転送を行うための HTTP / mDNS プロトコルである。

この文書は wire schema の安定した参照点であり、実装は `/sync/schema` でも同じ考え方の機械可読スキーマを公開する。

## バージョンと互換性
- `protocol`: `ux-music-sync`
- `protocolVersion`: `0.2`
- `minCompatibleProtocolVersion`: `0.1`
- `schemaVersion`: `2026-06-09`

互換性判定は最小実装として major 部分で行う。`0.x` 同士は互換、`1.x` など major が異なる端末は pairing / pull / push の前に拒否する。

## 拡張規則
- 未知フィールドは無視する。
- 未知 capability は保持してよいが、実行可能とはみなさない。
- 将来拡張用の自由領域は `extensions` に入れる。
- track metadata の未知フィールドは、取り込み時に壊さない範囲で保持してよい。
- artwork など巨大 blob は snapshot / import metadata では送らず、必要なら別 capability と別 endpoint で扱う。

## ネゴシエーション
client は `/sync/identity` へ次のヘッダで自分の対応状況を申告する。

- `X-UX-Music-Sync-Protocol-Version`
- `X-UX-Music-Sync-Schema-Version`
- `X-UX-Music-Sync-Capabilities`

server は identity 応答に `negotiation` を含める。

```json
{
  "protocolVersion": "0.2",
  "schemaVersion": "2026-06-09",
  "capabilities": ["identity.v1", "library.import.v1"],
  "negotiation": {
    "requestedProtocolVersion": "0.1",
    "selectedProtocolVersion": "0.2",
    "selectedSchemaVersion": "2026-06-09",
    "acceptedCapabilities": ["library.import.v1"],
    "compatible": true
  }
}
```

## Capabilities
- `identity.v1`: `/sync/identity`
- `schema.v1`: `/sync/schema`
- `discovery.mdns.v1`: `_uxmusic-sync._tcp.local.` mDNS discovery
- `pairing.code.v1`: 6桁コード確認ペアリング
- `library.events.v1`: 再生イベントpush
- `library.snapshot.v1`: ライブラリスナップショット取得
- `library.asset-file.v1`: 曲ID指定の音源取得
- `library.artwork.v1`: 曲ID指定のジャケット画像取得
- `library.import.v1`: multipart 音源push取り込み
- `library.storage-safety.v1`: 保存先空き容量が設定閾値未満の場合に同期を停止する
- `library.transfer-progress.v1`: Wails UI / local client 向け転送進捗イベント
- `library.transcode.mp3-320.v1`: MP3 320kbps へ変換しながら転送するオプション
- `library.auto-sync.v1`: 接続可能なペア済み端末へ軽量な同期ジョブを定期実行する

## 公開エンドポイント
| Method | Path | Auth | Capability |
| :--- | :--- | :--- | :--- |
| GET | `/sync/identity` | public | `identity.v1` |
| GET | `/sync/schema` | public | `schema.v1` |
| POST | `/sync/pairing/start` | public | `pairing.code.v1` |
| POST | `/sync/pairing/confirm` | public | `pairing.code.v1` |
| GET | `/sync/library/snapshot` | sync-token | `library.snapshot.v1` |
| GET | `/sync/assets/{trackId}/file` | sync-token | `library.asset-file.v1` |
| GET | `/sync/assets/{trackId}/artwork` | sync-token | `library.artwork.v1` |
| POST | `/sync/library/import` | sync-token | `library.import.v1` |
| POST | `/sync/library/events` | sync-token | `library.events.v1` |

## ジャケット同期
`library.artwork.v1` は、ジャケット画像を track metadata の巨大 blob として混ぜず、同期トークン付きの個別 asset として扱う。

- `/sync/library/snapshot` はローカル `artwork` を直接返さず、取得可能な場合だけ `syncArtwork` 参照を返す。
- `/sync/assets/{trackId}/artwork` は、ライブラリ登録済み曲の保存済みジャケットを返す。
- `/sync/library/import` の multipart payload は任意の `artwork` part を受け取れる。受信側は `Artworks` 配下へ保存し、`library.json` には安全なファイル名だけを `artwork.full` として保存する。

## 転送オプション
push 転送のローカル呼び出しは `encodingMode` を指定できる。

- `original`: 原本ファイルをそのまま送る。
- `mp3_320`: MP3以外の音源を MP3 320kbps へストリーミング変換しながら送信し、`syncTransferEncoding: "mp3_320"` と `audioBitrateKbps: 320` を metadata に付けて送る。

`mp3_320` は保存容量と転送時間を優先する portable client 向けのモードである。変換失敗時はその曲を failed として扱い、勝手に原本へフォールバックしない。

## push転送メタデータ
`POST /sync/library/import` の multipart `metadata` は、表示に必要な曲メタデータを `track` に含める。`title`、`artist`、`album`、`albumartist`、`trackNumber`、`discNumber`、`genre`、`year` などの既知フィールドは未知フィールドと同じく保持する。

送信側に再生回数がある場合、`track.syncPlayCount` に `count` と任意の `history` を入れる。受信側は音源を保存した実パスをキーに `playcounts` へ反映し、`syncPlayCount` 自体は `library.json` へ残さない。

ジャケットは可能な限り multipart `artwork` part として同梱する。送信側の `Artworks` 管理済みファイルを優先し、受信側は `Artworks` 配下へ保存して `track.artwork.full` を更新する。受信側は payload のメタデータが不足している場合、保存済み音源を再スキャンしてタグと埋め込みジャケットを補完してから `library.json` へ反映する。

## 転送進捗
UI には `ux-sync-transfer-progress` event として次の情報を流す。

```json
{
  "direction": "push",
  "stage": "uploading",
  "trackId": "track-1",
  "title": "Song",
  "fileName": "song.mp3",
  "current": 1,
  "total": 12,
  "bytesDone": 1572864,
  "bytesTotal": 3145728,
  "bytesPerSecond": 1572864,
  "encodingMode": "mp3_320",
  "updatedAt": "2026-06-09T05:56:00Z"
}
```

`stage` は `preparing`、`transcoding`、`downloading`、`uploading`、`done`、`skipped`、`failed` を使う。

## 自動同期
`library.auto-sync.v1` は、ペア済み端末の既知URLへ接続できた時に、手動ボタンなしで同期を試す capability である。ローカル再生回数の `PlayEvent` を `/sync/library/events` へpushし、`LibraryHost` 役割を持つ peer からは `/sync/library/snapshot` と `/sync/assets/{trackId}/file` を使って未取得曲だけを自動取得する。既に `syncSourceDeviceId` / `syncSourceTrackId` 付きで取り込み済みかつ実ファイルが存在する曲は skip として扱い、二重転送しない。既に同期済みの曲で欠けているジャケットは `/sync/assets/{trackId}/artwork` から補完する。

## 空き容量安全停止
`library.storage-safety.v1` は、受信側がローカル保存先ボリュームの空き容量を確認し、`settings.syncMinFreeSpaceGB` を下回る場合に同期を停止できることを示す。`syncMinFreeSpaceGB` が `0` または未設定の場合は無効である。

- `AutoSyncPairedDevices()` は peer 接続前に確認し、停止時は `SyncAutoResult.paused=true` と `pauseReason="free-space-below-limit"` を返す。
- `PullSyncLibraryAssets()` と `/sync/library/import` は、音源やジャケットの受信前に同じ判定を行う。
- `freeSpaceBytes` と `minFreeSpaceBytes` は診断用の数値であり、古い client は未知フィールドとして無視してよい。

## mDNS TXT
mDNS TXT は軽量な事前情報として扱い、最終判断は `/sync/identity` で行う。

- `deviceId`
- `displayName`
- `protocolVersion`
- `schemaVersion`
- `capabilities`
- `roles`

## 注意
現時点の Sync token 認証は「保存済み token のいずれかに一致するか」を見る。将来は `sourceDeviceId` と token の対応関係まで検証する capability を追加する。
