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
