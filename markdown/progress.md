# 開発進捗ログ (progress.md)

## 2026年2月16日

### 自動歌詞同期: MLボーカル抽出のmacOS加速とフォールバック改善

- **demucs 実行デバイス制御を追加**:
    - `internal/lyricssync/vocal_ml.go` で `--device` 指定を追加。
    - Apple Silicon（`darwin/arm64`）では `mps` を優先し、失敗時は `cpu` へ自動フォールバック。
    - `UXMUSIC_LYRICS_SYNC_DEMUCS_DEVICE` 環境変数で実行順を上書き可能（例: `mps,cpu`）。
- **フォールバック耐性の向上**:
    - モデル候補（`*_q` など）ごとにデバイス候補を切り替え、失敗時のリトライ精度を改善。
    - `diffq` 未導入時は既存どおり非量子化モデルへ切替。
- **テスト拡充**:
    - `internal/lyricssync/vocal_ml_test.go` にデバイス候補生成テストと `mps -> cpu` フォールバック試験を追加。
- **仕様同期とバージョン更新**:
    - `markdown/requirement.md` / `src/renderer/js/core/bridge.js` のバージョンを `0.1.9-Beta-7w` に更新。

### LRCエディタ: タイムライン編集UIと既存LRC再編集対応

- **タイムライン編集を追加**:
    - `src/renderer/components/lrc-editor.html` に、ルーラー・プレイヘッド・クリップ表示を持つタイムライン領域を追加。
    - `src/renderer/styles/lrc-editor.css` に、クリップ表示・ドラッグ中表示・未配置行表示のスタイルを追加。
- **編集ロジックを刷新**:
    - `src/renderer/js/features/lrc-editor.js` で、歌詞クリップのドラッグによる時刻微調整を実装。
    - タイムラインクリックによるシーク、再生位置プレイヘッド同期、未配置行一覧からの行選択に対応。
    - 既存 `.lrc` のメタタグ（`[ar:]` など）を保持し、保存時に再出力するよう変更。
    - 複数タイムスタンプ付きLRC行を編集用に展開して読み込み可能に変更。
- **導線改善**:
    - `src/renderer/js/features/lyrics-manager.js` を更新し、LRC表示中でも右クリックから「同期歌詞を編集...」を開けるよう変更。
- **仕様同期とバージョン更新**:
    - `markdown/requirement.md` / `src/renderer/js/core/bridge.js` のバージョンを `0.1.9-Beta-7x` に更新。

### LRCエディタ: オブジェクト伸縮編集とルーラー倍率変更

- **AviUtlライク編集を追加**:
    - `src/renderer/js/features/lrc-editor.js` でクリップ中央ドラッグの移動ロジックを拡張。
    - 左右端ハンドルを追加し、左端で開始位置、右端で終了境界（次行時刻）を伸縮できるように変更。
- **ルーラーズームを追加**:
    - `src/renderer/components/lrc-editor.html` に倍率スライダーを追加。
    - `src/renderer/styles/lrc-editor.css` にズームUI・横スクロールタイムライン・ハンドルスタイルを追加。
    - `src/renderer/js/features/lrc-editor.js` で倍率に応じたルーラー密度・描画幅切り替えを実装。
- **仕様同期とバージョン更新**:
    - `markdown/requirement.md` / `src/renderer/js/core/bridge.js` のバージョンを `0.1.9-Beta-7y` に更新。

### LRCエディタ: ドラッグ時のルーラー不要移動を抑制

- **ドラッグ開始時のスクロール制御を修正**:
    - `src/renderer/js/features/lrc-editor.js` の `setActiveLine` にスクロール制御オプションを追加。
    - クリップのドラッグ開始時は `scrollIntoView` を無効化し、タイムライン（ルーラー）が意図せず動かないように調整。
- **仕様同期とバージョン更新**:
    - `markdown/requirement.md` / `src/renderer/js/core/bridge.js` のバージョンを `0.1.9-Beta-7z` に更新。

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

### リスト表示のフッター背面スクロール仕様を復元

- **仕様再調整**:
    - 曲リスト等は「フッター背面までスクロールできる」挙動が正であるため、通常ビュー全体への下パディング付与を取り消し。
- **修正内容**:
    - `src/renderer/styles/layout.css`: `.main-content .view-container` の `padding-bottom` を `0px` に戻し、リスト側スペーサー方式（`--footer-height` と末尾スペーサー）を優先する構成へ復元。
    - LRCエディタおよび特殊ビュー側の下余白調整は維持。
- **検証**:
    - `node --check src/renderer/js/ui/ui.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6c` に更新。

### LRCエディタの操作性改善（ハイライト指定・間奏指定）

- **任意行ハイライト機能の追加**:
    - `src/renderer/components/lrc-editor.html`: 「行ハイライト ( H )」ボタンを追加。
    - `src/renderer/js/features/lrc-editor.js`: 選択行にハイライトをトグルする処理を実装。
    - `src/renderer/styles/lrc-editor.css`: 手動ハイライト行とアクティブ行の視認性を強化。
- **間奏指定機能の追加**:
    - `src/renderer/components/lrc-editor.html`: 「間奏挿入 ( I )」ボタンを追加。
    - `src/renderer/js/features/lrc-editor.js`: `[間奏]` 行を挿入する処理を実装。
    - 保存時は通常のLRC行として `[mm:ss.xx][間奏]` 形式で出力されるため、間奏開始位置を明示可能にした。
- **キーボード操作の拡張**:
    - `src/renderer/js/features/lrc-editor.js`: `H` でハイライト切替、`I` で間奏行挿入、`↑/↓` で選択行移動を追加。
