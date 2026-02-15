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
