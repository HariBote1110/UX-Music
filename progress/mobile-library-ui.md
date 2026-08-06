# UX Music Mobile: ライブラリ画面（Local/Remote）のタブ位置固定と見た目統一

## Decision
- Albums ⇄ Playlists ⇄ Songs 切り替え時に segmented control の位置がズレる問題を解消するため、Picker をナビゲーションバーの `.principal` ToolbarItem から出し、コンテンツ側の固定ヘッダー行に移動した。
- Local/Remote 両画面で共通の `LibrarySegmentedHeader`（`UX-Music-Mobile/Views/LibrarySegmentedHeader.swift`）を新設し、segmented control とタブ非依存の trailing アクセサリ（常に同じ幅を確保）を共有する構造にした。
- ナビゲーションバーは `.toolbar(.hidden, for: .navigationBar)` で非表示にし、件数入りの `navigationTitle`（"Library (37)" 等）を廃止した。
- Local の Playlists 操作（デスクトップ取り込み・並べ替え・新規作成）は ellipsis メニュー（`Menu` + `ellipsis.circle`）1個に集約。Albums/Songs タブでは同じ位置に `opacity(0)` + `disabled(true)` で表示だけ隠し、レイアウト位置は変えない。
- EditButton 相当は Menu 内の「並べ替え」トグルで `@State private var playlistEditMode: EditMode` を切り替える方式に置き換えた（`.environment(\.editMode, $playlistEditMode)`）。
- リスト行・空状態を NowPlayingView 由来の角丸カード（`RoundedRectangle(cornerRadius: 12)` + `Color(red: 0.07, green: 0.07, blue: 0.08)`）に統一し、Albums グリッドは spacing 16・横 padding 16・アートワークに `.shadow(color: .black.opacity(0.4), radius: 8, y: 4)` を追加。
- 空状態は `ContentUnavailableView` に統一。

## Alternatives considered
- Playlists の空状態を `List` の行として `ContentUnavailableView` を描画する案 → 却下。`List` 内で `ContentUnavailableView` の `actions` に `.buttonStyle(.borderedProminent)` を置くと、List 行の測定ロジックと衝突し、ボタンが画面全体を覆う巨大な縦長ピルとして描画される不具合が実機（シミュレータ）確認で判明した。空状態は `List` の外（`NavigationStack` 直下）に描画するよう変更して解消。

## Constraints / Gotchas
- 新規 Swift ファイルを追加する際は `UX-Music-Mobile.xcodeproj/project.pbxproj` に `PBXBuildFile` / `PBXFileReference` / グループ登録 / `PBXSourcesBuildPhase` の4箇所を手動追加する必要がある（プロジェクトが手書き pbxproj 管理のため、Xcode GUI を介さない場合は忘れがちなので要注意）。
- ContentUnavailableView を List 内に置くとレイアウトが壊れるケースがある（上記参照）。空状態は List の外側に置くのが安全。

## 教訓（2026-08-02 追記）: 標準 `Picker(.segmented)` への置換は不評だった
- 上記の位置固定対応の際、`LibrarySegmentedHeader` の中身を独自カプセル実装から標準 `Picker(.segmented)`（iOS 標準のグレー角丸ボタン群）に置き換えたところ、ユーザーから「上の選択ボタンがダサい」「よくわからんグレーが出てきてる」と明確な NG が出た。
- このアプリはヘッダー含め独自の黒基調デザインで統一されており、標準部品（特に `.segmented` Picker の灰色トラック）は世界観から浮く。**タブ切り替えのような目立つ UI 部品は、位置固定などの機能要件を満たしつつも、独自カプセル実装（`Capsule().fill(Color(white:0.12))` の外枠＋`matchedGeometryEffect` でスライドする選択ハイライト）を優先すること**。標準 SwiftUI コントロールへの安易な置換は避ける。
- 併せてヘッダー帯の背景に敷いていた `Color(red: 0.11, green: 0.11, blue: 0.12)` の矩形も「よくわからんグレー」として指摘された。ヘッダーは背景を完全に透明にし、下地の黒に自然に溶け込ませるほうが良い。

