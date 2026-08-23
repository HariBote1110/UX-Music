# モバイルUX不具合修正 (2026-08)

設定画面のキーボード/ライブラリタブ切替FPS/Remoteタブ初回遷移/iPadグリッド/
シャッフル・リピート視認性/ダウンロード済みチェックマーク/Remoteタブ切替時
CPU急騰の7件をまとめて対応。

## Decision

### 1. 設定画面のキーボード
`SettingsScreen` の `List` に `.scrollDismissesKeyboard(.interactively)` と
タップで `focusedField = nil` する `simultaneousGesture` を追加。ポート欄は
numberPad でそもそも Return キーが無いため、Done ツールバー(既存)以外に
タップ/スクロールドラッグでも閉じられるようにするのが本質的な修正。
port/secret 欄には `.submitLabel(.done)` + `.onSubmit` も追加。

### 2. ライブラリ Songs/Albums/Artists タブ切替の FPS 低下
`LocalLibraryScreen` の `sortedSongs`/`searchedAlbums`/`searchedArtists` が
素の計算プロパティで、body 再評価のたびに `Album.fromSongs`/`Artist.fromSongs`
を再計算していた。タブ切替のページングアニメーション中は body が高頻度で
再評価されるため、これがフレーム落ちの直接原因だった。

`Core/LibraryDerivedCollections.swift` に、入力
(`AppModel.downloadLibraryRevision` ・各ソート順 ・検索語)が変化した時だけ
再計算するキャッシュ構造体を導入。`LocalLibraryScreen` は `@State` で保持し、
`.task(id: derivedInputs)` 経由でのみ更新する（body 内では絶対に再計算しない）。

`libraryRevision` に曲配列そのもののハッシュではなく
`AppModel.downloadLibraryRevision`（ライブラリ変更時にモデル側が既にインク
リメントしているカウンタ）を使うことで、曲配列の内容比較コストを避けた。

あわせて `Artist.fromSongs(_:precomputedAlbums:)` を追加。Albums タブ側で
計算済みのアルバムグルーピング (`Album.fromSongs`) をそのまま渡せば、
Artists タブ側でアルバムを再構築する際に「ソート済みの曲配列をアーティスト
単位でフィルタするだけ」で済む（disc/track ソートはアーティストに依存しない
比較子なので、フィルタしても順序は保たれる）。representativeArtist の再計算
だけはアーティスト部分集合ごとに必要（コンピレーションアルバムの帰属が
サブセットで変わりうるため）。

### 3. Remote タブ初回訪問時の Album→Playlist プッシュ遷移の乱れ
`HomeRootView.LazyTabRoot` が非選択タブを `Color.clear` に差し替えていたため、
Remote タブを一度離れて戻るたびに `NavigationStack` が再構築されていた。
初回だけ発生していたのは、初回訪問直後に素早く Album→Playlist へ push すると
再構築直後でレイアウトが確定する前に push アニメーションが始まり、画面中央で
分割されたように見えていたため。

`LazyTabRoot` を「一度選択されたら生成したまま `.opacity(0)` で隠す」方式に変更
（未訪問タブは従来通り遅延生成のまま）。`NavigationStack` が生きたままになる
ので、次に選択されたときは既にレイアウト確定済み。

あわせて `RemotePlaylistDetailView` を `AlbumDetailView` 等と同じ
`LibraryBottomBleed` でラップし、ライブラリ未ロード時は「曲なし」の
細い空状態ではなく、曲数ぶんのプレースホルダー行（最大8行、56pt高さ）を
表示するようにした。プッシュ遷移中に描画サイズが変化しないようにするための
措置。

### 4. iPad レイアウト
`Core/AdaptiveGridColumns.swift` に `.adaptive(minimum: 160, maximum: 220)`
の共有列指定を追加し、`LocalLibraryScreen`/`ArtistDetailView`/
`RemoteLibraryScreen` の4箇所のグリッドで使い回す。iPhone 幅では従来通り
2列、iPad では概ね4〜6列になる。列数計算の純粋関数
(`AdaptiveGridColumns.columnCount(for:)`) を切り出してユニットテストで
iPhone/iPad 幅ごとの列数を固定した。