- **ヘルプ表記の更新**:
    - `src/renderer/components/lrc-editor.html`: 新しい操作（間奏挿入・行ハイライト）をヘルプへ追記。
- **検証**:
    - `node --check src/renderer/js/features/lrc-editor.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6d` に更新。

### LRCエディタのタイムスタンプ時ハイライト挙動を調整

- **仕様調整**:
    - `T` でタイムスタンプを打った際、次行へ自動移動せず、指定した行をアクティブ（青表示）に維持するよう変更。
    - 「どこに打ったか」を視認しやすくし、歌唱位置の混乱を減らす目的。
- **修正内容**:
    - `src/renderer/js/features/lrc-editor.js`: `addTimestamp()` の自動次行選択ロジックを削除し、現在行を維持する実装へ変更。
    - `src/renderer/components/lrc-editor.html`: ヘルプ文言を実挙動に合わせて更新（行維持と `↑/↓` 移動を明記）。
- **検証**:
    - `node --check src/renderer/js/features/lrc-editor.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6e` に更新。

### LRCエディタのT連打ワークフローに再調整

- **仕様調整**:
    - `T` 1回目: 現在行にタイムスタンプを打ち、青表示をその行に維持。
    - 同じ行が青い状態で `T` を再度押す: 次の歌詞行へタイムスタンプを打ち、青表示を次行へ進める。
    - これにより「今どこを歌っているか」を見失いにくい進行に変更。
- **修正内容**:
    - `src/renderer/js/features/lrc-editor.js`: `addTimestamp()` を連続入力対応ロジックへ変更（同一行連続T時のみ次行へ進行）。
    - `src/renderer/js/features/lrc-editor.js`: 手動行選択（クリック、`↑/↓`）時は自動進行状態を解除するよう調整。
    - `src/renderer/components/lrc-editor.html`: ヘルプ文言を新しいT連打フローに更新。
- **不要機能の整理**:
    - `src/renderer/components/lrc-editor.html` / `src/renderer/js/features/lrc-editor.js` / `src/renderer/styles/lrc-editor.css`: 手動「行ハイライト ( H )」機能を削除。
- **検証**:
    - `node --check src/renderer/js/features/lrc-editor.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6f` に更新。

### LRCエディタの空行間奏仕様へ変更

- **仕様変更**:
    - 空白行挿入ボタンによるスペース文字の疑似空行を廃止。
    - 文字がない行（空行）を間奏扱いとして扱い、`T` でタイムスタンプ付与可能に変更。
- **修正内容**:
    - `src/renderer/components/lrc-editor.html`: 「空白行挿入」ボタンを削除し、ヘルプに「空行も間奏扱いでタイムスタンプ可能」を追記。
    - `src/renderer/js/features/lrc-editor.js`: `insertBlankLine()` と関連リスナーを削除。
    - `src/renderer/js/features/lrc-editor.js`: LRC/TXT/テキストエリアの読込時に空行を `' '` ではなく `''` で保持するよう統一。
    - `src/renderer/js/features/lrc-editor.js`: `addTimestamp()` の空行スキップ制御を削除し、空行を含めて次行へ進行するよう調整。
    - `src/renderer/js/features/lrc-editor.js`: `isInterludeText()` で空行を間奏行として判定するよう変更。
- **検証**:
    - `node --check src/renderer/js/features/lrc-editor.js`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6g` に更新。

### 歌詞表示の追従スクロール中心を可視領域基準へ調整

- **仕様調整**:
    - 再生中の歌詞ハイライト行は、フッター重なり領域を除いた可視範囲の中心へ追従させる。
    - 「フッターに完全に隠れてからスクロール」する遅れを解消。
- **修正内容**:
    - `src/renderer/js/features/lyrics-manager.js`: `--footer-height` とビューポート座標から、歌詞ビューの実可視領域を算出する処理を追加。
    - `src/renderer/js/features/lyrics-manager.js`: LRCのアクティブ行更新時、従来の可視判定分岐を廃止し、実可視領域の中心へ常時スクロール補正するよう変更。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6h` に更新。

### 歌詞表示を Apple Music 風に調整（見た目・追従スクロール）

- **UIスタイルの改善**:
    - `src/renderer/styles/views.css`: 歌詞表示を専用スタイルへ分離し、左右余白を `clamp()` で最適化。
    - 非アクティブ行の減光とアクティブ行の強調（グラデーション・影・スケール）を追加し、視線誘導を改善。
    - 歌詞行をテキスト幅ベース（`width: fit-content`）で表示し、全幅ハイライトによる左右の不自然な空白感を解消。
    - 上下フェード（mask）と小画面向けのフォント/余白調整を追加。
- **追従スクロールの改善**:
    - `src/renderer/js/features/lyrics-manager.js`: アクティブ行の目標スクロール位置を算出する `getLyricsScrollTarget()` を追加。
    - `scrollTop += ...` を廃止し、`scrollTo({ behavior: 'smooth' })` ベースで中心追従するよう変更。
    - 連続更新時の過剰スクロールを抑える差分判定を追加し、体感の滑らかさを向上。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6i` に更新。

### 歌詞表示アニメーションの「ぬるっと感」を強化

- **スクロール追従の改善**:
    - `src/renderer/js/features/lyrics-manager.js`: `requestAnimationFrame` ベースの独自イージングスクロールを追加。
    - アクティブ行の更新時は既存アニメーションを中断し、最新ターゲット位置へ再補間するよう変更。
    - `prefers-reduced-motion` 時は即時スクロールへフォールバックするよう対応。
- **視覚トランジションの改善**:
    - `src/renderer/styles/views.css`: 歌詞行トランジションを 0.52s + `cubic-bezier(0.22, 1, 0.36, 1)` に統一し、移行を滑らかに調整。
    - 非アクティブ行のスケール・不透明度を微調整し、アクティブ行への寄りを自然化。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6j` に更新。

