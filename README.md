# UX Music

[![icon](./src/renderer/assets/ux-music-icon.png)](./src/renderer/assets/ux-music-icon.png)

ローカル・オンラインの音源を統合的に管理・再生できる、モダンなデスクトップ音楽プレーヤー。

## 🖥️ 対応OS

-   **macOS**
-   **Windows**

上記OSにて動作確認済みです。

> [!WARNING]
> **ハイパワーマシン向け**
> このアプリケーションは、楽曲のインポート時に音声解析などの処理を行うため、CPUリソースを大きく消費する場合があります。快適にご利用いただくためには、比較的高性能なPCでの使用を推奨します。

---

## ✨ 主要機能

### 🎵 ライブラリ管理

-   **多様なインポート**: ファイルやフォルダのドラッグ＆ドロップ、YouTubeのURL指定（単体・プレイリスト）に対応。
-   **アートワーク管理**:
    -   アルバム単位でアートワークを管理し、データ読み込みを高速化。
    -   リスト表示用に軽量なサムネイル画像を自動生成し、軽快なスクロールを実現。
-   **YouTubeダウンロード**:
    -   「最高品質（映像付き）」か「音声のみ」かを選択可能。
    -   ダウンロード完了時にラウドネス値を自動で解析し、再生音量を正規化。
-   **楽曲の完全削除**: ライブラリとファイルシステムの両方から楽曲を完全に削除可能。

### プレイリスト

-   **作成・編集**: `m3u8`形式でプレイリストを永続的に保存し、ドラッグ＆ドロップで曲順を変更可能。
-   **アルバム単位での追加**: アルバム内の全曲を一度にプレイリストへ追加。
-   **YouTubeプレイリスト連携**: YouTubeプレイリストのURLをインポートすると、同名のプレイリストを自動で作成。

### 再生機能

-   **オーディオノーマライザー**: 楽曲ごとにラウドネス値（LUFS）を解析し、再生音量を自動で均一化。
-   **多彩な再生モード**: 通常再生、全曲リピート、1曲リピート、シャッフル再生に対応。
-   **高品質なUI**:
    -   `requestAnimationFrame`により、滑らかに動作するシークバー。
    -   OSのメディアキー（再生/一時停止、曲送り/戻し）からの操作に対応。
-   **再生デバイスの切り替え**: アプリ内のポップアップから、オーディオの出力先を動的に変更可能。

### 🎨 UI・UX

-   **仮想スクロール**: 数千曲規模のライブラリでも軽快なスクロールと高速な起動を実現。
-   **Dynamic Island風イコライザー**: 再生中の楽曲のジャケットカラーを反映した、リアルタイムで動くイコライザーを表示。
-   **歌詞表示**: 再生中の曲とファイル名が一致する`.lrc`または`.txt`ファイルを自動で検索し表示。
-   **テキストの自動スクロール**: 表示領域からはみ出す長いテキストは、マウスオーバーでスクロール表示。
-   **キーボードショートカット**: `Space`キーで再生/一時停止、`0`キーで曲の先頭にシーク。

---

## 🛠️ 技術スタック

-   **フレームワーク**: Electron
-   **言語**: JavaScript (Node.js), HTML5, CSS3
-   **主要ライブラリ**:
    -   `sharp`: アートワークの画像処理
    -   `@distube/ytdl-core`: YouTube関連処理
    -   `music-metadata`: 音声ファイルのメタデータ解析
    -   `fluent-ffmpeg`: 音声ファイルのラウドネス値解析
    -   `electron-builder`: アプリケーションのビルド

---

## 開発者向け

### デバッグコマンド

開発者コンソールから以下のコマンドを実行できます。

-   `uxDebug.resetLibrary()`: 全てのライブラリデータ（曲、再生回数、アートワークなど）を削除します。**（注意: この操作は元に戻せません）**
-   `uxDebug.help()`: 利用可能なコマンドの一覧を表示します。
