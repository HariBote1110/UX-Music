# Task: Wails build後の m4a/mp4 再生失敗を修正（ffmpeg探索強化）

## 概要
`wails dev` では再生できるが `wails build` 後のアプリで `m4a/mp4` が再生失敗して次曲へスキップされる問題に対応するため、`ffmpeg/ffprobe` コマンド解決を `PATH` 依存からフォールバック探索付きへ強化する。

## 完了条件
- [x] `pkg/audio/player.go` の `resolveCommandPath` が `PATH` だけでなく Homebrew 標準パスを探索すること。
- [x] `.app` 実行時に `Contents/Resources/bin` および `Contents/Resources` 配下のコマンドも探索対象になること。
- [x] 解決結果をキャッシュし、再生中に毎回探索しないこと。
- [x] `ffmpeg/ffprobe` が解決できない場合、`PATH` を含む明示的なエラーメッセージが返ること。
- [x] `src/renderer/js/core/bridge.js` と `markdown/requirement.md` のバージョンが `0.1.9-Beta-8q` に更新されていること。

# Task: Wailsビルド用のアイコン設定

## 概要
Wailsのビルド時に既存のアイコン `src/renderer/assets/ux-music-icon.png` を使用するように設定する。

## 完了条件
- [x] `src/renderer/assets/ux-music-icon.png` が `build/appicon.png` にコピーされていること。
- [x] macOS用の `build/darwin/icon.png` にも同一のアイコンが配置されていること（Wailsの推奨構成）。
- [x] `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8p` に更新されていること。
- [x] `markdown/requirement.md` のバージョンが `0.1.9-Beta-8p` に更新されていること。

# Task: 右サイドバー映像プレビューのWails配信経路修正（file://禁止対応）

## 概要
Wails環境で右サイドバー映像プレビューが `Not allowed to load local resource` になる問題に対応するため、映像プレビューの参照経路を `file://` から `/safe-media/` へ切り替える。

## 完了条件
- [x] `src/renderer/js/ui/now-playing.js` で Wails 実行時の映像プレビュー URL が `/safe-media/...` になること。
- [x] 映像読み込み失敗ログに `songPath` と `sourceURL` が出力され、原因を追跡できること。
- [x] Electron 実行時の既存挙動（`file://`）を維持すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8o` に更新されていること。

# Task: 右サイドバーの映像プレビュー対応（映像付きローカル曲）

## 概要
右サイドバーのジャケット表示領域で、`mp4` など映像付きローカル楽曲を再生中に映像を表示する。Wails 環境では Go バックエンド再生と別にミュート映像プレビューを同期表示し、既存の `16:9` レイアウト切替を活かす。

## 完了条件
- [x] `src/renderer/js/ui/now-playing.js` で再生中楽曲が映像付き（`hasVideo`）の場合、右サイドバーに映像要素を描画できること。
- [x] Wails 環境では `main-player` に依存せず、右サイドバー専用のミュート動画プレビューを作成すること。
- [x] プレビュー映像が再生状態・一時停止状態・シーク位置に追従同期すること。
- [x] 非映像曲へ切替時にプレビューを確実に破棄し、従来どおりジャケット表示へ戻ること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8n` に更新されていること。

# Task: YouTube字幕取得のXML互換修正（選択2で字幕なし誤判定）

## 概要
YouTube字幕トラックを明示選択（例: `2`）しても「字幕が見つからない」と表示される問題に対応するため、`timedtext format=3` を含む字幕XML形式へ対応し、選択済みトラックから同期歌詞を生成できるようにする。

