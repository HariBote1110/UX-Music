# 開発進捗ログ (progress.md)

## 2025年10月11日

### ユーザーからの依頼
- 音楽プレイヤーに隠し機能としてクイズ機能を追加したい。
- Androidの開発者向けオプションのように、設定画面の特定の箇所を複数回タップすると機能が解放されるようにしたい。

### 実装内容
- **隠し機能のトリガー**: 設定モーダルのタイトル「設定」を7回クリックすると、サイドバーに「クイズ」メニューが表示されるロジックを実装。
- **UIの追加**:
    - `src/renderer/index.html`: サイドバーに非表示の「クイズ」メニューと、クイズ画面のコンテナ(`quiz-view`)を追加。
    - `src/renderer/renderer.js`: 設定タイトルのクリックイベントを監視し、7回クリックでクイズメニューを表示する処理を追加。
    - `src/renderer/js/navigation.js`: `showView`関数を修正し、`quiz-view`への画面切り替えに対応。

### 課題・つまづき
- 特になし。基本的なUIの枠組みとトリガーの追加を完了。

---

## 2025年10月12日

### ユーザーからのフィードバック
1. HTML内のコメントが画面にテキストとして表示されてしまう。
2. UI上のテキストが選択可能になっており、操作性を損なっている。

### 実装内容
- **HTMLコメントの削除**: `src/renderer/index.html` から、画面に表示されてしまっていたHTMLコメントをすべて削除。
- **テキスト選択の無効化**: `src/renderer/styles/base.css` の`body`セレクタに `user-select: none;` を追加し、アプリケーション全体のテキストを選択不可にした。

### 課題・つまづき
- 特になし。フィードバックに基づき、UIの微調整を実施。

---

## 2025年10月13日

### ユーザーからのフィードバック
- 他の画面からクイズ画面に遷移すると、以前の画面（アルバム一覧など）がクイズ画面の背後に残って表示されてしまう。

### 実装内容
- **画面遷移ロジックの修正**: `src/renderer/js/navigation.js` の `showView` 関数を修正。
    - クイズ画面のような特別なビューに切り替える際に、メインコンテンツ領域(`main-content`)を非表示にし、中身をクリアする処理(`clearMainContent()`)を追加。
- **`view-renderer.js`の修正**:
    - `clearMainContent`関数を外部のモジュールから呼び出せるように`export`キーワードを追加。

### 課題・つまづき
- 画面の描画管理が`navigation.js`と`view-renderer.js`にまたがっており、状態の不整合が起きやすい構造になっていた。責務を明確化し、`navigation.js`が全体の表示/非表示を管理し、`view-renderer.js`がコンテンツの描画とクリアに専念するよう修正した。

---

## 2025年10月14日

### ユーザーからの依頼
- クイズの具体的な内容として、イントロクイズ（曲名を当てる4択形式）を実装してほしい。
- 将来的に再生数に応じた難易度調整も視野に入れたい。

### 実装内容
- **クイズUIの実装**: `src/renderer/index.html`に、開始画面、問題画面、結果表示画面のUI要素を追加し、`src/renderer/styles/views.css`でスタイリング。
- **クイズ機能のコアロジック実装**:
    - `src/renderer/js/quiz.js`を新規作成。
    - ライブラリからランダムに4曲を選び、問題（正解1曲、不正解3曲）を生成するロジックを実装。
    - `new Audio()`を使用して、メインの音楽プレーヤーとは独立したイントロ再生機能（冒頭10秒）を実装。
- **各種モジュールの連携**:
    - `renderer.js`で`initQuiz()`を呼び出し、クイズ機能を初期化。
    - `navigation.js`で、クイズ画面から離れる際にイントロ再生が停止するよう`stopQuiz()`を呼び出す処理を追加。

### 課題・つまづき
- メインの音楽プレーヤー(`main-player`)とクイズ用の`Audio`オブジェクトが干渉しないように、クイズの音声を再生する前にメインプレーヤーを一時停止させる処理を追加した。