## 追記（2026-08-02）: カプセルタブに Liquid Glass を適用
- 「独自カプセル実装だが塗りが平板でダサい」という指摘を受け、`LibrarySegmentedHeader.swift` のカプセル外枠と選択ハイライトに iOS 26 の `glassEffect(.regular, in: Capsule())` / `glassEffect(.regular.interactive(), in: Capsule())` を適用した。デプロイメントターゲットが 17.0（`project.pbxproj` の `IPHONEOS_DEPLOYMENT_TARGET`）のため、`#available(iOS 26.0, *)` で分岐し、未満の OS では従来の `Color(white: 0.12/0.22)` 塗りにフォールバックする。
- `LocalLibraryScreen` の ellipsis メニューと `RemoteLibraryScreen` の取り込み/リフレッシュボタンは、共通の `LibraryHeaderGlassButtonStyle`（`LibrarySegmentedHeader.swift` 内、`ViewModifier`）を介して `.buttonStyle(.glass)`（iOS 26+）／`.ultraThinMaterial` 円形背景（iOS 26 未満）に統一した。`RemoteLibraryScreen` 側は従来 2 ボタンを 1 つの `.background(Circle()...)` で束ねていたため、ボタンごとに個別の円形フレーム＋glass を持つ構造に変更している。
- `matchedGeometryEffect` によるハイライトのスライドアニメーションは維持（`segmentSelectionHighlight` 内で `#available` 分岐後も同じ `matchedGeometryEffect` を適用）。
- シミュレータ（iOS 27, iPhone Air）で Albums/Playlists/Songs 切替時にガラスの背後透過・スライドアニメーションを目視確認済み。

## 追記（2026-08-02）: 独自カプセル＋Liquid Glass も再度不評 → 標準 `Picker(.segmented)` に戻す（最終形）
- 上記のカプセル＋`glassEffect` 版に対しても「すごいくすんでて文字が見えない」「スライドの動きが不自然」「しっかり iOS 標準のやつを使ってほしい」と再度 NG が出た。過去（19〜22 行目）の「標準 Picker はダサい」判断とは逆の結論になるが、これは当時グレーの背景帯を併用していたことが主因だった可能性が高い。
- 最終結論：`LibrarySegmentedHeader.swift` は独自カプセル実装（`matchedGeometryEffect` によるスライドハイライトや自前 `glassEffect`）を全廃し、iOS 標準の `Picker("View", selection:) { ... }.pickerStyle(.segmented)` に置き換えた。ヘッダーの背景は完全透明のまま（グレーの帯は追加しない）で、黒背景に標準 segmented control を直接載せる。
- iOS 26 以降、システムが `.segmented` Picker に標準で Liquid Glass 質感とネイティブのスライドアニメーションを与えるため、独自実装は不要という判断。今後同様の「標準 vs 独自」の揺り戻しが起きた場合は、まずグレーの背景帯を足していないか確認すること（それ単体が「くすんで見える」の主因になりやすい）。
- ellipsis メニュー（`LibraryHeaderGlassButtonStyle` 経由の `.buttonStyle(.glass)`）は標準 API なので変更なし。

## 改修（2026-08-07）: 行のベタ塗り化・連結線の連続化・スワイプ切替

ユーザー指摘は4点（リストの角丸が画面端に変な余白を作る／アルバムまとめ表示の線が途切れ途切れ／上部の切り替えがしづらく SwiftUI 準拠でない／セグメント切替はスワイプで行いたい）。

