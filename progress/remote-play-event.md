# POST /v1/remote/play-event（Phase 3-2 サーバー側）

## Decision

- **エンドポイント**: `POST /v1/remote/play-event`（認証必須、`/v1/identity`・`/v1/pairing/*` のような公開エンドポイントにはしない）。
  - リクエスト: `{"trackId": "<ライブラリの曲id>", "playedAt": "<RFC3339>", "durationPlayedSec": <number, optional>}`。
  - `trackId` はローカルライブラリの `id`（または `path`）を `remoteLibrarySongByID`（`server/app_remote_lyrics_playlists.go`）で解決する。既存の `/v1/remote/file` 等と同じ解決規則を再利用し、TV 側専用の別解決ロジックは作らない。
  - `playedAt` は必須・RFC3339 パース必須（不正 or 欠落は 400）。`durationPlayedSec` は省略可（省略時は `durationPlayedMs: 0` の完了イベントとして扱う）。
  - レスポンス: `{"trackId","matchKey","count"}`（`count` は収束後の playcounts エントリの現在値）。
- **収束経路の再利用**: `trackId` から曲を引いた後は `syncSongMatchKey` で matchKey を付与し、`uxsync.PlayEvent` を構築 → `uxsync.MergePlayEvents` → `sync-play-events` ストア保存 → `recalculateAllSyncPlayCounts()` → `a.emitPlayCountsUpdated()`。これは `syncLibraryEventsHandler`（デスクトップ間 sync 受信）や `recordLocalSyncPlayEvent`（ローカル再生）と同じ関数群であり、新規の収束ロジックは一切書いていない。
- **デバイスアイデンティティ**: 生成する `PlayEvent.DeviceID` は **このホスト自身の `ensureSyncDeviceID()`** を使う。TV 側から渡された deviceId や、Authorization トークンからの逆引きによる「TV 固有の deviceId」は使わない。
  - 理由: この報告は「TV が Sync ピアとして自分のイベントを送ってくる」のではなく、「ホストが自分のライブラリで完了した再生を代理で記録する」操作である（計画書 3-2 に明記の通り「TV を Sync ピアにせず収束へ参加させる」）。ホスト自身の deviceId を使うことで、このイベントはホストの既存 outbox シーケンス（`nextSyncDeviceSequence`）にそのまま乗り、`flushSyncPlayEventsToReachablePeers` 経由で他のデスクトップへも通常のローカル再生と同じ経路で伝播する。
  - もし TV ごとに新しい deviceId を発行する設計にすると、(a) `deviceAuthTokens` はトークン→deviceId の逆引きを持たないため新しいマッピングを追加する必要があり、(b) 収束は `matchKey`/`trackId` 単位であって `deviceId` 単位ではないため、再生回数の正しさには寄与せず複雑さだけが増える。よって不採用。
- **冪等性（重複配信対策）**: `uxsync.PlayEvent.EventID` はリクエストの内容（`deviceId + "|" + trackId + "|" + playedAt(UTC RFC3339)`）から SHA-1 で決定的に導出する（`remotePlayEventID`）。
  - 理由: `POST /v1/remote/play-event` のリクエストスキーマ（`trackId`/`playedAt`/`durationPlayedSec`）には `/v1/sync/library/events` のようなクライアント生成 `eventId` フィールドが無い。将来 TV クライアントが独自の `eventId` を送るようになれば、そのまま `event.EventID` として採用するよう切り替えられる（`remotePlayEventID` の呼び出し1箇所を差し替えるだけで済む）。
  - 既存の `uxsync.MergePlayEvents` は `eventIdentity(event)`（`EventID` があればそれをキーに、無ければ `deviceId:deviceSequence`）で重複排除する。決定的な `EventID` により、同一内容のリクエストを再送しても常に同じ `EventID` が生成され、2回目以降は `MergePlayEvents` で自動的に捨てられる（ストアのイベント数・playcounts のどちらも増えない）。

## Alternatives considered

- **`trackId` をそのまま `deviceId` に流用**、または呼び出し元の IP から仮想 deviceId を作る → 収束はホスト単位の outbox で完結するため不要な複雑化。却下。
- **`durationPlayedSec` の有無で `Completed` を分岐**（時間が短ければ未完了扱い） → このエンドポイントは「完了した再生の報告」という契約（計画書 3-2 も「再生完了を Host に報告」と明記）なので、常に `Completed: true` とし、`durationPlayedSec` は参考値（`DurationPlayedMs`）としてのみ保存。`isCountedPlay` は `Completed || DurationPlayedMs >= 30000` なので、どのみち `Completed: true` であれば必ずカウントされる。
- **冪等性キーを `sha1(...)` ではなく `trackId+playedAt` のみにする**（deviceId を含めない） → 将来ホストが複数台稼働する多重化構成は想定していないため実害はないが、他の PlayEvent 生成箇所（`recordLocalSyncPlayEvent` 等）が全て `deviceId` を eventId の一部にしている慣習に合わせ、含める形にした。

## Constraints / Gotchas

- レスポンスの `count` は `playcounts` ストアの `path` キー経由（`syncSongMatchKey`→`syncLibraryPathByMatchKey`／`trackId`→`syncLibraryPathByTrackID` の解決チェーン）で求めているため、同じ曲を指す `matchKey` の解決に失敗する状態（ライブラリの artist/album/title/duration が空でパスからのフォールバックに頼っている等）では `count` が 0 のまま返る可能性がある。挙動自体は既存の sync 収束と同じなので本エンドポイント固有の欠陥ではない。
- クライアント（Apple TV）側の実装はスコープ外。将来 TV アプリが本エンドポイントを叩く際は、`Authorization: Bearer <deviceAuthTokens 経由のトークン>` を付与し、`playedAt` は必ず UTC の RFC3339 で送ること。
- Watch/Mobile も将来この経路に統一される可能性があるが、本チケットでは `/v1/remote/play-event` の新設のみを行い、既存の `IncrementPlayCount`（ローカル再生用 Wails バインディング）や `/v1/sync/library/events`（デスクトップ間 sync）は変更していない。