---

## 2025年10月15日 (1回目)

### ユーザーからの改善案
1. クイズの音量をメインプレーヤーの音量と同期させたい。
2. 回答までにかかった時間を計測・表示したい。
3. 問題数を10問、20問、30問から選択できるようにしたい。
4. スペースキーでイントロを再生できるようにしたい。
5. 別アルバムに収録された同じ曲（同アーティスト・同タイトル）が選択肢に重複しないようにしたい。

### 実装内容
- **UIの機能拡張**: `src/renderer/index.html`と`src/renderer/styles/views.css`を更新。
    - 問題数選択用のラジオボタン、タイマー表示、最終結果画面（スコア・平均時間）を追加。
- **クイズロジックの強化**: `src/renderer/js/quiz.js`を大幅に更新。
    - **音量同期**: `volumeSlider`の値を`quizAudio.volume`に設定。
    - **タイマー機能**: `performance.now()`を使用して、再生開始から回答までの時間を計測。
    - **問題数選択**: 開始画面で選択された問題数を`quizState`に保存。
    - **重複排除**: 問題を生成する際に、同アーティスト・同タイトルの曲が選択肢に含まれないように重複チェック処理を追加。
- **スペースキー対応**: `renderer.js`の`keydown`イベントリスナーで、クイズ画面表示中に`handleQuizKeyPress`を呼び出すように修正。

### 課題・つまづき
- 曲の重複排除ロジックが少し複雑になったが、`Map`オブジェクトを使って`アーティスト名|曲名`をキーにすることで効率的に重複を判定できた。

---

## 2025年10月15日 (2回目)

### ユーザーからの改善案
1. イントロ再生を途中で止められないようにしたい。
2. 再生回数に基づいた難易度（かんたん/ふつう/むずかしい）を選択できるようにしたい。
3. クイズの結果をランキング形式で保存・表示したい。
4. `renderer.js`と`views.css`が長くなりすぎたのでリファクタリングしてほしい。
5. （追加要望）スペースキーで次の問題に進めるようにしたい。

### 実装内容
- **リファクタリング**:
    - `renderer.js`からイベントリスナーと設定関連の処理を`init-listeners.js`と`init-settings.js`に分離。
    - `views.css`からクイズ関連のスタイルを`quiz-view.css`に分離。
- **難易度とランキング機能の実装**:
    - `quiz.js`: 難易度に応じて`getQuizSongs`関数が出題リストをフィルタリング（再生回数を参照）するように修正。
    - `ipc-handlers.js`, `system-handler.js`: クイズのスコアを`quiz-scores.json`に保存・読み込みするためのIPCハンドラ`save-quiz-score`, `get-quiz-scores`を追加。
    - `data-store.js`: `quiz-scores.json`が空の場合でも、エラーにならないよう空の配列を返すように修正。
- **操作性の向上**:
    - `quiz.js`:
        - `playSnippet`関数から再生を停止するロジックを削除。
        - `handleQuizKeyPress`関数を修正し、解答表示後にスペースキーを押すと次の問題へ進めるようにした。

### 課題・つまづき
- **起動時エラー**: リファクタリングの際に`renderer.js`の`import`文が不足し、`elements is not defined`エラーが発生。`import { elements } from './js/state.js'`を追加して修正。
- **クイズ終了時エラー**: `quiz-scores.json`が空の時に`scores.push`が失敗するエラーが発生。`data-store.js`が空ファイルに対して`{}`を返していたのが原因。配列を期待するファイルの場合は`[]`を返すように修正。
- **プレイリスト表示問題**: 起動時にプレイリストが空になる問題が発生。IPC通信のタイミングを調整し、ライブラリ読み込み完了後にプレイリストを要求するように修正して解決。

## 2025年11月15日

### MTP 転送機能（次期バージョン）