### 歌詞スクロールのガタつき低減とイージング23番対応

- **ガタつき対策**:
    - `src/renderer/styles/views.css`: `#lyrics-view` の `scroll-snap-type` と歌詞行の `scroll-snap-align` を削除し、スクロール追従との干渉を解消。
    - `src/renderer/js/features/lyrics-manager.js`: 微小移動量ではアニメーションを開始しない閾値（`LYRICS_SCROLL_MIN_DISTANCE_PX`）を追加。
- **イージング調整**:
    - `src/renderer/js/features/lyrics-manager.js`: 追従スクロールの補間を `easeOutBack`（イージング23番相当）へ変更。
    - `src/renderer/styles/views.css`: 歌詞行の `transform` トランジションを `cubic-bezier(0.175, 0.885, 0.32, 1.275)` へ変更し、動きの質感を統一。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6k` に更新。

### 歌詞表示をさらにゆったり化し、遅延追従スクロールを追加

- **ゆったりした追従スクロール**:
    - `src/renderer/js/features/lyrics-manager.js`: スクロール時間を固定値から距離依存（最小/最大あり）へ変更し、長距離移動ほどゆっくり追従するよう調整。
    - 微小なスクロール差分は即時反映し、不要なアニメーションを抑えて安定性を維持。
- **遅延追従（ワンテンポ遅れ）演出の追加**:
    - `src/renderer/js/features/lyrics-manager.js`: 歌詞行のラグオフセットを `requestAnimationFrame` で制御する処理を追加。
    - `src/renderer/styles/views.css`: `--lyrics-lag-offset` を導入し、歌詞行の `transform` に反映。アクティブ行は遅延量を軽減して視認性を保持。
    - ラグは「ホールド → 減衰」の2段階で戻すことで、Apple Music 風の後追い感を表現。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6l` に更新。

### 歌詞ハイライト形状の調整と車列風の段階遅延アニメーション

- **ハイライト形状の調整**:
    - `src/renderer/styles/views.css`: アクティブ歌詞のハイライトをピル形状から角丸四角形（`border-radius: 12px`）へ変更。
    - 行パディングを微調整し、Apple Music 風の矩形ハイライトに近づけた。
- **段階遅延（信号待ちの車列）アニメーション**:
    - `src/renderer/js/features/lyrics-manager.js`: 全行一括ラグ方式を廃止し、行ごとに遅延開始する wave 方式へ変更。
    - スクロール方向に応じて行の遅延順を切り替え、前方行から順に動き出す挙動を実装。
    - アクティブ行から離れるほどオフセットを減衰させ、可読性を維持。
    - `src/renderer/styles/views.css`: `--line-lag-offset` / `--line-lag-delay` を導入し、行ごとに異なる追従タイミングを実現。
    - 初期フレーム固定用の `.lag-prime` を追加し、段階遅延開始時のちらつきを抑制。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6m` に更新。

### 歌詞の行間拡張と段階遅延をさらに強調

- **行間と視認性の調整**:
    - `src/renderer/styles/views.css`: 歌詞全体の `line-height` を拡大し、各行の上下余白（`margin` / `padding`）を増加。
    - モバイル幅でも行間が詰まりすぎないように `@media` 側の `line-height` も引き上げ。
- **一行ずつ動く演出の強調**:
    - `src/renderer/js/features/lyrics-manager.js`: wave 遅延パラメータ（ベース遅延・段階遅延・オフセット量）を増やし、前行と後行の差を明確化。
    - 遅延時間を `order` の線形ではなく `order^1.12` の非線形に変更し、後段行ほど明確に遅れて動くよう調整。
    - `src/renderer/styles/views.css`: `transform` トランジション時間を延長し、段階遅延の視覚差を強化。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6n` に更新。

### 元行単位の行間制御と後段遅延の強化

- **元行単位の行間制御**:
    - `src/renderer/js/features/lyrics-manager.js`: LRC 解析時に `sourceLine` を保持し、描画時に `line-break` / `line-continuation` クラスを付与。
    - `src/renderer/styles/views.css`: 同一元行の連続表示は狭め、元行が変わる箇所は広めのマージンを適用するスタイルを追加。
    - これにより、折り返しや同一元行の表示密度を保ちつつ、歌詞行の切れ目を明確化。
- **後段遅延の強化（前行完了に近い感覚）**:
    - `src/renderer/js/features/lyrics-manager.js`: 段階遅延のベース値とステップ値を大幅に増加。
    - 遅延関数を非線形（`order^1.22`）かつ上限付きに変更し、後ろの行ほど目立って遅れる挙動へ調整。
    - 遅延対象距離を絞り、強い段階感を保ちながら極端なロングテールを抑制。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6o` に更新。

### 表示中行基準への変更と同一元行の行間圧縮

- **遅延基準点の変更**:
    - `src/renderer/js/features/lyrics-manager.js`: 可視領域中心に最も近い行を `displayed index` として算出する処理を追加。
    - wave 遅延の基準を `active index` から `displayed index` へ変更し、「今表示している行」を軸に段階遅延が発生するよう調整。
    - スクロール中断・リセット時の表示基準インデックスの状態管理を追加し、方向判定の安定性を改善。
- **同一元行の行間調整**:
    - `src/renderer/styles/views.css`: `line-continuation` の `margin-top` をさらに縮小し、同一元行の連続表示をより詰めた見た目に変更。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6p` に更新。