## 完了条件
- [x] `internal/youtube/youtube.go` のトラック直取得パーサーが `xml-text`（`<text start dur>`）と `xml-timedtext-body`（`<p t d>`）の両方を扱えること。
- [x] `u74OTPd6W5Q` のように `GetTranscript(lang)` が失敗しても、直取得字幕からLRC生成できること。
- [x] 失敗時ログに字幕レスポンス種別・バイト数・短いスニペットが出力され、原因追跡できること。
- [x] `internal/youtube/youtube_test.go` に字幕XML形式ごとの単体テストが追加されていること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8m` に更新されていること。

# Task: YouTube字幕の選択UI追加と詳細ログ強化

## 概要
YouTube ダウンロード時に「字幕がない」と誤判定された状況の切り分けを容易にするため、字幕候補の選択UIを追加し、選択・取得・変換の詳細ログをコンソールへ出力する。

## 完了条件
- [x] `GetYouTubeInfo` のレスポンスに字幕候補一覧（言語/種別/トラックID）が含まれること。
- [x] `src/renderer/js/core/init-listeners.js` で YouTubeリンク追加時に字幕候補の選択モーダルを表示できること。
- [x] `add-youtube-link` が字幕選択情報（mode/language/vssId）を payload として渡せること。
- [x] `internal/youtube/youtube.go` で字幕選択情報を考慮し、候補評価・取得結果の詳細ログを出力すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8l` に更新されていること。

# Task: YouTube有効化同意ダイアログのWails互換化

## 概要
YouTube機能の有効化時に `confirm()` が Wails 環境で期待どおり動作しないケースに対応するため、アプリ内モーダルで同意取得できるようにする。

## 完了条件
- [x] `src/renderer/js/ui/modal.js` が `onCancel` を扱えること。
- [x] `src/renderer/js/utils/debug-commands.js` の YouTube同意処理が Wails 時にアプリ内モーダルを使うこと。
- [x] 「ライブラリを管理」連打導線と `uxDebug.enableYouTubeFeatures()` の両方で同じ同意処理を共有すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8k` に更新されていること。

# Task: YouTube機能有効化のWails対応（ライブラリ管理ボタン連打）

## 概要
既存の YouTube 機能有効化はデバッグコンソール経由（Electron 前提）だったため、Wails 実行環境でも利用できるように「ライブラリを管理」ボタン連打で有効化導線を提供する。

## 完了条件
- [x] `src/renderer/js/utils/debug-commands.js` の YouTube 有効化処理が共通関数化されていること。
- [x] `src/renderer/js/core/init-listeners.js` で「ライブラリを管理」ボタン連打（7回/2.5秒）時に有効化処理を呼び出すこと。
- [x] 既に有効な場合は重複有効化せず、UI表示だけ整合すること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8j` に更新されていること。

# Task: YouTube字幕の同時取得と同期歌詞化

## 概要
YouTube ダウンロード時に字幕も取得し、同期歌詞（`.lrc`）として自動生成・保存する。生成された歌詞は既存の歌詞表示と LRC エディタでそのまま利用できることを目標とする。