| ステータス | 機能 |
| :---: | :--- |
| 〇 | MTPデバイス（Walkman）の認識 (macOS) |
| 〇 | ストレージ情報の取得 (macOS) |
| 〇 | ファイル転送（アップロード）の基本実装 (macOS) |
---

## 2026年1月20日

### プロジェクト情報のドキュメント同期

- **ドキュメントの最新化**:
    - `requirement.md`: CDリッピング、MTP転送、ムード解析の最新情報を追記。バージョンを `0.1.9-Beta-5c` へ更新。
    - `features.md`: 実装済み機能リストを整理。
    - `document.md`: `cd-rip-handler.js` や `mood-analyzer.js` などの新規ファイルの説明を追加。
    - `roadmap.md`: 完了済み項目の整理と次期目標の更新。
- **バージョン情報の更新**:
    - `package.json`: バージョンを `0.1.9-Beta-5j` にカウントアップ。

### ビジュアライザーの調整

- **バーの伸長抑制**:
    - `src/renderer/js/visualizer.js`: バーの高さ計算のスケーリング係数を `20` から `12` へ調整。これにより、音が大きい時でもバーがコンテナの上限（20px）に張り付きにくくなり、よりダイナミックな動きを実現。

### 課題・つまづき
- ドキュメントが複数に分散していたため、情報の整合性を保つための精査に時間を要したが、今回の更新で各ドキュメントがソースコードの最新状態と同期された。
- ビジュアライザーの感度が高すぎると、常に最大値付近で動いてしまい視覚的な変化が乏しくなるため、係数の微調整が必要であった。

---

## 2026年1月28日

### プロジェクトの大規模リファクタリング

- **Go バックエンドの構造化**:
    - ロジックを `internal` パッケージ（`config`, `analyzer`, `scanner` 等）に分離。
    - `app.go` を機能別の 9 ファイル（`app_audio.go` 等）に分割し、可読性と保守性を向上。
    - `config` パッケージによる設定管理の一元化。
- **フロントエンド JS の整理**:
    - `src/renderer/js` 内のファイルを `core`, `features`, `ui`, `utils` ディレクトリへ分類。
    - 全ての相対インポートパスを新構造に合わせて修正。
- **ビルド・検証**:
    - `wails build` が正常に完了することを確認。
    - バージョンを `0.1.9-Beta-5k` へ更新。

---

## 2026年2月15日

### Wails 移行中のメタデータ読込改善

- **m4a メタデータ読込の強化**:
    - `internal/scanner/scanner.go`: `tag` で取得できない項目を `ffprobe` で補完する処理を追加。
    - `internal/scanner/ffprobe.go`: タイトル・アーティスト・アルバム・アルバムアーティスト・年・ジャンル・トラック番号・ディスク番号・再生時間・サンプルレートの抽出を実装。
- **ジャケット抽出の強化**:
    - `internal/scanner/artwork.go`: `tag.Picture()` で取得できない場合に `ffmpeg` で埋め込み画像（attached picture）を抽出するフォールバックを追加。
    - `ffmpeg` / `ffprobe` のパス解決を設定値優先 + `PATH` フォールバックへ変更し、Wails 環境でも実行可能に改善。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5t` に更新。

### ノーマライザー機能の Wails 互換修正

- **移行で欠落していたブリッジの復元**:
    - `src/renderer/js/core/env-setup.js` に `start-normalize-job` の `send` ルートを追加。
    - `select-files-for-normalize` / `select-folder-for-normalize` / `get-library-for-normalize` / `get-all-loudness-data` / `select-normalize-output-folder` の `invoke` ルートを Wails 側へ追加。
- **Go 側ジョブ処理の互換性修正**:
    - `app_normalize.go` で `options` の構造（`backup` / `output` / `basePath`）を解釈する実装に変更。
    - 解析結果イベント名を Electron 互換の `analysis-result` に統一（`normalize-result` は継続）。
    - ノーマライズ画面から使う API（ファイル選択、フォルダ再帰走査、ライブラリ読込、ラウドネス一括取得、出力先選択）を追加。
- **FFmpeg 解決の耐障害性向上**:
    - `pkg/normalize/normalizer.go` で `config` 未設定時も `PATH` から `ffmpeg` を解決するフォールバックを追加。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5u` に更新。