### 歌詞遅延アニメーションを単純ディレイ方式へ回帰

- **アニメーション方式の回帰**:
    - `src/renderer/js/features/lyrics-manager.js`: 行ごとの wave 遅延（表示基準インデックス/段階遅延）を廃止。
    - 早期段階で採用していた「全体ラグオフセット（`--lyrics-lag-offset`）」方式へ戻し、単純な遅延追従に統一。
    - `animateLyricsLagByDistance()` による「ホールド→減衰」制御へ復元し、スクロール追従との干渉を低減。
- **表示スタイルの整理**:
    - `src/renderer/styles/views.css`: 行単位ラグ用の CSS 変数/クラス（`--line-lag-*`, `.lag-prime`）を削除。
    - 同一元行/行切り替えの行間制御（`line-continuation`, `line-break`）は維持。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6q` に更新。

### 歌詞の追従基準を中央から上固定へ変更

- **追従基準の調整**:
    - `src/renderer/js/features/lyrics-manager.js`: `getLyricsScrollTarget()` の計算基準を「可視領域の中心」から「可視領域の上端」へ変更。
    - 上端貼り付きで見切れないように最小オフセット（`LYRICS_TOP_ANCHOR_OFFSET_PX`）を導入。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6r` に更新。

### 上フェードの緩和と上固定位置の下方オフセット調整

- **表示基準位置の調整**:
    - `src/renderer/js/features/lyrics-manager.js`: 上固定アンカー値 `LYRICS_TOP_ANCHOR_OFFSET_PX` を増加し、表示行がやや下に来るよう調整。
- **フェード量の調整**:
    - `src/renderer/styles/views.css`: 歌詞ビュー上端のマスク勾配を緩和し、上側フェードアウトの強さを低減。
- **改行時の行内行間対策**:
    - `src/renderer/styles/views.css`: `#lyrics-view p` に個別 `line-height` を設定し、長い歌詞が折り返した際の行内間隔が過大になる問題を修正。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6s` に更新。

### 行ごとの遅延増加を再導入（表示中行基準・表示済み除外）

- **遅延ロジックの再構成**:
    - `src/renderer/js/features/lyrics-manager.js`: 単純ディレイ（全体オフセット）方式を廃止し、行ごとの段階遅延方式を再導入。
    - 基準点は「表示中の行」（可視領域上端アンカー付近）として算出する方式に変更。
    - スクロール方向に応じて、表示済み側の行（過ぎた側）を遅延対象から除外するフィルタを追加。
- **CSS 連携の復元**:
    - `src/renderer/styles/views.css`: `--line-lag-offset` / `--line-lag-delay` と `.lag-prime` を復元し、行単位の時間差トランジションへ戻した。
    - 同一元行/行切替の行間制御（`line-continuation`, `line-break`）は維持。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6t` に更新。

### 行ごとの遅延カーブを緩やかに調整

- **遅延カーブの再調整**:
    - `src/renderer/js/features/lyrics-manager.js`: 行ごとの遅延増加が急すぎるため、段階遅延パラメータを緩和。
    - `LYRICS_TRAFFIC_WAVE_STEP_MS` を 280 から 120 へ縮小。
    - `LYRICS_TRAFFIC_WAVE_DELAY_EXPONENT` を 1.18 から 1.08 へ下げ、後段の遅延伸びを抑制。
    - `LYRICS_TRAFFIC_WAVE_MAX_DELAY_MS` を 3200 から 2000 へ下げ、過剰なロングテールを制限。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6u` に更新。

### 少表示行（1〜2行）時の遅延追従を補正

- **表示行数ベースの補正を追加**:
    - `src/renderer/js/features/lyrics-manager.js`: 可視領域内の表示行数を計測する `getVisibleLyricsLineCount()` を追加。
    - 表示行数が 3 行未満のとき、遅延カーブを自動的に緩和する係数（`sparseViewFactor`）を導入。
    - `base delay / step / exponent / max delay` を表示行数に応じて縮小し、1〜2行時の「置いていかれてから動く」印象を軽減。
    - 同時に `peakOffset` も表示行数が少ないほど抑え、視覚的な遅れ感を低減。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6v` に更新。

### スクロールイージングを初速高めの減速型へ変更

- **イージング関数の置換**:
    - `src/renderer/js/features/lyrics-manager.js`: スクロールで使用していた `easeOutBack23`（Back系）を廃止。
    - オーバーシュート由来の引っかかり感を減らすため、`easeOutCubic`（初速高め・終端減速）へ差し替え。
    - `animateLyricsScrollTo()` の進行率計算で新イージングを適用。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6w` に更新。

### オーバーシュート挙動（0=>1.2=>1）を解消

- **トランジション曲線の修正**:
    - `src/renderer/styles/views.css`: 歌詞行の `transform` トランジションで使っていた `cubic-bezier(0.175, 0.885, 0.32, 1.275)` を廃止。
    - 終端で 1 を超えない `cubic-bezier(0.22, 1, 0.36, 1)` へ統一し、`0 => 1` の単調遷移に変更。
    - これにより「一瞬上に上がってから落ちる」上振れ挙動を除去。
- **検証**:
    - `rg "1.275" src/renderer/styles/views.css`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6x` に更新。

### 距離に応じた可変速度追従へ変更

