# Implementation Plan - Electron & Node.js Removal

ElectronおよびNode.jsへの依存を完全に排除し、純粋なWails (Go + Web) アプリケーションへ移行するための計画です。

## User Review Required

> [!IMPORTANT]
> **MTP機能のGo移行について**
> 現在Node.jsから`koffi`経由で利用している`kalam.dylib`を、Goの`Cgo`機能を用いて直接呼び出す実装に変更します。
> これには`kalam.dylib`の関数シグネチャをGo側で正確に定義する必要があります。既存の`src/sidecars/mtp/index.js`を参考に定義を作成しますが、動作検証が重要になります。

## Proposed Changes

### 1. Backend Migration (Go)

Node.js SidecarおよびElectron Main Processで行っていた処理をGoに移植します。

#### [NEW] `pkg/cdrip`
CDリッピング機能をGoパッケージとして実装します。
- `cdparanoia` コマンドの実行ラッパー
- MusicBrainz APIクライアント (メタデータ取得)
- `ffmpeg` コマンド実行によるエンコード処理
- **File**: `pkg/cdrip/ripper.go`, `pkg/cdrip/metadata.go`

#### [NEW] `pkg/mtp`
MTPデバイス操作機能をGoパッケージとして実装します。
- `kalam.dylib` (C# Native Library) のロードと関数呼び出し (Cgo使用)
- コールバック処理の実装
- **File**: `pkg/mtp/mtp.go`, `pkg/mtp/kalam_wrapper.go`

#### [NEW] `pkg/normalize`
音量正規化機能をGoパッケージとして実装します。
- `ffmpeg` を使用したラウドネス解析と正規化
- ゴルーチンを用いた並列処理
- **File**: `pkg/normalize/normalizer.go`

#### [MODIFY] `app.go`
- 新しいパッケージ (`cdrip`, `mtp`, `normalize`) の統合
- `NodeSidecar` 関連コードの削除
- 不足しているIPCハンドラの移植 (コンテキストメニュー制御、システムダイアログなど)

#### [MODIFY] `main.go` / `wails.json`
- アプリケーションのビルド設定調整
- `sys/main/bin` などのリソースパス設定の確認

### 2. Frontend Migration (Renderer)

`src/renderer` 以下のコードからElectron依存を排除します。

#### [MODIFY] `src/renderer/js/env-setup.js` & Bridge
- `window.electron` および `ipcRenderer` の完全削除
- 全てのAPI呼び出しを `window.go.main.App` または `window.runtime` 経由に変更
- 必要に応じて `bridge.js` を更新し、APIインタフェースを統一

### 3. Cleanup

不要になったファイルを削除します。

#### [DELETE]
- `src/main` (Electron Main Process)
- `src/sidecars` (Node.js Sidecars)
- `node_sidecar.go`
- `sidecar_main.go`
- `package.json` から `electron` 関連の依存パッケージ削除

## Verification Plan

### Automated Tests
- Go単体テスト: 新規作成する `pkg/cdrip`, `pkg/normalize` の単体テストを作成し実行。
- `go test ./...`

### Manual Verification
1. **CD Ripping**: 実機CDドライブでリッピング、タグ付け、エンコードが正常に行われるか確認。
2. **MTP**: Walkman等のデバイスを接続し、ファイル一覧取得、転送、削除ができるか確認。
3. **Normalize**: 複数ファイルを選択し、並列で正規化処理が実行されるか確認。
4. **Build**: `wails build` が成功し、生成されたアプリがElectronなしで起動するか確認。
