# UX Sync Phase 5 実装計画: ポータブル mp3 キャッシュ（pull 側 mp3_320）

## 背景

実運用は **Mac mini（1TB, LibraryHost, 原本ロスレス）＋ MacBook Air（256GB, Portable Client, 持ち運びで頻繁にオフライン）**。Air は容量節約のため **mp3 圧縮**で持ちたい。

現状のギャップ: mp3_320 変換は **push（mini→Air）転送時のみ**で、Air の **自動同期 pull・Phase 3 タップ DL・Phase 4 選択プリフェッチはすべて `downloadSyncTrackAsset` 経由で原本（ロスレス）を取得**する（`/sync/assets/{trackId}/file` をエンコード指定なしで GET）。このため Air の自動/シームレス取得が原本で 256GB を圧迫し、「Air = mp3」運用に噛み合わない。

本フェーズで **pull 側でも mp3_320 を要求できる**ようにし、Air の自動・シームレス取得を mp3 化する。

## 確定方針（妥当な既定として本計画で採用。要変更なら指摘）

- 端末ごとの希望フォーマット `syncPreferredFormat`: `original`（既定・現行維持）/ `mp3_320`。Air を `mp3_320` にする。
- capability 不足時のフォールバック: peer が `library.transcode.mp3-320.v1` を持たない場合は **原本を取得**（曲を取り逃すより持つ方が良い）。
- 元が mp3 の曲に mp3_320 を要求された場合: **再変換せず原本 mp3 をそのまま配信**（push 側 line 785 と同じ判断）。
- matchKey は `artist|album|title|durationSec` で **フォーマット非依存**。mp3_320 変換は尺を保つため、mini(FLAC) と Air(mp3) で **再生回数はそのまま収束**する（設計上の利点。追加対応不要）。

## 設計

### サーバ側（ホスト = mini）

`/sync/assets/{trackId}/file` に任意クエリ `?encoding=mp3_320` を受ける。

- `encoding=mp3_320` かつ元ファイルが mp3 以外のとき、既存 `openSyncMP3Stream(ctx, path)` でオンザフライ変換し `Content-Type: audio/mpeg` でストリーム。
  - 応答ヘッダに `X-UX-Music-Sync-Transfer-Encoding: mp3_320`、`X-UX-Music-Sync-Audio-Bitrate: 320` を付ける。
  - `Content-Disposition` のファイル名拡張子を `.mp3` にする。
  - 変換失敗時はその曲を失敗として返す（勝手に原本へフォールバックしない＝push 仕様と一貫）。
- `encoding` 未指定、または元が mp3、または `encoding=original` のときは現行どおり原本を `http.ServeFile` で配信。
- artwork エンドポイントは対象外（変更なし）。

### クライアント側（Air）

- 設定キー `syncPreferredFormat`（`syncPreferredFormatSettingsKey = "syncPreferredFormat"`）を追加。`syncCachePolicy` と同様 `store.Instance.LoadMap("settings")` から読む。
- `downloadSyncTrackAsset` を拡張:
  - 希望が `mp3_320` かつ peer identity が `library.transcode.mp3-320.v1` を広告しているとき、取得 URL に `?encoding=mp3_320` を付ける。
  - 保存先ファイル名は応答（`Content-Disposition` / ヘッダ）優先、無ければ拡張子を `.mp3` にする。
  - 取り込み時、library.json の当該曲に `syncTransferEncoding: "mp3_320"`、`audioBitrateKbps: 320` を付与（push 取込と同じ形）。
  - capability 不足 or 希望 `original` のときは現行どおり原本取得。
- `DownloadSyncTrack` / `PrefetchSyncTracks` / `PullSyncLibraryAssets` / 自動同期 selective プリフェッチは、すべて `downloadSyncTrackAsset` 経由なので、ここを通せば自動的に希望フォーマットが効く。
- peer 到達先 identity は既に `fetchSyncIdentity` で取得しているので capability 判定に流用する。

### UI

- UX Sync 専用設定「保存」タブに **優先フォーマット**選択（`原本` / `MP3 320kbps`）を追加（`syncCachePolicy` の隣）。

## テスト（TDD・Red 先行）

サーバ:
1. `GET /sync/assets/{id}/file?encoding=mp3_320`（元 FLAC）→ `syncOpenMP3Stream`（stub）が呼ばれ、`audio/mpeg`＋`X-UX-Music-Sync-Transfer-Encoding: mp3_320`＋`.mp3` 名で返る。
2. 元が mp3 の曲に `?encoding=mp3_320` → 原本 mp3 をそのまま配信（再変換しない）。
3. `encoding` 未指定 → 現行どおり原本配信。
4. 変換失敗（stub エラー）→ エラー応答（原本フォールバックしない）。

クライアント:
5. `syncPreferredFormat=mp3_320` ＋ peer が capability あり → `downloadSyncTrackAsset` が `?encoding=mp3_320` を要求し、取込曲に `syncTransferEncoding/audioBitrateKbps` が付く・拡張子 `.mp3`。
6. peer が capability 無し → `?encoding` を付けず原本取得。
7. `syncPreferredFormat=original`（既定）→ 現行どおり原本取得。

整合:
8. 同一曲の FLAC と mp3_320 変換物が同じ `syncSongMatchKey` を返す（尺保持前提）→ 再生回数が収束する。

設定:
9. `syncPreferredFormat` の normalise / 永続化（不正値は `original`）。

## バージョン

新機能追加のため `PhaseVer` を +1、`SubVer` を `a` にリセット。

## ドキュメント更新

`markdown/ux-music-sync-protocol.md`（asset エンドポイントの `encoding` クエリと pull 側 mp3_320 を明記）、`markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を同期。
