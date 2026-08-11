> **このドキュメントは廃止済みです（2026-08-11）。**
> 旧 `/sync/*`（無版）プロトコルの実装計画です。LAN API v1 統一（`progress/lan-api-v1.md`）により `/v1/sync/*` へ再編済みです。

# UX Sync Phase 2 実装計画: 統一ライブラリビュー

## 背景と目的

UX Music Sync の完成系は「ストリーミングプラットフォーム的体験（ただし LAN ローカルファースト）」。再生モデルは **ダウンロード優先のシームレス化**で実現する（[[project_sync]] の確定方針）。

- Phase 1（実装・実機検証済み）: 再生回数収束。曲のクロスマシン同一性を `syncSongMatchKey`（メタデータ正規化＋SHA-1）で判定し、再生回数をイベントログから導出する単一ソース化。詳細は `markdown/sync-playcount-convergence-plan.md`。
- **Phase 2（本計画）: 統一ライブラリビュー。** 音源がローカルに無いリモート曲も一覧に表示し「DL可能」とマークする。Phase 3（シームレス DL 再生）/ Phase 4（先読みキャッシュ）の土台。

## 現状の課題

現状は「pull（音源 DL ＋取込）して初めて `library.json` に載る」モデルで、未 pull の曲はクライアントに見えない。`LoadLibrary()` は `library.json`（実ファイルのみ）を読んで `load-library` イベントで renderer に渡す。`/sync/library/snapshot` は host の全曲メタデータ（artwork blob 無し）を返す基盤が既にある。

## スコープ（確定）

対象:
- リモートカタログ（peer の snapshot）の取得・キャッシュ。
- 表示時マージ（`syncSongMatchKey` で dedup）。
- リモート曲への `syncAvailability` マークと UI バッジ「DL可能」。
- リモート曲のアートワークは**プレースホルダのみ**。

対象外（後続フェーズ）:
- リモート曲の DL 操作・再生（Phase 3）。
- リモート曲の実アートワーク取得（Phase 4）。

## 設計

### データモデル

- 新ストア `sync-remote-catalog`（マップ: `peerDeviceId -> { displayName, baseUrl, generatedAt, tracks[] }`）。`tracks` は snapshot のメタデータ（artwork blob 無し）。
- `library.json` には**リモート曲を混ぜない**（scanner / playback / normalize 等が全走査するため、汚すと壊れやすい）。リモートは別ストア＋表示時マージで扱う。

### バックエンド

1. **カタログ更新** `refreshSyncRemoteCatalog()`:
   - `AutoSyncPairedDevices()` 内で、到達可能な LibraryHost peer の `/sync/library/snapshot` を取得し `sync-remote-catalog` の当該 peer エントリへ保存する。
   - 取得失敗時は握りつぶし、既存キャッシュを温存する。
   - 空き容量安全停止（`library.storage-safety.v1`）の対象外（メタデータのみで容量を使わないため）。

2. **統一ビュー取得**: `LoadLibrary()` を拡張（同じ `load-library` イベントで返す）、または新メソッド `GetUnifiedLibrary()` を追加する。マージ規則:
   - local library をロードし、各曲に `syncAvailability: "local"` を付ける。
   - 各 local 曲の `syncSongMatchKey` 集合を作る。
   - remote catalog の各 track について `syncSongMatchKey`（**クライアント側で計算**。snapshot track のメタデータに同じ正規化を適用するので peer 非依存で確実）を求め、local の matchKey 集合に**無いものだけ**を追加する。
     - 追加するリモート曲には `syncAvailability: "remote"`、`syncSourceDeviceId`、`syncSourcePeerName`、`syncSourceTrackId`（snapshot の `id`）を付ける。`path` は持たせない（または空）。
   - 複数 LibraryHost peer のカタログは union し、同一 matchKey のリモート曲は1件に集約する（取得元が複数でも Phase 2 では1件でよい）。

3. **手動更新** `RefreshSyncRemoteCatalog()`（任意・UI ボタン用）。

留意:
- dedup は matchKey のみで行う（リモートは別マシンの id なので trackID/path フォールバックは無意味）。
- リモート曲の `id` は UI 選択キーに snapshot の host id をそのまま使う（local uuid と実質衝突しない）。

### フロントエンド

- `load-library`（または新イベント）で受け取った各曲の `syncAvailability` を反映する。
- `syncAvailability === "remote"` の曲に「DL可能」バッジを表示し、アートワークはプレースホルダにする。
- リモート曲は再生アクションの対象外にする（クリックは無効、または「Phase 3 で対応予定」トースト程度）。既存のソート/フィルタを阻害しないこと。

## テスト（TDD・Red を先に）

バックエンド:
1. `GetUnifiedLibrary`: local のみ → そのまま、各曲 `syncAvailability="local"`。
2. remote catalog に local 未保有の曲 → unified に `syncAvailability="remote"` で1件追加される。
3. local と remote に同一曲（matchKey 一致）→ 1件のみ・local 優先（再生可・availability=local）。
4. 複数 peer の同一リモート曲 → 1件に集約される。
5. `refreshSyncRemoteCatalog`: snapshot 取得結果が catalog に保存される／取得失敗時は既存キャッシュ温存。

フロント:
6. `syncAvailability="remote"` の曲に「DL可能」バッジが付く／アートワークがプレースホルダ。
7. リモート曲は再生アクション対象外（または適切に無効化）。

## バージョン

新機能追加のため `PhaseVer` を +1、`SubVer` を `a` にリセットする。

## ドキュメント更新

`markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/roadmap.md`、`markdown/ux-music-sync-plan.md` を統一ライブラリビュー仕様へ同期する。