### ラウドネス永続化の修正

- **`loudness.json` への保存を復元**:
    - `app_normalize.go` の `NormalizeAnalyze` と `NormalizeStartJob(jobType=analyze)` で解析成功時に `loudness` ストアへ保存する処理を追加。
    - `GetLoudnessValue` / `GetAllLoudnessData` で安全なロード関数を使うように変更し、空ファイル時も安定動作。
- **再生時のラウドネス解析イベントを Wails に接続**:
    - `src/renderer/js/core/env-setup.js` に `request-loudness-analysis` の Wails 分岐を追加。
    - `NormalizeAnalyze` の結果を `loudness-analysis-result` としてフロントへイベント送信するように修正。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5v` に更新。

### Wails 再生前ラウドネス解析の有効化と安全対策

- **再生前ラウドネス解析の有効化**:
    - `src/renderer/js/features/playback-manager.js` で Wails 環境でも `request-loudness-analysis` を発行するように変更。
    - 解析完了までの「再生準備中」通知と待機フローを Wails でも有効化。
- **解析失敗時イベントの補完**:
    - `src/renderer/js/core/env-setup.js` の `request-loudness-analysis` 失敗時に `loudness-analysis-result`（`success: false`）を emit するよう修正。
- **元音源消失リスクの低減**:
    - `src/renderer/js/ui/list-renderer.js` の「ライブラリから削除」をライブラリ上の削除のみ（`DeleteSongs(..., false)`）に変更。
    - 削除確認文言から「ファイルも削除」を除去。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5w` に更新。

### D&D インポート時の実ファイルコピー対応

- **D&D 取り込みフローの修正**:
    - `app_scanner.go` で、スキャンした曲をライブラリフォルダ（`settings.libraryPath`）配下へコピーしてからライブラリへ登録する処理を実装。
    - 保存先は `アーティスト/アルバム/ファイル名` 構成（ファイル名はサニタイズ）とし、同一保存先の重複取り込みを抑制。
    - `libraryPath` 未設定時は初回取り込み時にフォルダ選択ダイアログを表示し、設定へ保存する処理を追加。
- **ライブラリパス設定操作の Wails 接続**:
    - `src/renderer/js/core/env-setup.js` に `set-library-path` の Wails 分岐を追加。
    - Go 側 `SetLibraryPath()` を呼び出して `settings.libraryPath` を更新可能にした。
- **元音源削除リスクの追加対策**:
    - `src/renderer/js/core/init-listeners.js` の選択削除（ショートカット経路）も、実ファイル削除なしに統一。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5x` に更新。

### ライブラリ末尾曲の再生ハイライト不整合修正

- **ライブラリ曲IDの安定化**:
    - `internal/scanner/scanner.go`: `Song` に `id` を追加し、スキャン時の既定値として `path` を設定。
    - `app_scanner.go`: ライブラリへコピー後の保存先パスを `song.id` に反映し、マージ時に `id` を維持するよう修正。
    - `app_playlist.go`: 既存ライブラリ読込時、`id` が欠落している曲へ `path` を補完して保存する移行処理を追加。
- **UI のハイライト判定を一意識別子ベースへ修正**:
    - `src/renderer/js/ui/element-factory.js`: `data-song-id` を `song.id || song.path` で設定。
    - `src/renderer/js/ui/list-renderer.js`: 再生中判定を `id` フォールバック付きで比較。
    - `src/renderer/js/ui/ui-manager.js`: `updatePlayingIndicators()` のセレクタを `id || path` ベースに変更し、ライブラリ追加時も欠落IDを補完。
- **型定義更新**:
    - `src/renderer/wailsjs/go/models.ts`: `scanner.Song` に `id` を追加。
- **検証**:
    - `go test ./...` を実行し、全パッケージで成功（テスト未定義パッケージを除く）。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5y` に更新。

