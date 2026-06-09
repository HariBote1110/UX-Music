# 実装計画: Walkman Cross UI 差し替え

## 方針
十字ナビゲーションの「状態モデル」と「レイアウト計算」は純ロジックとして切り出し、
テストで仕様を固定する（TDD）。その後、SwiftUI 画面を状態モデルへ接続し、各ペインを
`AppModel` の実データへ配線する。

モックの `MusicNavigation.swift` / `CrossPlayerLayout.swift` のうち、実 UI で実際に使う
ロジックのみを `Core/CrossPlayerNavigation.swift` に移植する（ハードコードの
`MusicPanePresentation` / `MusicMockVisualStyle` は移植しない＝実データで置換するため）。

## Red — 失敗するテストを書く
`CrossPlayerNavigationTests.swift` に以下を定義する。
- `MusicNavigationState` の初期状態・十字移動・反対方向での復帰・無効方向の維持。
- `MusicPane` の `title` / `description` 文言。
- `MusicSwipeResolver` の方向判定（しきい値・軸支配・対角抑制）と `filteredDragOffset`。
- `CrossPlayerLayout` の `minimumRequiredWidth`・`directionButtonWidth==0`・`cardWidth`・
  ペイン原点（十字）・`offset`（ドラッグ追従／画面外配置）・`topContentInset`・
  `horizontalPadding`・ライブラリメニュー寸法。

## Green — テストを通す
`Core/CrossPlayerNavigation.swift` に純ロジックを最小実装する。
`MusicPane`(player/queue/favourites/library/settings)、`MusicDirection`、`MusicNavigationState`、
`MusicSwipeResolver`、`PaneOrigin`、`PaneOffset`、`CrossPlayerLayout`。

## UI 配線（SwiftUI）
`HomeRootView.swift` を十字 UI ルートに書き換える（既存ファイルなので pbxproj 変更不要）。
- `ZStack`：最背面に `sceneBackground`（再生画面はアルバムグラデ、他は暗色）。
- `MusicPane.allCases` を `CrossPlayerLayout.offset(...)` で連続キャンバス配置し、全画面 `DragGesture` で遷移。
- 各ペインを実データへ配線（Task.md の受け入れ条件参照）。
- メニュー系ペインでは bottom toolbar に再生中表示（現在曲・再生/次へ）。
- 歌詞表示は既存 `NowPlayingLyricsScreen` を流用。

既存の `NowPlayingView.swift` / `MiniPlayerView.swift` はファイルとして残置するが、ルートからは参照しない
（`NowPlayingLyricsScreen` 等の共有部品は引き続き利用）。

## Refactor
- ペイン部品を小さな `private` ビューに分割し、`@Observable` の更新範囲を局所化する。
- テストとビルド（`xcodebuild` / iPhone シミュレータ）の成功を維持する。

## 検証
- 単体テスト: `xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone 17' test`
- 実機表示: iPhone 17 シミュレータでビルド・起動し、十字スワイプと各ペインの実データ表示を確認。
