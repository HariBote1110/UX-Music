> **このドキュメントは廃止済みです（2026-08-11）。**
> 旧 `/sync/*`（無版）プロトコルの実装計画です。LAN API v1 統一（`progress/lan-api-v1.md`）により `/v1/sync/*` へ再編済みです。

# UX Sync 再生回数メタデータ先行同期計画

## 背景

実機検証で、Mac mini 側の `playcounts` は健在（例: 699曲 / 合計4772回）だが、MacBook Air 側は新規再生イベント由来の少数しか持たず、未DL曲や既存DL曲の再生回数が大きくズレることを確認した。

原因は、`PlayEvent` による新規再生イベント同期は動いている一方で、mini が過去から持っている既存再生回数（`playcounts-base` 由来を含む）が remote catalog / pull 側へ渡っていないこと。

既に push 転送では `syncPlayCount` を metadata に同梱するヘルパーがあるが、snapshot / pull / remote 表示には反映されていない。

## 目的

曲本体は必要な時に取得しつつ、再生回数はメタデータとして最初から同期・表示できるようにする。

- remote（DL可能）曲にも、mini 側の再生回数を表示する。
- 既にDL済みの同期曲は、次回 snapshot / pull skip 時に mini 側の再生回数をローカル `playcounts` へ反映する。
- 新規DL時も、音源取込と同時に `syncPlayCount` をローカル `playcounts` へ反映する。
- ローカル原本と同じ曲を peer から逆輸入 skip する場合は、peer 側の count で原本を上書きしない（再生イベント同期を正とする）。

## 実装方針

1. `/sync/library/snapshot` の各 track に、対象 path の `playcounts` がある場合 `syncPlayCount` を付与する。
   - 既存 `attachSyncPlayCountForTransfer` / `normaliseSyncPlayCountForTransfer` を再利用する。
   - `library.json` には `syncPlayCount` を永続化しない。

2. `downloadSyncTrackAsset` で `upsertSyncImportedTrack` 後、`applySyncImportedPlayCount(track, destPath)` を呼ぶ。
   - `syncPlayCount` は `upsertSyncImportedTrack` が library へ残さない既存仕様を維持する。

3. `PullSyncLibraryAssets` が既に `syncSourceDeviceId` / `syncSourceTrackId` 付きで取り込み済みの track を skip する場合、既存 import path へ `syncPlayCount` を反映する。
   - これにより既存DL済み曲も、音源再取得なしで再生回数が追従する。

4. renderer の再生回数表示は `state.playCounts[song.path]` を優先し、無い場合は `song.syncPlayCount.count` を fallback とする。
   - remote 曲は path を持たないため、この fallback でDL前から count を表示する。

## テスト

1. snapshot が `playcounts` を `syncPlayCount` として含める。
2. 新規 pull import が `syncPlayCount` を取り込み先 path の `playcounts` へ反映する。
3. 既に import 済みの曲を pull skip する場合も、`syncPlayCount` が既存 path へ反映される。
4. ローカル原本と matchKey が一致して逆輸入 skip する場合、peer の `syncPlayCount` で原本 count を上書きしない。
5. renderer が remote 曲の `syncPlayCount.count` を表示する。

## バージョン

メタデータ先行同期の新機能として、renderer を `1.0.0-Beta-32a`、仕様書を `0.1.9-Beta-35a` へ進める。