`NowPlayingView` のジャケット (`NowPlayingArtworkBlock`) は iPhone は従来の
340pt 固定を維持しつつ、`horizontalSizeClass == .regular`（iPad）では
画面短辺の45%・上限480ptにキャップする方式にとどめた。指示にあった
「アートワーク左・コントロール/歌詞右の2カラム化」までは今回のスコープでは
実施しておらず、次点の代替案（サイズキャップ）のみ対応。

### 5. シャッフル/リピートの選択状態の視認性
アクティブ状態がアクセント色への tint 変更のみで、非アクティブ
(`.white.opacity(0.55)`) との差が乏しかった。`NowPlayingTransportSection` に
`transportToggleButton` を追加し、アクティブ時はアクセント25%塗りの丸背景+
アイコン下の小さいドット、非アクティブは背景なしの暗いアイコンのみにした。

`Core/AccentContrastFallback.swift` で、アートワーク由来のアクセントが
「明るすぎ(brightness > 0.88)かつ低彩度(saturation < 0.35)」の場合は
Watch 版 (`WatchModeIconViews.swift`) の固定 `.blue` に倣った固定色
(`Color.blue`) にフォールバックする。閾値の妥当性はテストでいくつかの
代表色（白に近い/淡いパステル/鮮やかな暗色/明るいが彩度が高い/暗いが
低彩度）について境界を確認した程度で、実機の様々なアートワークに対する
網羅的な検証はしていない。

### 6. ダウンロード済み曲の緑チェックマーク削除
`SongRowDownloadTrailing` から、ダウンロード済み通常曲・ライブラリ追加済み
YouTube曲の `checkmark.circle.fill`(緑) を削除し、`EmptyView()` にした。
ダウンロード中/未ダウンロードのアフォーダンスは維持。参照していたテストは
無かった。

### 7. Remote タブ Songs/Albums/Playlists 切替時のCPU急騰(130%超)
項目2で `LocalLibraryScreen` に導入した `LibraryDerivedCollections` メモ化を、
`RemoteLibraryScreen` には移植していなかった。同スクリーンの `albumsPane`/
`songsPane` は素の関数呼び出しで、呼ばれるたびに
`Album.fromSongs(songs)`・`SongSearchFilter.filter(songs, query:)`・
`AlbumGrouping.positions(for:)` を再計算していた。`libraryBody` の
`TabView(selection:)` は `.page` スタイルでもタグ付き子ビュー(`albumsPane`/
`playlistsPane`/`songsPane`)を毎 body 評価で全て呼び出すため、ページング
アニメーション中の高頻度な再評価がそのまま再グルーピングに直結し、CPU
使用率が跳ね上がっていた。項目2と同根の問題が Local 修正時に Remote 側へ
横展開されていなかっただけ、というのが実態。

`LibraryDerivedCollections` に `RemoteInputs`（`remoteLibraryRevision`・
`librarySortOrder`・検索クエリ）と `updatedForRemote(songs:inputs:)` を追加
（既存の `Inputs`/`updated` とは別のフィールド・別メソッドとして共存させ、
ロジックの重複ではなくキャッシュ構造体の再利用とした）。`AppModel` には
`remoteLibraryRevision` を新設し、`refreshLibrary()` が `.loaded(songs)` を
確定させた箇所でインクリメント。`RemoteLibraryScreen` は `@State private var
derived` を保持し、`.task(id: derivedInputs(searchQuery:))` でのみ更新、
`albumsPane`/`songsPane`/`remoteSongsList` は全て `derived.remoteSearched*`
を読むだけにした。

**`LazyTabRoot` の保持方式（項目3）との関係**: `LazyTabRoot` は一度訪問した
タブを非表示中も `opacity(0)` でマウントし続ける。そのため Remote タブを
非表示にしていても `model` の変化を購読していれば body は再評価され得るが、
キャッシュがヒットする限り実質コストはほぼゼロになるため、指示にあった
「非アクティブ時は重い派生計算そのものを止める」までの追加ゲート
（`isActive` を明示的に渡す等）は行わなかった。ヒット時のコストは
`PerformanceBenchmarkTests.testRemoteDerivedCollectionsCacheHitVsRecompute`
(`UXM_PERF=1` 限定) で計測しており、60回連続呼び出しでも実測 0.4秒程度
（1回あたり数ミリ秒未満）で、体感上ネックにならない水準であることを確認した。

