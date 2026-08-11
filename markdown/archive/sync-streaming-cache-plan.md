> **このドキュメントは廃止済みです（2026-08-11）。**
> 旧 `/sync/*`（無版）プロトコルの実装計画です。LAN API v1 統一（`progress/lan-api-v1.md`）により `/v1/sync/*` へ再編済みです。

# UX Sync Phase 3+4 実装計画: シームレス DL 再生とスマートキャッシュ

## 背景

UX Music Sync の完成系は「ストリーミング的体験（LAN ローカルファースト）」で、再生モデルは**ダウンロード優先のシームレス化**で実現する（[[project_sync]]）。

- Phase 1（実機検証済み）: 再生回数収束（`syncSongMatchKey` ＋ イベントログ単一ソース）。
- Phase 2（完了）: 統一ライブラリビュー。未取得リモート曲も一覧表示し `syncAvailability:"remote"` でマーク。`sync-remote-catalog` に peer の snapshot をキャッシュ。
- **Phase 3（本計画）: シームレス DL 再生。** リモート曲の再生ボタンで、その曲を最優先 DL → 自動再生。
- **Phase 4（本計画）: スマート先読みキャッシュと容量ポリシー。** 現行の「全曲無差別 pull」を端末ごとのポリシー配下に置き、選択的プリフェッチ＋ LRU 削除を行う。

設計は一体で考えるが、実装・コミットは Phase 3 → Phase 4 の順に分ける。

## 確定方針

- Phase 4 自動先読み対象: **最近再生 ＋ キュー先読み**（プレイリスト/お気に入りは対象外。お気に入り機能自体が未実装）。
- 全曲ミラーの扱い: **端末ごとに `syncCachePolicy` を選択**（`mirror` / `selective`）。
- LRU 削除トリガ: **既存 `syncMinFreeSpaceGB` 閾値を再利用**。
- 開発手法: TDD（Red → Green → Refactor）、英式綴り、日本語コミット。

---

## Phase 3: シームレス DL 再生

### 目的
`syncAvailability:"remote"` の曲の再生ボタンで、その曲だけを取得元 peer から最優先 DL し、完了後に自動再生する。

### 設計

バックエンド:
- 新メソッド `DownloadSyncTrack(sourceDeviceId, sourceTrackId string) (SyncPullResult, error)`:
  - `sync-remote-catalog` から該当 peer の track メタデータを引く。
  - peer の `baseUrl` と token を `ListSyncDevices` / `loadSyncAuthTokenForDevice` で解決する。
  - 既存 `downloadSyncTrackAsset` を単曲で実行し、`SyncLibrary` へ保存・`library.json` へ取込・local path を返す。
  - 進捗は既存 `ux-sync-transfer-progress` イベントで流す。
  - peer 到達不可・token 無しはエラーを返す（フォールバックで原本以外を勝手に使わない）。

フロントエンド（`playback-manager.ts`）:
- `canStartPlayback` が remote のとき、現行の「再生は後続フェーズで対応」トーストをやめ、DL フローに入る。
  - `DownloadSyncTrack(syncSourceDeviceId, syncSourceTrackId)` を呼ぶ。
  - `ux-sync-transfer-progress` で進捗表示（既存 UI を流用）。
  - 完了後に統一ライブラリを再取得し、その曲を local として再生に遷移する。
  - 失敗時はエラートーストを出し、再生しない。

### テスト（Red 先行）
1. `DownloadSyncTrack`: catalog の remote 曲を peer から取得・import し、local path を返す。
2. 取得元 peer 未到達 / token 無しでエラーを返す。
3. フロント: remote 曲の再生で `DownloadSyncTrack` が呼ばれ、完了後に local 再生へ遷移する（モック）。
4. フロント: DL 失敗時はエラー表示で再生に入らない。

---

## Phase 4: スマート先読みキャッシュと容量ポリシー

### 設計

端末設定:
- `syncCachePolicy`（settings）: `"mirror"`（既定・現行どおり全曲）/ `"selective"`（先読み対象のみ）。
- UX Sync 専用設定の「保存」タブに選択 UI を追加する。
- 既定は `mirror`（現行挙動を変えない）。Portable Client は `selective` を選ぶ。

AutoSync のプル分岐（`AutoSyncPairedDevices`）:
- `mirror`: 現行どおり `PullSyncLibraryAssets(baseURL, 0)`（全曲）。storage-safety pause は既存どおり。**LRU 削除は行わない**（全部持つ意図のため）。
- `selective`: 全曲 pull をやめ、プリフェッチ対象の remote 曲だけを取得する。

プリフェッチ対象（`selective` のみ）:
- **最近再生**: `playcounts` の history から最近 N 曲（remote のもの）。バックエンドの自動同期ループで実行。
- **キュー先読み**: フロントが現在キューの次 M 曲（remote）を新メソッド `PrefetchSyncTracks(refs)` で要求し、backend が `DownloadSyncTrack` 群を実行する。

LRU 削除（`selective` のみ）:
- 空き容量 < `syncMinFreeSpaceGB` のとき発動する。
- 対象は同期取得した音源（`syncSourceDeviceId` 付き）。最終アクセス（`playcounts` history の最終再生時刻を recency 代理に使う。未再生は最古）が古い順に削除する。
- 削除は**音源ファイルと `library.json` エントリ**を消す。catalog から再び remote として表示される（再生ボタンで再 DL 可能）。
- 再生回数は `playcounts`（path キー）として残し、`downloadSyncTrackAsset` の保存先 path が決定的なため、再 DL 時に同じ path へ再関連付けされる。
- 現在再生中の曲は最終アクセスが最新になるため LRU で残る（明示ピン留めは設けない）。

### テスト（Red 先行）
5. `syncCachePolicy="selective"`: AutoSync が全曲 pull せず、最近再生の remote 曲のみ pull する。
6. `syncCachePolicy="mirror"`（既定）: 現行どおり全曲 pull する。
7. 最近再生プリフェッチ: history 上位の remote 曲が取得対象になる。
8. `PrefetchSyncTracks`: 指定 remote 曲が取得される。
9. LRU: 空き容量 < 閾値 のとき、最終アクセス最古の同期音源が削除され、`library.json` から除外される（再 unified で remote 表示）。
10. LRU は `mirror` では発動しない。

---

## バージョン

Phase 3 / Phase 4 それぞれで新機能追加のため `PhaseVer` を +1、`SubVer` を `a` にリセットする。

## ドキュメント更新

`markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を同期する。
