# 開発への貢献 (CONTRIBUTING.md)

このプロジェクトへの貢献に興味を持っていただきありがとうございます。

## 🛠️ 技術スタック

- **フレームワーク**: Wails v2（Go バックエンド + TypeScript/HTML/CSS フロントエンド）。旧 Electron 版は `Electron_Based_UX-Music/` に比較用として残置（下記参照）。
- **言語**: Go, TypeScript, HTML5, CSS3
- **主要ライブラリ / ツール**:
    - `wails`: デスクトップアプリのビルド・実行基盤
    - `sharp`: アートワークの画像処理（フロントエンド側）
    - `music-metadata`: 音声ファイルのメタデータ解析
    - `ffmpeg` / `ffprobe`: 音声ファイルのラウドネス値解析・トランスコード

## 💻 環境構築

1.  リポジトリをクローンします。
    ```bash
    git clone [https://github.com/your-username/UX-Music-beta.git](https://github.com/your-username/UX-Music-beta.git)
    cd UX-Music-beta
    ```

2.  依存関係をインストールします。
    ```bash
    npm install
    ```

3.  アプリケーションを開発モードで起動します。
    ```bash
    wails dev
    ```
    （`Makefile` の `make dev` からも起動できます。）

## 📌 比較用ディレクトリの扱い

- `Electron_Based_UX-Music/` は、Wails 版移行後に機能差分を確認するための比較用リファレンスです。
- 通常の実装変更は Wails 側（ルート配下の `src/` など）に対して行い、`Electron_Based_UX-Music/` は原則編集しません。
- 比較資料そのものを更新する必要がある場合のみ、目的を明記したうえで例外的に編集します。

## 🐛 デバッグコマンド

開発者コンソール（`Option + Command + I` on macOS）から以下のコマンドを実行できます。

-   `uxDebug.resetLibrary()`: 全てのライブラリデータ（曲、再生回数、アートワークなど）を削除します。**（注意: この操作は元に戻せません）**
-   `uxDebug.help()`: 利用可能なコマンドの一覧を表示します。