#### 7-1. 追補: Controlタブ自体のアイドルCPU（`mobile_remote_perf_research`）

項目7は「Songs/Albums/Playlists切替時」のスパイクだったが、`Control`タブ
（`RemoteControlScreen`）は切替とは無関係にアイドル表示中も2秒毎の
`pollOnce()`でCPUスパイクを起こしていた。`mobile_remote_perf_research/`
配下の研究（`notes/01`〜`04`）で実測: Controlタブをただ開いて置いておく
だけでCPU中央値1.0%・p95 2.7%（Remoteライブラリタブは0.3%/0.6%）。原因は
`pollOnce()`が`desktopState: [String: Any]`を毎tick無条件代入していたこと
（`Equatable`に適合できない辞書のため、内容が同じでもSwiftUIは新規の状態
変化として`controlsView`全体を再評価していた）。

`AppModel.sidecarPollOnce()`が`SidecarMetadataSnapshot`で先に導入していた
のと同じパターンで`RemoteControlStateSnapshot`（title/artist/album/
duration/playing、`Equatable`）を追加し、変化した時だけ`@State`へ書き込む
差分ガードを実装（`position`のみ従来通り毎tick更新）。ついでに研究ノートで
指摘されていた低優先2件も対応: Remoteアートワークのグリッドタイル用に
`UIImage.preparingThumbnail(of:)`によるダウンサンプリング付きデコードと
サイズバケット別メモリキャッシュ（`RemoteArtworkDecodeTarget`/
`RemoteArtworkDecoding`/`RemoteArtworkDecodedImageCache`）を追加、
`RemoteLibraryScreen`のPlaylistsグリッドの`ForEach id: \.offset`を
`id: \.name`に安定化。

**対策後の実測**（同一環境・同一手順で再計測、詳細は
`mobile_remote_perf_research/notes/04-summary-and-recommendations.md`の
「対策後の実測」節）: CPU中央値は1.0%→0.6%に改善したが、p95は2.7%→3.3%で
改善しなかった。`pollOnce()`のHTTP往復・JSONデコード・スナップショット
構築自体は差分ガードの対象外で毎tick発生するため、そのtickのピーク
コストは消えない。差分ガードが効くのは「変化なしtickでの無駄な全体
再評価」というスパイク後の定常コストの方であり、「2秒毎のピークそのもの」
という当初仮説の理解は不正確だった。p95をさらに下げるにはポーリング
間隔の見直しやネットワーク/デコードコスト自体の削減が必要（未着手）。
アートワークのダウンサンプリングとPlaylists ID安定化は実装のみ完了し、
実行時計測（グリッド連続スクロールのA/B比較）は未実施。

## Constraints / Gotchas

- **並行編集による共有ファイルの競合**: `UX-Music-Mobile.xcodeproj/project.pbxproj`
  は Watch 側を担当する別エージェントも同時に編集しており、git commit の
  タイミング次第でお互いの登録行が上書きされるレースが実際に発生した
  (`LibraryDerivedCollections.swift` 等の Sources 登録が一時的に消えた)。
  pbxproj を編集した直後は必ず `plutil -lint` と実ビルドで登録漏れが
  無いか確認すること。
- 同様に、`git commit` を pathspec 無しで実行すると、他エージェントが同時に
  `git add` していたファイル(Watch 側やデスクトップ側)を巻き込んで
  コミットしてしまう事故が起きた。以後は `git commit -m "..." -- <path> <path>`
  のように必ずコミット対象を明示すること。
- Watch ターゲットのビルドエラー(型未定義・構文エラー)は他エージェントの
  作業途中の一時的な状態であり、`UX-Music-Watch/` 配下の変更ではない場合は
  静観して再ビルドで様子を見るのが妥当だった。
