# タスク: Mobile UI を Walkman Cross UI に差し替え

## 目的
UX-Music-Mobile（ネイティブ SwiftUI iOS アプリ）の従来の `TabView` ベース UI を、
`HariBotes-playground/Music-Mock` の「Walkman Cross UI」（十字スワイプ操作）に差し替える。
モックは見た目のみのハードコード実装だったため、本タスクでは各ペインを `AppModel` の
実データ・実再生へ完全配線する。

## 画面構成（中央=再生を起点とした十字）
- 中央: 再生画面（Now Playing）
- 左: 再生キュー
- 右: お気に入りの曲
- 上: ライブラリ（アルバム / プレイリスト / 全曲）
- 下: 設定（イコライザー + サーバー設定 / ペアリング / Remote ライブラリ / Remote コントロールを集約）

## 受け入れ条件
- 初期表示は中央の再生画面である。
- 画面全体のスワイプ操作で対応する画面へ遷移する（独立した方向ボタンは設けない）。
- 外側の画面から反対方向へスワイプすると再生画面へ戻る。外側で対応しない方向へスワイプしても現在の画面を維持する。
- 中央=再生画面はアルバムアートに沿った青緑系グラデーション背景とし、下部セーフエリアまで途切れない。
- メニュー系画面の下部には、現在再生中の曲（ジャケット・曲名・アーティスト・再生/次へ）を暗色のネイティブ bottom toolbar で表示する。
- 各ペインはモックのハードコード値ではなく、`AppModel` の実データを表示・操作する。
  - 再生画面: `player.currentSong` のジャケット・曲情報・進捗・トランスポート・お気に入り・歌詞表示。
  - キュー: `player.playbackQueue` の実キュー。タップで `playQueueItem(at:)`。
  - お気に入り: `favouriteSongsForPlayback()`。タップで再生、スワイプで解除。
  - ライブラリ: ダウンロード済みのアルバム / プレイリスト / 全曲。詳細は既存の `AlbumDetailView` / `PlaylistDetailView` を流用。
  - 設定: イコライザー（既存 `MusicPlayerService` の EQ API）、サーバー設定・QR ペアリング・プレイリスト取り込み（既存 `SettingsScreen` 相当）、Remote ライブラリ（`RemoteLibraryScreen`）、Remote コントロール（`RemoteControlScreen`）。

## 非目標
- 既存サービス層（`MusicPlayerService` / `WearAPIClient` / `DownloadManager` 等）の振る舞いは変更しない。
- 既存の機能を削減しない（モックに無い機能は設定ペインに集約して残す）。