- **遅延主体から速度主体へ移行**:
    - `src/renderer/js/features/lyrics-manager.js`: 行ごとの動きを単純な段階遅延から、距離依存の可変速度制御へ変更。
    - 「基準行から遠い行ほど速く戻る」ように、`distance ratio` から `speed factor` を算出。
    - 近い行は遅延が残り、遠い行は遅延が小さくなるよう `line delay` を反比例で調整。
    - さらに遠い行ほど `line-lag-duration` を短くし、収束速度を上げる挙動を追加。
    - 少表示行（1〜2行）時の補正は維持し、過度な置いていかれ感を抑制。
- **スタイル連携の拡張**:
    - `src/renderer/styles/views.css`: `--line-lag-duration` を追加し、`transform` トランジション時間を行ごとに受け取るよう更新。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6y` に更新。

### 強調行を固定しつつ背景歌詞をスクロールする遷移へ改善

- **ガタつき対策（切り替え順序の変更）**:
    - `src/renderer/js/features/lyrics-manager.js`: `active` クラスの切り替えを「スクロール開始前」から「スクロール完了時」へ変更。
    - 既存の強調行がある場合は、次行への強調切り替えを保留し、背景歌詞の移動完了後に切り替えるフローを追加。
    - これにより、強調位置が先にガクッと切り替わる見え方を抑え、後ろのテキストだけが流れる印象へ調整。
- **実装詳細**:
    - `animateLyricsScrollTo()` に完了コールバックを追加し、アニメーション終端で `active` を更新。
    - `setActiveLyricsLineByIndex()` を新設して強調切り替え処理を一元化。
    - 連続更新時の古い完了処理を無効化するため、`lyricsActiveSwapToken` を導入。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-6z` に更新。

### 行数差で不安定だった強調切替方式を廃止し表示を簡素化

- **強調切替ロジックの回帰**:
    - `src/renderer/js/features/lyrics-manager.js`: スクロール完了後に `active` を切り替える方式を廃止。
    - `updateSyncedLyrics()` を即時強調切替に戻し、行数差による不自然な遷移を解消。
    - `lyricsActiveSwapToken` / `pendingActiveLyricsIndex` を削除し、分岐を簡素化。
    - `animateLyricsScrollTo()` から完了コールバックを除去。
- **歌詞スタイルの簡素化**:
    - `src/renderer/styles/views.css`: `active` 行のグラデーション背景とボックスシャドウを削除。
    - `active` 行は白文字でクリアに表示し、他行はぼかしと低めの不透明度で背景化。
    - これにより「強調行ははっきり、その他はぼける」見え方へ調整。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7a` に更新。

### 行切り替え時の急なスクロールを連続追従へ変更

- **スクロール制御の平滑化**:
    - `src/renderer/js/features/lyrics-manager.js`: 行切替時のみ移動していた方式を改め、再生時間に応じた連続スクロールへ変更。
    - 現在行から次行までの時間進行を使って目標位置を補間し、次行へ向けて先行的に少しずつ移動するよう調整。
    - `animateLyricsScrollTo()` を再始動型アニメーションから「目標値追従型」に変更し、目標更新時のガクつきを抑制。
    - 行が切り替わった瞬間のみ wave ラグを発火し、常時発火によるノイズを防止。
- **強調表示の扱い**:
    - `active` の切り替えは従来どおり維持しつつ、背景スクロールだけを連続化して急な切替感を軽減。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7b` に更新。

### スクロール開始タイミングを従来基準へ回帰

- **開始タイミングの調整**:
    - `src/renderer/js/features/lyrics-manager.js`: 次行への先行スクロール補間（時間進行ベース）を廃止。
    - スクロール目標は再び「現在アクティブ行の位置」のみに設定し、動き始めのタイミングを従来と同等に戻した。
    - 目標値追従型のスクロール制御は維持し、開始タイミングを遅らせつつ移動自体は滑らかに保つ構成へ調整。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7c` に更新。

### 行切り替えスクロールへイージングを適用

- **切り替え時スクロールの補間を改善**:
    - `src/renderer/js/features/lyrics-manager.js`: 行切り替え時の追従係数に `easeOutCubic` を適用。
    - `animateLyricsScrollTo()` に `switchEasing` オプションを追加し、行切替時だけ明示的なイージングカーブで追従。
    - 通常追従時と切替時で追従係数を分離し、切替スクロールの急な印象を緩和。
    - 切替スクロール完了後は `switchEasing` 状態をリセットし、次の通常追従に復帰。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7d` に更新。

### 行切り替えスクロールをゆったり化

- **追従速度の再調整**:
    - `src/renderer/js/features/lyrics-manager.js`: 行切替時/通常時の `followStrength` をともに低下。
    - 切替時は `0.06 + easedDistanceRatio * 0.17` へ変更し、最大追従速度を抑制。
    - 通常時は `0.09 + distanceRatio * 0.13` へ変更し、全体の追従を穏やかに調整。
    - イージング形状は維持し、テンポ感のみ「クイック」から「ゆったり」へ変更。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7e` に更新。

### 行切り替えのクイック感をさらに抑制

- **切り替え時の速度上限を導入**:
    - `src/renderer/js/features/lyrics-manager.js`: 行切替時/通常時の `followStrength` をさらに低下。
    - 1フレームあたりの移動量に上限（`maxStep`）を追加し、急なジャンプ移動を抑制。
    - 切替時は最大 4.6px、通常時は最大 6.2px に制限して視覚的な「クイッ」を軽減。
- **ラグ演出の発火条件を調整**:
    - `triggerLag` の発火を大きめの移動時（24px超）に限定し、細かい行切替での過剰演出を回避。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7f` に更新。

