# 技術仕様書 (document.md)

## 1. プロジェクト概要

このプロジェクトは、Electronフレームワークを使用して構築されたデスクトップ音楽プレーヤー「UX Music」です。ローカルの音楽ファイル、YouTube、そしてCDなどの多岐にわたる音源を統合的に管理・再生することを目的としています。

## 2. ディレクトリ構造と主要ファイルの役割

### 2.1. `src/main/` - メインプロセス

-   **`index.js`**: エントリーポイント。カスタムプロトコルの登録や、メインプロセスの初期化を担当。
-   **`ipc-handlers.js`**: 各ハンドラを集約し、レンダラープロセスとの通信を管理。
-   **`data-store.js`**: 設定やライブラリ情報のJSON永続化クラス。
-   **`handlers/`**:
    -   `library-handler.js`: ライブラリのスキャン、インポート、メタデータ解析。
    -   `cd-rip-handler.js`: CDの吸い出し、MusicBrainz連携、エンコード処理。
    -   `system-handler.js`: 設定、履歴、Discord連携、クイズスコア管理。
    -   `playlist-handler.js`: プレイリストファイル(`.m3u8`)の操作。
    -   `youtube-handler.js`: YouTube音源の処理。
-   **`mtp/`**: MTPデバイス（Walkman等）との通信・転送ロジック。
-   **`mood-analyzer.js`**: 楽曲データからムードパターンの適合性を解析し、プレイリストを生成。
-   **`history-analyzer.js`**: 再生履歴を解析し、パーソナルプレイリストを生成。
-   **`*-worker.js`**: 重い処理を行うためのWorkerスレッド群。

### 2.2. `src/renderer/` - レンダラープロセス

-   **`index.html`**: シングルページアプリケーションのベースHTML。
-   **`renderer.js`**: レンダラープロセスの起動とモジュール初期化。
-   **`js/`**:
    -   `player.js`: Web Audio API。EQ、ビジュアライザー、再生制御の核。
    -   `state.js`: アプリ全体のグローバルな状態管理。
    -   `navigation.js`: ビューの切り替えと履歴管理。
    -   `ui-manager.js` / `ui/`: 仮想スクロールや要素の動的生成。
    -   `quiz.js`: イントロクイズのゲームロジック。
    -   `mtp-browser.js`: MTP転送用UIの制御。
    -   `cd-ripper.js`: CDリッピングUIの制御。

## 3. 主要な処理フロー

### アプリケーションの起動
1.  **`main/index.js`**: 起動時にプロトコル登録、USB監視開始。
2.  `renderer/index.html` のロード。
3.  **`ipc-handlers.js`**: 各ハンドラの初期化（`stores`を経由して設定を共有）。
4.  **`renderer/renderer.js`**: ライブラリ、設定、プレイリストのフェッチとUI描画。

### CDリッピングフロー
1.  `cd-rip-handler.js` が `cdparanoia` を実行してTOCを取得。
2.  MusicBrainz APIからメタデータを取得。
3.  `ffmpeg` Workerが一時WAVを生成し、指定フォーマットにエンコード＆タグ付与。
4.  完了後、ライブラリパスへ移動。