# Walkthrough - Electron/Node.js Removal & Go Migration

Electron および Node.js への依存を排除し、Go (Wails) へのバックエンド機能移行が完了しました。

## 実施した変更

### 1. バックエンド機能の Go 移植
以下の主要機能を `pkg` 配下の Go パッケージとして再実装しました。
- **CDリッピング** (`pkg/cdrip`): `cdparanoia` および `ffmpeg` コマンドを Go から実行制御。MusicBrainz メタデータ取得も Go で実装。
- **MTPデバイス連携** (`pkg/mtp`): `Cgo` を使用して `kalam.dylib` を直接呼び出し、Node.js 依存を排除。
- **音量正規化** (`pkg/normalize`): `ffmpeg` の `volumedetect` および `volume` フィルタ操作を Go で実装し、並列処理に対応。

### 2. Electron / Node.js の排除
- `src/main` (Electron Main Process) および `src/sidecars` (Node.js Sidecars) を削除しました。
- `package.json`, `node_modules` を削除しました。

### 3. フロントエンドの最適化
- `src/renderer/js/env-setup.js` を更新し、Electron IPC 呼び出しを Wails ランタイム呼び出し (`window.go.main.App...`) に置換しました。

## 開発環境のセットアップ

### 必要なバイナリ
`bin/macos` ディレクトリに以下のバイナリおよびライブラリが配置されていることを確認してください。
- `cdparanoia`
- `kalam.dylib`
- `libusb.dylib`
- `ffprobe` (あれば)
- `ffmpeg` (なければシステム PATH のものを使用します)

### アプリケーションの実行

Wails CLI を使用して開発モードで実行します。

```bash
wails dev
```

または、標準の Go コマンドでも実行可能ですが、アセット処理のために Wails CLI 推奨です。

## 注意事項 (MTP機能)
MTP機能は `pkg/mtp/lib` 配下のライブラリ (`libkalam.dylib`) にリンクしています。
`pkg/mtp/mtp.go` にて `rpath` を設定しているため、追加の設定なしで動作することを想定していますが、ロードエラーが発生する場合は `DYLD_LIBRARY_PATH` の確認が必要になる場合があります。

```bash
export DYLD_LIBRARY_PATH=$(pwd)/pkg/mtp/lib
wails dev
```