### Decision
- **行はベタ塗り・全幅**。`RoundedRectangle(cornerRadius: 12)` の角丸カードを行ごとに敷き、`listRowInsets` で左右 8pt 空けていたのをやめ、共通の `LibraryListRowStyle`（`SongRowView.swift`）に統一した。背景色 `Color(red: 0.07, green: 0.07, blue: 0.08)` は据え置きだが `listRowBackground` に単色を渡して行幅いっぱいに敷き、`listRowInsets` は上下 0・左右 16pt（コンテンツのインセットのみ）。角丸カードを隙間なく並べると角の欠けが画面端の黒い切れ端として見えるのが元凶だった。
- **行高を固定**（`SongRowMetrics.rowHeight = 64`）。呼び出し側の `.padding(.vertical, 4/8)` は全廃。行が隙間なく接するのがアルバム連結線を繋げる前提条件になる。
- **連結線のジオメトリを純粋関数へ**。`AlbumGroupConnector`（`Core/AlbumGroupPosition.swift`）が行ローカル y 座標で描画区間を返す。`Canvas` は高さを固定せず行高いっぱいに広がる（`.frame(width:)` のみ指定し、`HStack` に `.frame(height:)` で降ってくる提案を受け取る）。`.first` 行はアートワークに加えて「アートワーク下端→行下端」のスタブ線も描く（`ZStack`）ため、アートワーク直下から最終行のエルボーまで一本に繋がる。
- **セグメント切替は paged `TabView`**（`.tabViewStyle(.page(indexDisplayMode: .never))`）でスワイプ可能にし、**ライブラリ各リストの `.swipeActions` は全廃**。`WatchSongListView` が watchOS で踏んだのと同じ競合（行スワイプがページジェスチャを食う）を避けるため。曲削除・キュー操作（次に再生／最後に追加）・プレイリスト追加・Watch 転送は長押しの `contextMenu` に集約した（`SongQueueMenuItems` / `AddSongToPlaylistMenuItem`）。
- **For You セグメントを廃止**（ユーザー判断）。`SituationPlaylistResolver` と `AppModel.refreshSituationPlaylists` は残置（テストも維持）、UI からのみ外した。
- **Picker は全幅の独立行に分離**。`.segmented` はセグメントを等幅配分するため、trailing アクセサリに 32pt 取られるだけで「アーティ…」と切り詰められる（iPhone 17 実機幅 402pt で再現）。`LibrarySegmentedHeader` から trailing スロットを削除して Picker に全幅を与え、並び替え／ellipsis／更新ボタンは新設の `LibrarySearchRow` の trailing に移した。Local のプレイリストタブにも検索欄を持たせ（`playlistQuery`）、4ページの構造を揃えている。

### Alternatives considered
- 5セグメント（For You 込み）のまま標準 Picker を使う → 却下。等幅配分で 6 文字ラベルが必ず切れる。
- スクロール可能な独自カプセル行を作り直す → 却下。「SwiftUI 準拠でない見た目」がまさに今回の指摘対象。
- 検索欄をページ外（ヘッダー直下）に固定 → 却下。プレイリストタブだけ検索欄がないとページ送りのたびに高さが変わる。

### Constraints / Gotchas
- `LibraryListRowStyle` と `SongRowMetrics` は `Views/SongRowView.swift` に同居させている。新規 Swift ファイルを足すと `project.pbxproj` の4箇所を手書きする必要があるため（このファイル冒頭の注意書き参照）、共有部品は既存ファイルに寄せた。
- プレイリストの `.onMove` は `playlistQuery` が空のときだけ有効。`movePlaylists` は `model.playlists` のオフセットを取るので、絞り込み後のリストとは添字が一致しない。
- **未検証**: スワイプでのページ送りと長押しメニューの動作は、この作業時点の Mac で CoreSimulator の HID 入力が壊れており（`No Legacy HID port found` / タップは成功を返すがアプリに届かない）、実機相当の操作確認ができていない。静止画としてのレイアウト（ベタ塗り行・連結線・4セグメント Picker）はスクリーンショットで確認済み。
