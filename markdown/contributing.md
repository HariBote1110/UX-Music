# 開発への貢献 (CONTRIBUTING.md)

このプロジェクトへの貢献に興味を持っていただきありがとうございます。

## 🛠️ 技術スタック

- **フレームワーク**: Electron
- **言語**: JavaScript (Node.js), HTML5, CSS3
- **主要ライブラリ**:
    - `sharp`: アートワークの画像処理
    - `@distube/ytdl-core`: YouTube関連処理
    - `music-metadata`: 音声ファイルのメタデータ解析
    - `fluent-ffmpeg`: 音声ファイルのラウドネス値解析
    - `electron-builder`: アプリケーションのビルド

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
    npm start
    ```

## 📌 比較用ディレクトリの扱い

- `Electron_Based_UX-Music/` は、Wails 版移行後に機能差分を確認するための比較用リファレンスです。
- 通常の実装変更は Wails 側（ルート配下の `src/` など）に対して行い、`Electron_Based_UX-Music/` は原則編集しません。
- 比較資料そのものを更新する必要がある場合のみ、目的を明記したうえで例外的に編集します。

## 🐛 デバッグコマンド

開発者コンソール（`Option + Command + I` on macOS）から以下のコマンドを実行できます。

-   `uxDebug.resetLibrary()`: 全てのライブラリデータ（曲、再生回数、アートワークなど）を削除します。**（注意: この操作は元に戻せません）**
-   `uxDebug.help()`: 利用可能なコマンドの一覧を表示します。