## 完了条件
- [x] `internal/youtube/youtube.go` で字幕トラックの優先選択（手動字幕優先、日本語/英語優先）と LRC 変換が実装されていること。
- [x] `app_youtube.go` に `AddYouTubeLink` が実装され、ダウンロード結果をライブラリ保存し、字幕がある場合 `.lrc` を保存すること。
- [x] `src/renderer/js/core/env-setup.js` で `add-youtube-link` が Wails 側 `AddYouTubeLink` を呼び出すこと。
- [x] 字幕がない動画でもダウンロード自体は成功し、ユーザー通知されること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-8i` に更新されていること。

# Task: LRCエディタのタイムライン編集化と既存LRC再編集

## 概要
従来の打鍵中心UIに加えて、動画編集ソフトのタイムラインに近い形で歌詞タイミングを調整できるLRCエディタへ拡張する。既存の `.lrc` を読み込んで再編集できることも必須とする。

## 完了条件
- [x] `src/renderer/components/lrc-editor.html` にタイムラインUI（ルーラー・プレイヘッド・クリップ領域）が追加されていること。
- [x] `src/renderer/styles/lrc-editor.css` にタイムライン編集用スタイルが追加されていること。
- [x] `src/renderer/js/features/lrc-editor.js` で、クリップのドラッグ移動による時刻調整が可能であること。
- [x] タイムラインクリックでシークでき、再生位置がプレイヘッドに反映されること。
- [x] 既存 `.lrc` を読み込んで編集し、保存できること（メタタグ保持を含む）。
- [x] `src/renderer/js/features/lyrics-manager.js` の右クリック導線から、既存LRC時もエディタを開けること。
- [x] `markdown/requirement.md` と `src/renderer/js/core/bridge.js` のバージョンが `0.1.9-Beta-7x` に更新されていること。

# Task: Wails への移行 Phase 1 - プロジェクト初期化と基盤設計

## 概要
Electron から Wails への移行を開始します。Phase 1 では、Wails プロジェクトの初期化、既存の Go ロジック（`src/go`）の App 構造体への統合、およびレンダラー（`src/renderer`）を Wails のフロントエンドとして動作させるための基盤を構築します。

## 完了条件
- [x] `package.json` のバージョンが `0.1.9-Beta-5s` に更新されていること。
- [x] Wails `App` 構造体への `GetSettings` / `SaveSettings` メソッドの実装
- [x] `bridge.js` の Wails 対応（設定の読み書き）
- [x] フロントエンドの `settings` 関連の `TypeError` を解消（`env-setup.js` の強化）
- [x] `src/renderer` が Wails の `frontend` として機能するためのディレクトリ構成が完了していること。
- [x] フロントエンドから Go のメソッドを呼び出すサンプルが動作すること。
- [x] Wails 環境での音楽ファイルの再生（`/safe-media/`）が動作すること
- [x] Wails 環境でのアートワーク表示（`/safe-artwork/`）が動作すること
- [x] プレイリスト管理機能（取得、詳細表示、作成、削除、名前変更、並び替え、追加）の Wails 移行
- [x] 歌詞表示・保存・追加機能の Wails 移行
- [x] Wails 環境での設定（Settings）の永続化と読み込みが正常に動作すること

# Task: Wails への移行 Phase 2 - Backend Migration & Cleanup

## 概要
Node.js および Electron に依存していたバックエンド処理（CDリッピング、MTP、正規化）を Go に完全移植し、不要になった Node.js/Electron コードを削除します。

## 完了条件
- [x] `pkg/cdrip` パッケージの実装 (MusicBrainz, cdparanoia, ffmpeg)
- [x] `pkg/mtp` パッケージの実装 (Cgo wrapper for kalam.dylib)
- [x] `pkg/normalize` パッケージの実装 (ffmpeg based normalization)
- [x] `app.go` への上記パッケージの統合と IPC メソッドの実装
- [x] `src/sidecars` および `src/main` の削除
- [x] `package.json` からのエレクトロン依存削除

# Task: CoreML 前提 TXT 自動歌詞同期

## 概要
CoreML が使える macOS 環境を前提に、`TXT` 歌詞を自動で時刻同期し、`LRC` 作成を支援する機能を追加する。
同期解析は `whisper.cpp` の CoreML 実行を利用し、結果は LRC エディタにプレビュー反映する。

## 完了条件
- [x] `internal/lyricssync` パッケージを追加し、同期解析の実行パイプライン（ffmpeg抽出 / whisper実行 / 単調整列 / 補完 / 単調性補正）を実装。
- [x] `App.AutoSyncLyrics` を公開し、Wails から呼び出せること。
- [x] `env-setup.js` に `lyrics-auto-sync` invoke ルートを追加すること。
- [x] `lrc-editor` へ「自動同期解析」ボタンを追加し、実行中状態・完了通知・失敗通知を実装すること。
- [x] 自動同期結果は保存せず、既存の「LRCを保存」操作でのみファイル保存されること。
- [x] `whisper-cli` / モデル未配置時に配置先を含むエラーメッセージが返ること。
- [x] `markdown/requirement.md` のバージョンを `0.1.9-Beta-7i` に更新すること。
- [x] 単体テスト・結合テスト（擬似 `ffmpeg` / `whisper-cli`）を追加すること。
