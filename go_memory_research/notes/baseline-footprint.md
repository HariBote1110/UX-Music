# バックグラウンド時 Go プロセス約100MB のベースライン内訳

## 目的 / 仮説
WebView 破棄後に残る UX-Music 本体（Go プロセス）の footprint 約100MB の内訳を確定する。
仮説: (a) Go ヒープ（ライブラリ・キャッシュ類）、(b) ネイティブ malloc（音声バッファ等）、(c) フレームワーク定常コスト、のいずれが支配的か。

## 環境
- ホスト: Apple M4 / 32GB RAM / macOS 26.5.2 (25F84)
- 対象: build/bin/UX-Music.app（branch feature/native-queue-background, v1.0.0-Beta-64d、フォーク cecf1be）
- ライブラリ: library.json 700KB（≒中規模）
- 計測: `footprint <pid>` / `heap -s <pid>`（起動15秒後と駐機40秒後）

## 手順
```
open build/bin/UX-Music.app && sleep 15
footprint $(pgrep -f build/bin/UX-Music.app/Contents/MacOS/UX-Music)
heap -s $(pgrep ...)
# Finder 経由で hide → 40秒後に再測定
```

## 結果
| 区分 | 起動直後 | 駐機後(hide+40s) | 中身 |
|---|---|---|---|
| footprint 合計 | 100MB (peak 119MB) | 約98MB | ほぼ不変（駐機で減るのは WebKit 側のみ） |
| untagged (VM_ALLOCATE) dirty | 44MB | 43MB | **Go ランタイムヒープ**（mmap 経由のため untagged） |
| MALLOC_SMALL + LARGE dirty | 37MB | 37MB | ネイティブ malloc。生存ノード実質 24MB |
| うち non-object | 16.6MB | — | **352KB×33個の均一ブロックが約11.6MB**（未帰属・音声バッファ疑い） |
| WebKit malloc (in-process) | 4.3MB | 3.8MB | WKWebView のプロセス内プロキシ |
| __DATA / __DATA_DIRTY / その他 | 約15MB | 同 | フレームワーク・バイナリ定常コスト（削減余地ほぼ無し） |

ObjC クラス別で目立つものは NSMutableDictionary 0.8MB / CFString 0.6MB 程度で、ネイティブ側に「肥大」と呼べる単一犯はいない。

## 結論
- 100MB の主因は **Go ヒープ 44MB** と **ネイティブ malloc 37MB（うち 352KB×33 の未帰属ブロック 11.6MB）**。フレームワーク定常 15MB は削れない。
- 仮説 (c) 単独説は棄却。(a)(b) の複合。
- 駐機前後で Go プロセス側はほぼ不変（膨張ではなく定常値）。

## 次の一手 / 未検証事項
1. Go ヒープ 44MB の名前付け: pprof（デバッグゲート付き `net/http/pprof`）を LAN サーバへ一時追加して heap profile を取る
2. 352KB×33 ブロックの帰属: `MallocStackLogging=1` で起動し `malloc_history` で割当元スタックを取る（コード変更不要）
3. Go の RSS はランタイムが OS へ返しにくい点に注意（`GOMEMLIMIT`/`debug.FreeOSMemory` は対症）。まず中身の名前付けが先