### ぼかし解除に短いフェードインを追加

- **フォーカス遷移の調整**:
    - `src/renderer/styles/views.css`: `#lyrics-view p` に `--line-focus-delay` を追加。
    - `opacity` / `filter` / `text-shadow` の遷移に `--line-focus-delay` を適用し、ぼかし解除を即時ではなく短い遅延付きで開始。
    - `#lyrics-view p.active` で `--line-focus-delay: 72ms` を設定し、アクティブ化時にわずかなフェードイン感を付与。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7g` に更新。

### 行切替クイック感を復帰し、TXT表示の特殊効果を無効化

- **行切替スクロールのクイック感を復帰**:
    - `src/renderer/js/features/lyrics-manager.js`: 速度抑制のために追加した1フレーム移動量上限を撤去。
    - `followStrength` を以前の値（切替時 `0.06 + easedDistanceRatio * 0.17` / 通常時 `0.09 + distanceRatio * 0.13`）へ復元。
    - wave ラグ発火条件を `LYRICS_SCROLL_MIN_DISTANCE_PX` 基準へ戻し、切替時のテンポ感を復帰。
- **TXT歌詞のエフェクト無効化**:
    - `src/renderer/js/features/lyrics-manager.js`: 歌詞ビューに `lyrics-mode-lrc` / `lyrics-mode-txt` クラスを付与する処理を追加。
    - `clearLyrics()` / `displayNoLyrics()` でモードクラスをリセットし、前曲の表示効果を持ち越さないよう修正。
    - `src/renderer/styles/views.css`: `#lyrics-view.lyrics-mode-txt p` で blur/transform/遅延遷移を無効化し、通常テキスト表示へ変更。
- **検証**:
    - `node --check src/renderer/js/features/lyrics-manager.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7h` に更新。

### CoreML 前提 TXT 自動同期歌詞の追加

- **バックエンド同期サービスの新設**:
    - `internal/lyricssync/` を新規作成し、以下を実装。
      - `syncer.go`: ffmpeg 抽出 → whisper 実行 → 行整列 → 補間 → 単調性補正の統合パイプライン。
      - `whisper_runner.go`: `whisper-cli` 実行、JSONセグメント解析、モデル探索（環境変数優先 + 既定パス）。
      - `align.go`: TXT行と認識セグメントの単調整列、未一致行の補間、逆転時刻の補正。
      - `normalise.go`: 記号/空白除去、全角半角吸収、大小文字吸収の正規化。
      - `types.go`: `Request` / `AlignedLine` / `Result` の I/O 定義。
    - ログプレフィックスを `[Lyrics AutoSync]` で統一。
- **Wails 公開APIの追加**:
    - `app.go`: `lyricsSyncer` を App 構造体に組み込み。
    - `app_lyrics.go`: `AutoSyncLyrics(req lyricssync.Request)` を追加。
- **フロントエンド連携**:
    - `src/renderer/components/lrc-editor.html`: 「自動同期解析」ボタンを追加。
    - `src/renderer/js/features/lrc-editor.js`: `lyrics-auto-sync` invoke、実行中状態、結果反映、通知表示を実装。
    - `src/renderer/styles/lrc-editor.css`: 自動同期ボタンの通常/実行中/無効状態スタイルを追加。
    - `src/renderer/js/core/env-setup.js`: Wails invoke dispatch に `lyrics-auto-sync` を追加。
- **保存方針**:
    - 自動同期はエディタ上のプレビュー反映のみで、既存の「LRCを保存」操作でのみファイル保存される設計を維持。
- **テスト追加**:
    - `internal/lyricssync/normalise_test.go`: 文字正規化と間奏判定。
    - `internal/lyricssync/align_test.go`: 単調整列と補間の挙動。
    - `internal/lyricssync/syncer_test.go`: 空行エラー、CLI未配置、モデル未配置、擬似 `ffmpeg` / `whisper-cli` による結合検証。
- **ドキュメント更新**:
    - `markdown/Task.md`: 本タスクの完了条件を追加。
    - `markdown/features.md`: TXT自動同期解析を機能一覧に追記。
    - `markdown/requirement.md`: CoreML前提の運用条件と仕様を追加。
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7i` に更新。

### 歌詞自動同期のボーカル重視前処理とフォールバック改善

- **症状**:
    - 実機ログで `whisper のセグメント結果が空です` が発生するケースがあった。
    - 同期精度向上のため、伴奏影響を抑えた前処理の要望を受領。
- **対応**:
    - `internal/lyricssync/whisper_runner.go`:
      - `whisper-cli` の JSON 解析を `segments` 形式に加えて `transcription` 形式にも対応。
      - `timestamps` / `offsets` から秒への変換処理を追加。
    - `internal/lyricssync/syncer.go`:
      - 同期前処理にボーカル重視フィルタ音声を追加（帯域制限・コンプレッション・ノイズ低減）。
      - ボーカル重視候補の一致率が低い場合、通常音声候補を追加解析して自動比較。
      - 一致行数と平均信頼度で最良候補を採用するロジックへ拡張。
    - `internal/lyricssync/syncer_test.go`:
      - 候補比較ロジックと補助関数のテストを追加。
    - `internal/lyricssync/whisper_runner_test.go`:
      - `segments` と `transcription` の両 JSON フォーマット解析テストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
    - `node --check src/renderer/js/features/lrc-editor.js`
    - `node --check src/renderer/js/core/env-setup.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7j` に更新。

### 空白行（前奏・間奏）補間の改善

- **課題**:
    - 空白行が多い区間で、未一致行の補間時に空白が時間配分を取りすぎるケースがあった。
- **対応**:
    - `internal/lyricssync/align.go`:
      - 補間を重み付き方式へ変更。
      - 空白/間奏行（`Source=interlude`）の重みを下げ、歌詞行へ時間配分を優先。
      - 先頭/末尾の補間ステップも空白行で縮小するよう調整。
    - `internal/lyricssync/align_test.go`:
      - 空白行が混在する区間での重み付き補間テストを追加。
      - 一致ゼロ時に空白行ステップが歌詞行より小さくなることを検証。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7k` に更新。

