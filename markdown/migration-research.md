# Electron から Wails への移行難易度調査レポート

## 1. 総合評価
**難易度：高 (High)**

本アプリケーションは単なるWebラッパーではなく、USB/MTPデバイス制御、FFmpegによる音声処理、CDリッピングなど、OSのネイティブ機能やバイナリに深く依存しています。そのため、移行にはバックエンドの大規模な書き換えと、フロントエンドのNode.js依存の完全な排除が必要です。

## 2. 主要な技術的課題

### A. バックエンド (Main Process) の完全な再実装
現在 `src/main/ipc-handlers.js` (~800行) で定義されているロジックをすべて Go で書き直す必要があります。
- **MTP/USB制御**: `koffi` (Node FFI) による `kalam.dylib` の呼び出しを、Goの `cgo` または別のライブラリに移植する必要があります。
- **音声処理 (FFmpeg)**: Node.jsの `worker_threads` と `fluent-ffmpeg` を使用した正規化・解析処理を、Goの goroutine と `os/exec` による実装に変更する必要があります。
- **データ永続化**: JSONファイルベースの `DataStore` を Go の構造体とJSONエンコーディングで再実装します。

### B. フロントエンド (Renderer) の Node.js 依存排除
- 現在のレンダラーは `nodeIntegration: true` で動作しており、`require('electron')` などを直接使用しています。
- Wails ではレンダラーでの Node.js 使用が禁止されているため、すべての IPC 通信を Wails の `window.go` 経由のリクエストに置き換え、Node.js 固有のモジュール（`fs`, `path` 等）の使用を排除する必要があります。

### C. OS固有機能とビルド
- **CDリッピング**: macOS固有の `drutil` 等の呼び出しを Go で実装し直す必要があります。
- **バイナリ管理**: `ffmpeg-static` 等の npm パッケージに頼らず、Wails の `frontend:embed` や外部バイナリ配布の仕組みを構築する必要があります。

## 3. 移行のメリットとデメリット

| 項目 | Electron (現状) | Wails (移行後) |
| :--- | :--- | :--- |
| **実行ファイルサイズ** | 大きい (100MB+) | 非常に小さい (10MB〜) |
| **メモリ使用量** | 高い (Chromium + Node) | 低い (OS標準Webview + Go) |
| **開発言語** | JS/TS (全域) | Go (Backend) / JS (Frontend) |
| **エコシステム** | 膨大 (npm) | Go の強力な標準ライブラリ/パッケージ |

## 4. 推奨されるステップ (移行する場合)
1. **Frontend のクリーンアップ**: まずレンダラーから `require` を排除し、すべてのバックエンド通信を `preload.js` (またはそれに類する抽象レイヤー) に集約する。
2. **Go Backend のプロトタイプ**: `kalam.dylib` を Go から呼び出せることを確認する。
3. **段階的移行**: 重要な IPC ハンドラから順に Go へ移植する。

---
調査日: 2026-01-20
調査担当: Antigravity