### Wails取り込み時の曲ID付与をUUIDへ統一

- **新規取り込み曲のID生成を修正**:
    - `app_scanner.go`: `importSongsToLibrary()` で取り込み後の `song.id` に `uuid` を付与するよう変更。
    - これにより、Wails 経由で追加した曲も `library.json` に `id` が永続化されるように修正。
- **既存ライブラリの欠落ID補完を修正**:
    - `app_playlist.go`: `LoadLibrary()` の移行処理を `path` 補完から `uuid` 補完へ変更。
    - `id` が欠落した過去データを読み込んだ際にも一意IDを生成して保存。
- **依存関係の更新**:
    - `go.mod`: `github.com/google/uuid` を直接依存として追加。
- **検証**:
    - `go test ./...` を実行し、全パッケージで成功（テスト未定義パッケージを除く）。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-5z` に更新。

### LRC作成機能のWails互換復元

- **歌詞検索ロジックをElectron互換へ調整**:
    - `src/renderer/js/core/env-setup.js`: `get-lyrics` のWails分岐を修正。
    - 検索順を「`song.path` のベース名」→「`song.title`」に変更し、既存の `.lrc/.txt` を見つけやすくした。
- **LRC保存レスポンス形式の互換化**:
    - `src/renderer/js/core/env-setup.js`: `save-lrc-file` のWails分岐を修正。
    - Go呼び出し結果を `{ success: true/false, message }` に正規化し、Electron版のUI期待値に合わせた。
- **LRCエディタ初期化の安定化**:
    - `src/renderer/js/features/lrc-editor.js`: エディタ要素参照をモジュール読込時固定から、開始時の動的解決に変更。
    - 要素未解決時は通知して安全に中断する処理を追加。
    - エディタ再オープン時も `keydown` ハンドラが確実に再接続されるよう調整。
- **検証**:
    - `node --check src/renderer/js/core/env-setup.js`
    - `node --check src/renderer/js/features/lrc-editor.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6a` に更新。

### 各UIでフッターとコンテンツが重なる問題の修正

- **フッター余白計算の実測化**:
    - `src/renderer/js/ui/ui.js`: `updateListSpacer()` を修正。
    - `playback-bar` の実測矩形（`getBoundingClientRect()`）から、ビューポート下端との重なり量を算出して `--footer-height` へ反映するよう変更。
- **通常ビューの下余白を統一**:
    - `src/renderer/styles/layout.css`: `.main-content .view-container` の `padding-bottom` を `--footer-height` へ変更。
- **特殊ビューの下余白を統一**:
    - `src/renderer/styles/normalize-view.css`: `#normalize-view` の下パディングを `calc(20px + var(--footer-height))` に変更。
    - `src/renderer/styles/quiz-view.css`: `#quiz-view` の下パディングを `calc(20px + var(--footer-height))` に変更。
    - `src/renderer/styles/lrc-editor.css`: `#lrc-editor-view` の下パディングを `calc(20px + var(--footer-height))` に変更。
    - `src/renderer/styles/views.css`: `#mtp-transfer-view` の下パディングを `calc(20px + var(--footer-height))` に変更。
    - `src/renderer/styles/mtp-browser.css`: `#mtp-browser-view` に `padding-bottom: var(--footer-height)` を追加。
    - `src/renderer/components/cd-ripper.html`: `.cd-rip-container` の下パディングを `calc(30px + var(--footer-height))` に変更。
- **検証**:
    - `node --check src/renderer/js/ui/ui.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6b` に更新。