### 前奏（先頭空白行）アンカー改善と低域カット調整

- **課題**:
    - 先頭の空白行がある歌詞で、前奏の時間幅が十分に残らず、最初の歌詞が早めに配置されるケースがあった。
    - ボーカル重視前処理において、人声として不要な低域カット閾値を調整したい要望があった。
- **対応**:
    - `internal/lyricssync/align.go`:
      - 先頭補間ロジックを変更し、先頭行が空白/間奏なら 0 秒アンカーを固定するように修正。
      - 先頭未一致区間を 0 秒〜最初の一致行時刻で重み付き配分し、前奏を潰さない補間に変更。
    - `internal/lyricssync/syncer.go`:
      - ボーカル重視フィルタを `highpass=70Hz` / `lowpass=4500Hz` に調整。
      - 50Hz付近など人声帯域外の低域をより明確に抑制。
    - `internal/lyricssync/align_test.go`:
      - 先頭空白行が 0 秒アンカーになることを確認するテストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7l` に更新。

### 自動同期の検知テキスト可視化（デバッグ表示）

- **課題**:
    - 自動同期時に `whisper` が実際に何を検知しているかを画面上で確認したい要望があった。
- **対応**:
    - `internal/lyricssync/types.go`:
      - `Result` に `DetectedBy` と `DetectedSegments` を追加し、採用候補と検知セグメントを返せるように拡張。
    - `internal/lyricssync/syncer.go`:
      - 最終採用候補（`vocal-focus` / `plain`）のセグメントを `Result` に格納して返却する処理を追加。
    - `src/renderer/components/lrc-editor.html`:
      - 「検知テキスト表示」ボタンと表示ポップアップを追加。
    - `src/renderer/js/features/lrc-editor.js`:
      - 自動同期結果から `detectedSegments` を保持し、ポップアップで時刻付きテキストを表示する処理を実装。
    - `src/renderer/styles/lrc-editor.css`:
      - 検知テキスト表示ボタンとポップアップのスタイルを追加。
    - `wails generate module`:
      - `lyricssync.DetectedSegment` を含む生成コードを更新。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
    - `node --check src/renderer/js/features/lrc-editor.js`
    - `node --check src/renderer/js/core/env-setup.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7m` に更新。

### 先頭セグメントの無音トリム補正（前奏つぶれ対策）

- **課題**:
    - 実機で、先頭セグメントが `0.00` 開始かつ長尺になり、最初の歌詞行が早すぎる時刻に吸着するケースがあった。
- **対応**:
    - `internal/lyricssync/align.go`:
      - セグメント整列前にアンカー時刻を算出する処理を追加。
      - 先頭セグメントのみ、開始 `0.00` かつ異常長の場合に、テキスト長と推定文字速度から先頭無音ぶんをトリムする補正を実装。
      - 一般ケースは従来どおり `segment.Start` を使用し、副作用を最小化。
    - `internal/lyricssync/align_test.go`:
      - 先頭長尺セグメント時に、先頭空白行を `0` に維持しつつ最初の歌詞行が早すぎないことを検証するテストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
    - `node --check src/renderer/js/features/lrc-editor.js`
    - `node --check src/renderer/js/core/env-setup.js`
    - `node --check src/renderer/js/core/bridge.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7n` に更新。

### 空白行の時刻吸収を抑制する補間調整

- **課題**:
    - 空白/間奏行がある区間で、未一致歌詞行の時刻が想定より手前に引っ張られるケースがあった。
- **対応**:
    - `internal/lyricssync/align.go`:
      - 補間時に、同一区間内に歌詞行が存在する場合は空白/間奏行の重みを極小値へ切替するロジックを追加。
      - 先頭空白アンカー (`0s`) から最初の一致行までの補間では、右アンカー寄せの tail weight を導入し、先頭歌詞が早まりにくいよう調整。
    - `internal/lyricssync/align_test.go`:
      - 先頭空白 + 先頭歌詞未一致のケースで、歌詞行が過度に早くならないことを確認するテストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
    - `node --check src/renderer/js/features/lrc-editor.js`
    - `node --check src/renderer/js/core/env-setup.js`
    - `node --check src/renderer/js/core/bridge.js`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7o` に更新。

### 空白行のみ区間の右アンカー寄せ補間

- **課題**:
    - 空白行のみの区間で、空白行が直前歌詞の直後に配置され、歌詞表示がすぐ空行へ遷移して見える問題があった。
- **対応**:
    - `internal/lyricssync/align.go`:
      - 空白/間奏行のみで構成される補間区間は、右アンカー寄せの tail weight を適用する処理を追加。
      - これにより空白行が前詰めされず、直前歌詞の表示時間を確保。
    - `internal/lyricssync/align_test.go`:
      - 空白行のみ区間で空白タイムスタンプが即時ジャンプ位置にならないことを検証するテストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7p` に更新。

### 歌詞行先行整列（空白行後段補完）への変更

- **課題**:
    - 空白行が混在することで、未一致歌詞の補間位置が不安定になり、次の空白行に先に飛んで見えるケースがあった。
- **対応**:
    - `internal/lyricssync/align.go`:
      - 整列処理を 2 段階へ変更。
      - 1段階目で歌詞行のみをセグメント整列・補間。
      - 2段階目で空白/間奏行に時刻を補完（右アンカー寄せを維持）。
      - 空白行探索用の補助関数を追加し、前後アンカーがない場合の補間も安定化。
    - `internal/lyricssync/align_test.go`:
      - 「未一致歌詞の次にある空白行へ早跳びしない」回帰テストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7q` に更新。

