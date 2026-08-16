> **このドキュメントは廃止済みです（2026-08-11）。**
> 旧 `/sync/*`（無版）プロトコルの実装計画です。LAN API v1 統一（`progress/lan-api-v1.md`）により `/v1/sync/*` へ再編済みです。

# UX Sync 再生回数収束 実装計画

## 背景と目的

UX Music Sync の主目的は「複数マシン間で曲のずれをなくし、再生回数を同期する」「起動時にバックグラウンドで勝手に同期する」ことである。バックグラウンド自動同期 (`startSyncAutoLoop`) は既に存在するが、再生回数の同期に概念とのズレがある。本計画はそのズレを解消する。

詳細仕様は `markdown/ux-music-sync-protocol.md` を正とし、本書はその実装方針を補う。

## 現状のズレ（根本原因）

### 1. 曲のクロスマシン同一性が存在しない（本丸）
- 曲の `id` は `uuid.NewString()`（`server/app_scanner.go`）でマシンごとにランダム。同じ物理曲でも端末間で別 ID。
- 再生イベントは送信側 trackID を載せ、受信側は `syncLibraryPathByTrackID()`（ローカル id / syncSourceTrackId / path のみ）で突合する。
- そのため、受信側がその曲を **sync 経由で pull 済み**（`syncSourceTrackId` に送信側 id が入る）でないと一致しない。両機が同じ曲を別々に取り込んでいると永遠に一致せず、
  - 再生回数が同期されない。
  - `firstNonEmpty(pathByTrackID[trackID], trackID)` により、**実在しない trackID をキーにした幽霊 playcounts エントリ**が溜まり続ける（`server/app_sync_auto.go` の `applyIncomingSyncPlayEventsToPlayCounts`）。

### 2. 再生回数の真実の源が二重化している
- 表示用 `playcounts`（path キー、ローカル再生で直接 +1、かつ受信イベントで加算パッチ）と `syncPlayEvents` ログが別管理で再突合されない。
- プロトコル文書は「再生回数はイベントログから導出する」と明記しているが、実装は count レベルの加算マージ。途中失敗や片方リセットで恒久的にズレる。

## 方針（確定事項）

- 曲の同一性キー: **メタデータキー優先**。
- スコープ: **#1（安定同一性）＋ #2（イベントログ単一ソース化）をまとめて**実装する。
- 開発手法: TDD（Red / Green / Refactor）。コード内英語は英式綴り。コミットは日本語。

## 実装内容

### A. 安定同一性キー（メタデータベース）

新規ヘルパー（例: `server/app_sync_match.go`）:

```go
func syncSongMatchKey(song map[string]interface{}) string
```

- `title` / `artist` / `album` を正規化: Unicode NFKC → 小文字化 → trim → 連続空白を 1 個に圧縮。
- `duration` は秒へ四捨五入した整数。欠落・0 は `"0"` として扱う。
- キーは `artist|album|title|durationSec` を結合し、安定化のため sha1 hex 等にする。
- `title` 等が全て空のときのみ `filepath.Base(path)` を fallback に含めてよいが、基本はメタデータのみ。

### B. PlayEvent に matchKey を載せる

`internal/uxsync` の `PlayEvent` に `MatchKey string` (`json:"matchKey,omitempty"`) を追加。

- `recordLocalSyncPlayEvent` で `syncSongMatchKey(song)` を計算してセットする。
- `EventID` / `DeviceID` / `DeviceSequence` / `TrackID` は維持し、冪等 dedup は従来どおり eventID 基準。
- 後方互換: `matchKey` が空の旧イベントは、受信側で従来の trackID → path 索引でフォールバック突合する。

### C. 受信側マッピング: 幽霊エントリ排除

- `syncLibraryPathByMatchKey()`（matchKey → path）を追加。
- 突合順序: ① `event.MatchKey` → path、② フォールバックで `event.TrackID` → path（既存索引）。
- どちらでも一致しなければ **playcounts に書かない**（skip）。イベントログには保持する（曲が後から来れば反映できる）。

### D. 再生回数をイベントログから導出（単一ソース化）

`syncPlayEvents` ログを「同期対象の確定再生」の唯一の真実とし、`playcounts` はそこからの射影にする。

- `playcounts[path].count = base[path] + logCount(path)`
  - `base[path]`: 同期イベント導入前から存在した再生回数のスナップショット。新規ストア（例: `playcounts_base`）に保存。
  - `logCount(path)`: dedup 済みイベントログのうち、matchKey（or trackID フォールバック）が当該 path に解決される件数。
- `IncrementPlayCount`: 直接 `+= 1` をやめ、PlayEvent を記録 → 当該 path を再計算 → `playcounts` 保存 → イベント発火。
- 受信 `/sync/library/events`: ログへ dedup マージ → 影響を受けた path を再計算。

#### 一度きりの移行（冪等）

旧 `playcounts` の数値を失わず、かつ既存イベントとの二重計上を避けるため:

```
migration（store にバージョン/フラグを持たせ 1 回だけ実行）:
  for each path in playcounts:
      existingLogCount = 当該 path に解決される dedup 済みイベント件数
      base[path] = max(0, currentCount[path] - existingLogCount)
  mark migrated
```

これにより移行直後の表示値は不変、以後は `base + logCount` が正しく増える。

## テスト（TDD・Red を先に）

1. `syncSongMatchKey`: 大小文字 / 全角半角 / 連続空白差を吸収し同一キー。duration 丸め。
2. 異なる曲は異なるキー。
3. メタ一致の別マシン由来イベントが、**pull 未経由でも**ローカル曲の playcounts に反映される。
4. 同一 eventID の再 push で二重加算されない（冪等）。
5. 該当曲が無いイベントは playcounts に幽霊エントリを作らない（ログには残る）。
6. 移行: 既存 count が保存され、移行後の再計算で値が変わらない（`base = count - existingLogCount`）。
7. 双方向同期で両機の各曲 count が同値に収束する。
8. 旧イベント（matchKey 空）は trackID フォールバックで従来どおり突合できる。

## バージョン

新機能追加のため `package.json` の `PhaseVer` を +1 し `SubVer` を `a` にリセットする。

## 対象外（本計画では扱わない）

- WebSocket 再生移行、圧縮アセット生成、プレイリスト同期、お気に入り同期。
- 既に動作しているバックグラウンド自動同期ループ自体の作り替え。
