# UX Music Mobile 静的パフォーマンスレビュー（2026-08）

## 目的 / 仮説

「転送以外に重い部分はあるか」という問いに対し、コード静的レビューで疑い箇所を洗い出す。
実測（Instruments）前のスクリーニングであり、ここでの順位は「コード構造から見た疑いの強さ」。
採否の確定には実機プロファイルが必要。

## 環境

- 対象: `UX-Music-Mobile/UX-Music-Mobile/`（branch ai-feature-special、2026-08-11 時点）
- 手法: 読み取り専用サブエージェント 3 並列（音声再生系 / UI 描画系 / データ層・起動系）による
  コードリーディング。file:line の裏取りあり。実測なし。

## 結果（重大度順）

### 1. DownloadManager が問い合わせのたびにディレクトリ全列挙 — 最重要

`Services/DownloadManager.swift` `resolvedExistingFileURL`: 呼ばれるたびに
`contentsOfDirectory` で DownloadedTracks 全体を列挙。`isDownloaded` / `localPathString` /
`watchTransferSourceURL` 等すべてこの上に乗る。

- `SongRowDownloadTrailing.body`（`Views/SongRowView.swift`）が**行ごと・再描画ごと**に呼ぶ。
  使用画面: RemoteLibraryScreen / AlbumDetailView / ArtistDetailView / RemotePlaylistDetailView
- 行タップ用 `rowTap(for:in:)` が ForEach 構築時に全行分先行評価され、`filter{isDownloaded}` +
  `map{localPathString}` で 1 タップあたり 2×N 回列挙
- `downloadAlbum` / `downloadPlaylistSongs` のループでも毎曲列挙 → DL 数増加とともに O(n²)

**対策方向**: init で stem の Set/辞書を 1 回構築し、register/remove/finalize で増分更新。
既存の `downloadLibraryRevision` を無効化シグナルに使える。

### 2. 検索・ソート・グループ化が毎キーストロークで全量再計算＋非表示タブも先行評価

`Views/LocalLibraryScreen.swift` / `RemoteLibraryScreen.swift`: `sortedSongs` /
`searchedAlbums` 等がメモ化なしの computed var。検索フィールドはデバウンスなしで
`$searchQuery` 直結。さらに 4 タブのペインが同一 body 直下にあるため、Songs タブ操作中も
Albums/Artists の `Album.fromSongs` / `Artist.fromSongs`（O(n) 再グループ+ネストソート）が走る。

**対策方向**: 検索デバウンス、(query, sortOrder, revision) キーのメモ化、非表示ペインの遅延化。

### 3. downloadProgress 辞書の @Observable 監視で全行再描画

`AppModel.downloadProgress: [String: Double]` は 1 曲の進捗ティックごとに更新されるが、
@Observable の追跡はプロパティ単位のため、辞書を読む**全可視行**が毎ティック再描画。

**対策方向**: 行単位の観測スコープ分離、または進捗書き込みのスロットリング。

### 4. アートワークのフル解像度デコード＋iOS 側メモリキャッシュ未接続

`RemoteArtworkCaching.swift`: `UIImage(contentsOfFile:)` を原寸デコード（44〜180pt 表示なのに）。
`ArtworkMemoryCache` は実装・テスト済みだが **watchOS ターゲットのみで使用**、iOS では未配線。
スクロールで行が再表示されるたびに同じ画像をディスクから再デコード。
（`ArtworkPaletteExtractor` は 128px 上限のサムネイルデコードで正しくやっている — 手本が repo 内にある）

**対策方向**: `CGImageSourceCreateThumbnailAtIndex` で表示サイズにダウンサンプル+
`ArtworkMemoryCache` を iOS でも使用。

### 5. AlbumDetail / ArtistDetail / RemotePlaylistDetail が非 Lazy VStack

`ScrollView { VStack { ForEach … } }` で全行即時構築（1 と 4 の行コストが全行分先払いになる）。
他画面は List/LazyVStack/LazyVGrid で正しく、この 3 画面だけ不整合。

**対策方向**: LazyVStack へ置換（Watch 側で先週やったのと同型の修正）。

### 6. 再生位置タイマーが一時停止中も 4Hz で回り続ける（ネイティブ+YouTube JS の二重）

`MusicPlayerService.swift:472-500`: 0.25s Timer が曲ロード中ずっと稼働し、一時停止中も
`MPNowPlayingInfoCenter` を毎回更新。YouTube 再生時は埋め込み JS 側のタイマー
（`YouTubeEmbedPlayer.swift:234-246`）も止まらず、JS↔native ブリッジ経由で二重にポンプ。
バッテリーに効くタイプ。

**対策方向**: `!isPlaying` 時はティック/更新をスキップ。JS 側は onStateChange でタイマー停止。

### 7. トラックロードがメインスレッドで同期 I/O

`MusicPlayerService.loadAndPlay`（@MainActor）: `AVAudioFile(forReading:)` のヘッダ解析と
`fileExists` が曲送りのたびにメインスレッドで実行。サンプルレート変更時は
`prepareGraph` のエンジン再構築も同経路。

**対策方向**: ファイルオープン/フォーマット確定をバックグラウンドへ、エンジン操作のみ main。

### 8. 起動時の同期 I/O と UserDefaults の DB 的使用

- `DownloadManager.loadMeta`（init → AppModel.init → 起動経路）: JSON 全量デコード+
  ディレクトリ 2 回列挙+曲ごと線形照合を起動時に同期実行
- `register` ごとに全曲リストを JSON 再エンコードして UserDefaults へ全書き（アルバム一括 DL で O(n²)）。
  PlaylistStore / LibraryMembershipStore も同パターン
- `RemoteAPIClient.fetchSongs` の JSONDecoder がメインアクター上で実行。
  HTTP キャッシュ明示無効+ETag なしで毎回全量取得。`importDesktopPlaylists` は直後に再フェッチ

**対策方向**: loadMeta の非同期化、バルク操作の永続化バッチ化、デコードの main 外し、ETag。

### クリーンと確認された箇所

RemoteArtworkCaching のフェッチ合流/ミスキャッシュ設計、LANDiscoveryService（push 型 mDNS）、
EQ/LUFS（ロード時のみ再計算）、NowPlayingView の高頻度状態分離、LyricsFileStore、
YouTubeEmbedLoopbackServer（遅延起動+使い回し）。

## 結論

「箱庭だから最適化の余地がない」の逆で、体感に直結する構造的な伸び代が多数ある。
最大は **1（ディレクトリ列挙）** で、2・3・5 と複合してリスト画面のスクロール/検索の
カクつきとして現れる可能性が高い。6 はバッテリー、7 は曲送りの引っかかり、8 は起動時間。

## 次の一手 / 未検証事項

- すべて静的レビューによる疑いであり、**実測未了**。修正前に Instruments（Time Profiler /
  SwiftUI / Energy Log）で 1・2・6 のベースラインを取ってから直すのが research 的に正道
- 修正は 1→（2,3,5 同時）→ 4 → 6 → 7 → 8 の順が費用対効果順の見立て
