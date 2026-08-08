# Mobile版 Desktop機能パリティ（検索・並び替え・アーティスト・For You・シャッフル/リピート・キュー編集・和訳）

## 背景

Mobile と Desktop の機能差を洗い出したところ、「Mobile に無くて実際に困る」ものは以下に絞られた。
CDリッピング・MTP転送はハード要件的に不可、メタデータ編集・ラウドネス解析・YouTubeダウンロード・LRCエディタ・
TXT自動同期は「Desktop がライブラリの所有者、Mobile はそのクライアント」という設計上 Mobile に持たせるべきでない、
と判断して対象外とした。

対象にしたもの:

- 優先度高: シャッフル/リピート、検索、アーティストビュー
- 優先度中: キュー編集、ソート順、For You（シチュエーション別プレイリスト）
- 別枠（優先実装の要望あり）: 歌詞の和訳表示
- UI: リスト時のアートワークのまとめ方と、ナビゲーション構成の Desktop 寄せ

## Decision

### 1. 和訳は Desktop のサイドカーを LAN API で配信する

`internal/lyrics.FindLyrics` は以前から `{base}.ja.lrc` / `{base}.ja.txt` を読んで
`translationContent` / `translationFormat` を返していたが、`remoteLyricsHandler` が `type` と `content` しか
転送せず**その場で捨てていた**。ここを素通しさせるだけで Mobile 側の実装が可能になる。

和訳の生成（LLM プロンプト作成と貼り付け解釈）は Desktop に残す。Mobile は表示専用。

- 和訳が無い場合はキー自体をレスポンスから省く。空文字列を送ると、古いクライアントの
  `decodeIfPresent` が「和訳あり（空）」と誤認するため。
- 行の対応付け規則（タイムスタンプ一致→位置フォールバック、間奏行には訳を付けない）は
  `src/renderer/js/features/lyrics-translation.ts` を `Core/LyricsTranslationMerger.swift` に移植し、
  Desktop と同じ見え方になるようにした。

### 2. `LocalLyricsDisplayMode` は変更せず `BilingualLyricsDisplayMode` を並行追加した

既存 enum の associated value を差し替えると歌詞画面の `switch` が全面的に壊れる。
`AppModel.localBilingualLyricsDisplay(for:)` を別 API として足し、画面側が段階的に移行できる形にした。

### 3. For You は LAN API 経由で Desktop の生成結果を取得する

シチュエーション別プレイリストの生成は Desktop の解析データ（`playcounts` 等）に依存するため、
Mobile で再実装しない。ただし `(*App).GetSituationPlaylists` は Wails バインドのみで HTTP に露出していなかったので、
`GET /v1/remote/situation-playlists` を新設した。

- レスポンスは既存の `/v1/remote/playlists` と同形の `[{name, songIds}]` に揃えた。
- 生成ロジックは `generateSituationPlaylists(songs, counts)` に切り出して Wails 版と共有。
  `GetSituationPlaylists` の戻り値の形（`recently_added` / `most_played` / `random_pick` をキーとする map）は
  renderer が依存しているため変更していない。
- ローカルの `Playlist` レコードは作らない。サーバー生成の読み取り専用リストとして扱う。

### 4. シャッフル/リピートは Watch 側の純粋ロジックを汎用化して流用した

`Core/WatchPlaybackLogic.swift` に `WatchRepeatMode` / `WatchQueueNavigation.autoAdvance` /
`WatchShuffleLogic` が既にあり、Watch だけで使われていた。`Playback*` へ改名して iPhone 側でも使い、
旧名は `typealias` で残して watchOS ターゲットと既存テストを無変更に保った。

**副次的に不具合が1件直っている**: `MusicPlayerService.next()` が `(currentIndex + 1) % queue.count` で
あったため、**リピートを OFF にできず必ずループしていた**。自然終了を `autoAdvance` 経由にしたことで、
リピート OFF ならキュー末尾で停止するようになった。明示的な `next()` / `previous()` は従来どおり
ラップする（クラシックなメディアプレーヤーの挙動）。

### 5. アートワークのまとめ方は Desktop の連結線をそのまま再現した

Desktop（`src/renderer/js/ui/element-factory.ts` の `createSongItem`）は、連続する同一アルバムの行で
アートワークを先頭行だけ出し、以降は縦線、グループ最終行は `└` 型の折れ線を描く。
判定を `AlbumGrouping.positions(for:)`（純関数）に切り出し、描画は `SongRowView` の `Canvas` で行う。

**アルバム順ソートのときだけ有効**にしている。タイトル順やアーティスト順ではアルバムの連続性に意味がなく、
偶然隣り合った同一アルバムが繋がって見えてしまうため。

## Alternatives considered

- **和訳を Mobile 側で生成する**: 却下。LLM への問い合わせ導線を Mobile に持たせることになり、
  「Desktop がライブラリの所有者」という設計から外れる。Desktop で作った `.ja.lrc` を配るほうが一貫する。
- **`.searchable(text:)` を使う**: 不可。ローカル/リモート両ライブラリ画面が
  `.toolbar(.hidden, for: .navigationBar)` を指定しておりナビゲーションバーが存在しないため、
  `.searchable` は描画されない。Remote Library に元からあった `TextField` 行のスタイルに合わせた。
- **5セグメントを `.segmented` Picker のまま出す**: 不可。iPhone 幅に収まらない。
  `LibrarySegmentedHeader` は4つ以上のときだけ横スクロールのカプセル型に切り替える形にし、
  3つ以下（Remote Library）は従来の Picker を維持した。

## Constraints / Gotchas

- **歌詞画面のスクロールは実測高さに依存している**。`NowPlayingSyncedLyricsScroll` は
  `LyricsLineHeightKey` で測った各行の高さを積み上げてアクティブ行をアンカー位置に置く
  （`progress/mobile-nowplaying-visuals.md` の Desktop 忠実移植の節を参照）。
  和訳は同じ `Button` ラベル内の `VStack` に入れてあるので、測定対象が伸びるだけでオフセット計算式は無変更で追従する。
  この構造を崩して和訳を測定範囲の外に出すと、アクティブ行のセンタリングが壊れる。
- `translation == nil`（間奏行、および和訳が無い曲）の行は追加の余白を一切取らないこと。
  空の訳文行を描くとレイアウトが間延びし、上記の高さ計算にも効いてくる。
- `/v1/remote/situation-playlists` を持たない古い Desktop に対しては 404 が返る。
  これはエラーではなく「空の For You」として扱う。
- `pickRandomPick` は名前のとおりランダムなので、For You を引き直すたびに「ランダムピック」の中身は変わる。
  Desktop と同じ挙動であり、Mobile 側でキャッシュして固定したりはしていない。