### MLボーカル抽出（demucs / カスタム抽出器）対応

- **課題**:
    - 既存の帯域フィルタのみでは伴奏残りが多い曲で認識誤りが発生し、さらなる同期精度向上余地があった。
- **対応**:
    - `internal/lyricssync/vocal_ml.go` を新規追加。
      - `UXMUSIC_LYRICS_SYNC_VOCAL_SEPARATOR` 指定時はカスタム抽出器を実行（`<input> <output>` 引数契約）。
      - 未指定時は `demucs` を自動探索し `--two-stems=vocals` で抽出。
      - 抽出結果を `ffmpeg` で 16kHz/mono WAV に正規化して同期処理へ投入。
    - `internal/lyricssync/syncer.go`:
      - 候補評価を `vocal-ml` → `vocal-focus` → `plain` の順に統合。
      - 候補の一致率・信頼度・優先順位で最良候補を採用する方式に更新。
    - `internal/lyricssync/syncer_test.go`:
      - 候補優先順位（`vocal-ml` 優先）テストを追加。
    - `internal/lyricssync/vocal_ml_test.go` を新規追加。
      - カスタム抽出器経由の成功ケース
      - demucs 経由の成功ケース
      - 抽出器未検出のエラーケース
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7r` に更新。

### demucs 実行パス解決の強化と導入確認

- **課題**:
    - macOS GUI 起動時は `PATH` が限定される場合があり、`demucs` が存在しても検出できないケースがある。
    - Python 3.14 環境では `demucs` 依存が解決しづらい導入エラーが発生した。
- **対応**:
    - `internal/lyricssync/vocal_ml.go`:
      - `resolveDemucsPath()` を追加し、`demucs` の探索順を `UXMUSIC_LYRICS_SYNC_DEMUCS` → `PATH` → `/opt/homebrew/bin/demucs` → `/usr/local/bin/demucs` に拡張。
    - `internal/lyricssync/vocal_ml_test.go`:
      - `UXMUSIC_LYRICS_SYNC_DEMUCS` の有効/無効ケースを検証する単体テストを追加。
    - 実機導入確認:
      - `python3.10 -m pip install demucs==4.0.1` で導入可能なことを確認（Python 3.14 失敗時の代替手順）。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7s` に更新。

### demucs 失敗時の連鎖タイムアウト対策

- **課題**:
    - `demucs` が長時間実行または強制終了された場合、同一 `context` を使い回していたため後続 `whisper` 候補まで `context deadline exceeded` で連鎖失敗していた。
- **対応**:
    - `internal/lyricssync/syncer.go`:
      - タイムアウトを段階分離（ML抽出用・候補解析用）へ変更。
      - 候補解析ごとに新しい `context.WithTimeout` を作成し、前段失敗が後段に波及しないよう修正。
    - `internal/lyricssync/vocal_ml.go`:
      - demucs の既定引数を `--name mdx_extra_q --jobs 1` に変更し、メモリ負荷を低減。
      - `UXMUSIC_LYRICS_SYNC_DEMUCS_MODEL` でモデル上書きを可能化。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7t` に更新。

### demucs diffq 依存エラー時の自動モデルフォールバック

- **課題**:
    - `demucs --name mdx_extra_q` 実行時に `diffq` 未導入エラーで ML 抽出が失敗するケースがあった。
- **対応**:
    - `internal/lyricssync/vocal_ml.go`:
      - 既定モデルを `mdx_extra` に変更し、追加依存なしで動作しやすい構成へ修正。
      - 指定モデル失敗時の再試行候補を生成し、`*_q` モデルで `diffq` エラー検出時は自動で非量子化モデルへフォールバック。
      - demucs 実行失敗ログを候補別に集約して返却するよう改善。
    - `internal/lyricssync/vocal_ml_test.go`:
      - `mdx_extra_q` 失敗（diffqエラー）から `mdx_extra` 成功へ自動切替するテストを追加。
      - モデル候補生成ロジックの単体テストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7u` に更新。

### 長尺曲での候補解析タイムアウト自動調整

- **課題**:
    - 長尺曲で `whisper` 候補解析が固定2分タイムアウトに達し、`context deadline exceeded` で失敗するケースがあった。
- **対応**:
    - `internal/lyricssync/syncer.go`:
      - `ffprobe` で音声長を取得し、`whisper` / `vocal-ml` タイムアウトを音声長ベースで動的算出するロジックを追加。
      - 段階別タイムアウト設定値をログ出力し、解析失敗時の原因切り分けを容易化。
      - `ffprobe` パス解決関数を追加（`config.FFprobePath` 優先 + `PATH` フォールバック）。
    - `internal/lyricssync/syncer_test.go`:
      - `computeWhisperTimeout` / `computeVocalMLTimeout` の単体テストを追加。
- **検証**:
    - `go test ./internal/lyricssync`
    - `go test ./...`
- **バージョン情報の更新**:
    - `src/renderer/js/core/bridge.js` と `requirement.md` のバージョンを `0.1.9-Beta-7v` に更新。
