# 「あなたへ」（For You）レコメンドバケット再設計

## 背景: プレイリストコラージュが壊れていた根本原因

`RequestPlaylistsWithArtwork`（`server/app_playlist.go`）が
`song["artwork"].(string)` で直接型アサートしていたが、ローカルスキャン済み
楽曲の `artwork` は `internal/scanner/artwork.go`（`extractAndSaveArtwork` /
`PersistArtworkBytes`）が返す `{"full": "...", "thumbnail": "..."}` という
ネストしたマップであり、YouTube楽曲（`app_youtube.go`）だけがプレーン文字列
だった。型アサーションが常に失敗するため、ローカル曲だけのプレイリストの
コラージュは常に空になっていた（`app_queue.go` の Now Playing 用コードは
既にマップ形式を正しく扱っており、バグは `app_playlist.go` 側のみ）。

## 決定: 共有ヘルパーへ抽出

`server/artwork_helpers.go` に2つの純粋関数を新設し、`app_playlist.go` の
`RequestPlaylistsWithArtwork` と `situation_playlists.go` の
`generateSituationPlaylists` の両方から使う。

- `artworkPathFromSong(song) string` — マップ形式（`map[string]interface{}`
  と、JSONラウンドトリップ前の `map[string]string` の両方に対応）は
  thumbnail優先・fullへフォールバック、文字列形式（YouTube）はそのまま返す。
- `collageArtworks(songs) []string` — アルバム単位で重複排除し、最大4枚まで。
  水増しはしない（4枚未満ならそのまま4枚未満を返す。フロント側は4枚未満なら
  単一画像表示にフォールバックする前提）。

## 「あなたへ」バケットのゲートと構成

`generateSituationPlaylists(songs, counts, now time.Time) []situationPlaylistBucket`
（`server/situation_playlists.go`）が唯一の生成ロジックで、Wails版
`GetSituationPlaylists`（`app_playlist.go`）とLAN API版
`remoteSituationPlaylistsHandler`（`app_remote_lyrics_playlists.go`）の
両方が共有する。空になったバケットは黙って省く。

固定表示順序（該当するもののみ）:

1. **recently_added**（最近追加した曲） — ライブラリ末尾から新しい順。曲が
   1件でもあれば必ず出る。
2. **most_played**（よく聴く曲 / 最近再生した曲） — `playcounts[path].count`
   が1件でもあれば「よく聴く曲」。無ければ `lastPlayed`
   （後述）から「最近再生した曲」にフォールバック。両方無ければ省略。
   旧実装は再生回数が無いと即座に諦めていたが、初日でも「最近再生した」で
   埋まるようにした。
3. **random_pick**（ランダムピック） — ライブラリの下限を **5曲→2曲** に
   緩和。ストライド抽出（`len/limit` 間隔）は変更なし。
4. **rediscover**（聴き返したい曲） — `count > 0` かつ、
   `lastPlayed` が30日以上前 **または** `lastPlayed` 自体が無い（履歴移行前
   の古いデータで「最近聴いていない」と断定はできないが、断定できる材料も
   無いので緩めに拾う）曲。`lastPlayed` 昇順（＝最も長く聴いていない曲が
   先頭）。
5. **artist_spotlight**（〈アーティスト名〉の特集） — アーティストごとの
   総再生回数で重み付きルーレット選択（`dailySeed` でシード、後述）。
   再生回数がゼロのアーティストは対象外。
6. **album_deep_cut**（アルバムの隠れた名曲） — アルバムごとの総再生回数で
   降順ランキングし、上位アルバムから曲を「再生回数が少ない順」で埋める。
   総再生回数ゼロのアルバムは対象外。
7. **genre_mix / decade_mix** — `genre` フィールドが1件でもあればジャンルを
   1つ `dailySeed` で選び `genre_mix`。無ければ `year` から10年単位の
   decade を1つ選び `decade_mix`。どちらも無ければ省略。

各バケットには `description`（短い日本語説明。例:
「最近ライブラリに追加した曲」）と、`collageArtworks` で埋めた最大4件の
`artworks` を付与する。

## `lastPlayed` はストアを増やさず既存の `playcounts.history` から導出

grep で `playhistory` / `lastplayed` 相当の既存ストアを探したところ存在
しなかったが、`IncrementPlayCount` が毎回呼ぶ
`recordLocalSyncPlayEvent` → `recalculateAllSyncPlayCounts`
（`app_sync_auto.go`）が `playcounts[path]["history"]` に RFC3339
タイムスタンプを既に積んでいることが分かった。そのため新規ストアは追加
せず、`lastPlayedByPath(counts)`（`situation_playlists.go`）で
`history` 内の最大時刻を都度算出する。既存フローが正しく動いていれば
`IncrementPlayCount` 経由の再生には必ず `history` が付くため、通常の
利用では `count > 0` かつ `history` 欠落、というケースは同期由来の
移行データなど例外的な場合のみ。

## seed 戦略: 日次で安定、リロードでは揺れない

`artist_spotlight` の重み付き抽選と `genre_mix`/`decade_mix` の選択は
`dailySeed(now) = now.UTC().Truncate(24h).Unix()` から作った
`math/rand.Source` を使う。同じUTC日内は常に同じ結果、日付が変わると
再抽選される。`math/rand`（`crypto/rand` ではない）で十分 — レコメンド
選定であり秘匿性は不要。

## テスト方針

すべて `[]map[string]interface{}` + `playcounts` マップ + `now time.Time`
+ `seed int64` を受け取る純粋関数として実装し、`store.Instance` 無しで
単体テスト可能（`server/situation_playlists_test.go`）。既存の
`TestGenerateSituationPlaylists_OrderAndOmitsEmpty` と LAN API側の
`TestRemoteSituationPlaylistsHandler_ReturnsFixedOrderWithSongIDs`
（`server/app_remote_situation_playlists_test.go`）は、ゲート緩和と
新バケット追加に伴い期待するバケット数・順序を更新済み（旧仕様の
「3曲未満はランダムピック省略」という固定化されたテストは、今回の
意図的な仕様変更の一部として書き換えた）。
