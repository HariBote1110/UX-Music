> **このドキュメントは廃止済みです（2026-08-11）。**
> 旧 `/sync/*`（無版）プロトコルの実装計画です。LAN API v1 統一（`progress/lan-api-v1.md`）により `/v1/sync/*` へ再編済みです。

# UX Sync 実機検証バグ修正計画（重複 / アートワーク / 相互ペアリング）

## 背景

実機（Mac mini host + MacBook Air client, Wi-Fi）検証で、再生・同期・mp3化・再生回数収束は動作したが、3つのバグを確認した。実データ調査（mini/Air 双方の `/sync/library/snapshot` と artwork エンドポイントを直接確認）で原因を特定済み。

## Issue 1: 統一ビューでリモート（DL可能）曲が重複していく

**根本原因（renderer）**: `src/renderer/js/ui/ui-manager.ts:296-317` の load-library 処理が **path をキーに増分マージ追記**し、消えたエントリを削除しない。
- リモート曲は `path` を持たない（`GetUnifiedLibrary` が remote から path を削除）。
- ダウンロードすると local 版が **新しい id（`uuid.NewString()`）＋ path** で来る。
- 旧 remote エントリ（DL可能バッジ）が `state.library` に残ったまま、新 local エントリが追加され**重複**する。ダウンロードを重ねるほど増える。
- バックエンドの `GetUnifiedLibrary` は `matchKey` dedup 済みで正しい（実データで Air ローカル全曲の matchKey が mini snapshot に一致することを確認）。renderer がその dedup 結果を無視して旧状態にマージしているのが問題。

**修正**: load-library が完全な統一ライブラリを運ぶケースでは `state.library` とインデックス（libraryById/libraryByPath）を **置換（再構築）** する。最低限、適用前に「今回のペイロードに無い旧エントリ」を除去する。migration / 既存の増分用途を壊さないよう、`GetUnifiedLibrary` 由来の全量ロードであることを示すフラグ等で分岐してよい。

**テスト（renderer）**: load-library を remote 版 → local 版（同一 matchKey、path 付与）の順で流し、最終的に当該曲が **1 件（local, バッジ無し）** になり stale remote が残らないこと。

## Issue 2: ダウンロード曲にアートワークが付かない（メタデータ未同期）

**根本原因（pull の非対称）**: PUSH 受信（`importSyncUploadedTrack`）は multipart で artwork を受け取り保存するが、**PULL（`downloadSyncTrackAsset`）は audio しか取得しない**。snapshot の `syncArtwork` 記述子（peer 側ファイル参照）だけがコピーされ、実画像が client に無い（Air の `/sync/assets/{id}/artwork` が全曲 404 を確認）。
- 音声タグ（title/artist/album/duration 等）は snapshot 経由で正しく同期されている（確認済み）。欠けているのは**カバー画像**。
- バックフィル `syncMissingArtworkFromPeer` は存在するが、(a) reachable 時の auto-sync でしか動かず tap-DL 直後は無い、(b) 1 件の非 not-found エラーで `return changed, err` し全体が中断し得る。

**修正**:
- `downloadSyncTrackAsset`（tap-DL / pull / prefetch / selective 自動同期が共用）で、audio 取込後に `downloadSyncArtworkAsset(ctx, baseURL, token, identity.DeviceID, trackID)` を呼び、成功時 `track["artwork"]` をセットしてから `upsertSyncImportedTrack`。artwork 取得失敗・not-found でも audio 取込は成功させる（ベストエフォート）。
- `syncMissingArtworkFromPeer` は per-track のエラーを `continue`（ログのみ）にして全体 abort しない。

**テスト**: 単曲 DL で artwork が保存される（stub）。artwork 取得失敗でも audio 取込は成功し path を返す。

## Issue 3: ペアリングが片側だけ（された側が何も分からない）

**根本原因**: `server/app_sync.go:497-509` の confirm ハンドラは、initiator を known peer に保存するのが `detail.BaseURL != ""` の時だけ。initiator が自分の `deviceId` / `displayName` / reachable baseURL を伝えていないため、**受信側は相手を一切記録できず**、相手へ同期する導線も UI 表示も無い。
- 結果、initiator 側だけが token＋known peer を持ち、受信側は「何も分からない」。
- 受信側は initiator 用 token を `ensureSyncAuthTokenForDevice` で発行・保持済みだが、known peer（baseURL）が無いので使えない。

**修正（相互ペアリング）**:
- initiator は `/sync/pairing/start`（および `/sync/pairing/confirm`）に自分の `deviceId` / `displayName` / reachable `baseURL`(host:port) を含める。Wails 側 `StartSyncPairing` / `ConfirmSyncPairing` は自端末の deviceId・表示名・LAN baseURL を付与する。
- 受信側は session detail に initiator の情報を保持し、confirm 成功時に**必ず** known peer（baseURL 付き）を保存する。token は `ensureSyncAuthTokenForDevice` の共有値（現仕様は値一致で受理するため、同一トークンで双方向に通る）。
- これで両側が「known peer ＋ 受理可能トークン」を持ち、双方向 auto-sync（再生回数収束、mini→Air の push 等）が機能する。
- 受信側 UI は確定検知後にデバイス一覧／同期元セレクトを再描画（emit など）。リアルタイム通知が難しければ次回「探索」で出ればよい（known peer に入るため）。
- 後方互換: initiator 情報を送らない旧 client でも従来どおり動作（落ちない）。

**テスト**: confirm 後、受信側 settings に initiator が baseURL 付き known peer として保存される。initiator 情報なしの旧形式でも 200 を返す。`manual`/discovery 双方の開始経路で baseURL が送られる。

## バージョン

不具合修正のため各対応で `SubVer` を進める（Issue 3 は受信側に機能が増えるため `PhaseVer` +1 でもよい）。

## ドキュメント更新

`markdown/ux-music-sync-protocol.md`（pairing start/confirm に initiator 情報を追加、pull が artwork も取得する旨）、`markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/ux-music-sync-plan.md` を同期。
