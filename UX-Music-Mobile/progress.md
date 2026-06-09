# UX Music Mobile 進捗ログ

## 2026-06-10 — Mobile UI を Walkman Cross UI に差し替え

### 実施内容
- `HariBotes-playground/Music-Mock` の「Walkman Cross UI」（十字スワイプ）を UX-Music-Mobile へ移植。
- 純ロジック（`MusicPane` / `MusicDirection` / `MusicNavigationState` / `MusicSwipeResolver` / `CrossPlayerLayout`）を
  `Core/CrossPlayerNavigation.swift` に追加し、単体テスト 19 件（`CrossPlayerNavigationTests`）で仕様を固定（TDD）。
- `HomeRootView.swift` を従来の `TabView` から十字 UI ルートへ全面書き換え。5 ペインを `AppModel` の実データへ配線：
  - 中央=再生（ジャケット・曲情報・進捗・トランスポート・お気に入り・歌詞）。
  - 左=キュー（`player.playbackQueue` / `playQueueItem`）。
  - 右=お気に入り（`favouriteSongsForPlayback()` / 再生・解除）。
  - 上=ライブラリ（アルバム/プレイリスト/全曲のメニュー → `LocalLibraryScreen` をシート提示）。
  - 下=設定（EQ + サーバー設定 / Remote ライブラリ / Remote コントロールへの入口）。
- メニュー系ペインに下部の再生中バー（タップで再生画面へ）を追加。
- iPhone 17 シミュレータでビルド・起動し、再生・設定・ライブラリ各ペインの表示を確認。`xcodebuild test` 全合格。
- `markdown/` に Task / Implementation_Plan / Walk_Through を追加。

### 選定理由・判断の根拠
- **実データへの完全配線**を選択（モックのハードコード値は不採用）。実用アプリとして機能を維持するため。
- **モックに無い機能（Remote ライブラリ / コントロール / サーバーペアリング）は設定ペインに集約**。
  機能を削減せず、十字 UI の 5 方向構成に収めるため。
- **縦スワイプで遷移するライブラリ / 設定ペインは 1 画面に収まるメニュー構成**とし、
  スクロールを要する詳細はシートで提示。全画面スワイプ（モックの操作感）とスクロールの
  ジェスチャ競合を避けるため。横スワイプ遷移のキュー / お気に入りは縦スクロール可能なリストのままとした。
- 既存の `NowPlayingView.swift` / `MiniPlayerView.swift` はルートから参照しなくなったが、
  `NowPlayingLyricsScreen` 等の共有部品があるためファイルは残置。

### 残課題・次のステップ
- 実機（ダウンロード済み楽曲あり）での各ペインのデータ表示・再生動作の確認。
- ルート未参照になった `NowPlayingView` / `MiniPlayerView` の整理（要否を判断のうえ別タスクで）。
- 再生画面背景をアルバムアート由来パレット（`ArtworkPaletteExtractor`）へ動的化する余地。
