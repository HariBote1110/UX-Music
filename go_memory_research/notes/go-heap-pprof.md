# Go ヒープ 44MB の内訳を pprof で名前付け

## 目的 / 仮説
baseline-footprint.md で特定した「untagged (VM_ALLOCATE) dirty 約44MB = Go ランタイムヒープ」の中身を、
`net/http/pprof` のヒーププロファイルで具体的に名前付けする。
仮説: ライブラリストア／アートワーク／同期／音声リングバッファ／FFT のいずれかが単一の支配的要因である。

## 環境
- ホスト: Apple M4 / 32GB RAM / macOS 26.5.2 (25F84)
- 対象: build/bin/UX-Music.app（branch feature/native-queue-background, v1.0.0-Beta-64e、フォーク cecf1be）
- 計測: `UXMUSIC_PPROF=127.0.0.1:6060` で起動した診断用 pprof サーバー（`internal/diagnostics/pprof.go`、loopback限定・環境変数未設定時は無効）
- `go tool pprof -top -inuse_space / -inuse_objects http://127.0.0.1:6060/debug/pprof/heap`
- `curl http://127.0.0.1:6060/debug/pprof/heap?debug=1` で `runtime.MemStats` を採取
- `footprint <pid>` で OS 側 dirty ページも併読

## 手順
```
wails build
UXMUSIC_PPROF=127.0.0.1:6060 ./build/bin/UX-Music.app/Contents/MacOS/UX-Music \
  > /tmp/uxm-pprof.log 2>&1 &
sleep 15
go tool pprof -top -inuse_space http://127.0.0.1:6060/debug/pprof/heap
go tool pprof -top -inuse_objects http://127.0.0.1:6060/debug/pprof/heap
curl -s "http://127.0.0.1:6060/debug/pprof/heap?debug=1" | grep -A20 "runtime.MemStats"
footprint $(pgrep -f build/bin/UX-Music.app/Contents/MacOS/UX-Music)

# 駐機後の再計測
osascript -e 'tell application "System Events" to tell process "UX-Music" to set visible to false'
sleep 30
（同じコマンドを再実行）
```

## 結果

### runtime.MemStats（起動15秒後 → hide+30秒後）
| 項目 | 起動直後 | 駐機後(hide+30s) | 備考 |
|---|---|---|---|
| Alloc (=HeapAlloc) | 13.2MB | 22.4MB | GC タイミング依存で変動（下記参照） |
| HeapSys | 32.5MB | 32.5MB | Go が OS から確保済みの総ヒープ領域。両時点で不変 |
| HeapInuse | 15.6MB | 24.3MB | span 単位で「使用中」とマークされた領域 |
| HeapIdle | 17.0MB | 8.2MB | 空きだが未返却の span（HeapSys − HeapInuse） |
| HeapReleased | 4.1MB | 4.1MB | madvise 済みで OS に返却申告済みの部分 |
| **スラック (HeapIdle − HeapReleased)** | **12.9MB** | **4.1MB** | **「生きていないが確保されたまま」の量** |
| Stack / MSpan / MCache | 計 1.3MB | 計 1.4MB | ランタイム固定コスト |
| BuckHashSys | 1.5MB | — | pprof のプロファイルバケット自体が計上される点に注意（診断サーバー起動によるやや過大計上） |
| GCSys / OtherSys | 計 5.3MB | — | GC ビットマップ等、ランタイム固定コスト |
| Sys（合計） | 40.8MB | 41.0MB | baseline の footprint untagged 44MB とほぼ整合 |

駐機後に Alloc が 13.2MB→22.4MB へ増えたのは GC 未実行区間にたまたま採取したためで、リークではない
（HeapSys は完全に不変=32.5MB のまま）。パーク中に新規メモリを大量確保する処理は無い。

### pprof -top -inuse_space（起動15秒後、上位)
| flat | 関数 | 由来 |
|---|---|---|
| 1.6MB | `strings.(*Builder).Write` | 汎用文字列組み立て |
| 1.5MB | `regexp/syntax.(*compiler).inst` | 起動時の正規表現コンパイル（1回限り） |
| 1.5MB (cum 2.1MB) | `runtime.allocm` | Go ランタイムの M（OS スレッド）管理構造体 |
| 1.5MB | `server.cloneSyncMap` | 設定/ライブラリマップの複製（同期処理） |
| 1.5MB (cum 3.6MB) | `encoding/json.(*decodeState).objectInterface` | JSON デコード（設定・ライブラリ） |
| 1.5MB | `encoding/json.unquote` | 同上（文字列アンクオート） |
| 1.2MB | `bytes.growSlice` | JSON エンコード時のバッファ拡張 |
| 0.86MB (cum 2.5MB) | `text/template.JSEscapeString` | **Wails の `EventsEmit`/`Notify`**（フロントエンドへの IPC 文字列エスケープ） |
| 0.54MB | `zeroconf.(*Server).recv4` | mDNS 受信バッファ（LAN サーバー） |
| 0.51MB×3 | `runtime.mcommoninit` / `scavengerState.init` / `acquireSudog` | ランタイム固定コスト |

cum 経路で見ると、支配的なのは:
- `encoding/json.Unmarshal` 系（`store.Load`→`LoadMap`→`syncUnifiedRemoteSongs`/`GetUnifiedLibrary`/`LoadPlayCounts`/`RequestInitialLibrary`）: cum 3.6〜8.8MB。**ライブラリ・設定・再生回数ストアの JSON デコード**が最大の名指し可能な発生源。
- `wails/.../BoundMethod.Call` → `reflect.Value.Call`: cum 8.8MB（上記 JSON 処理を内包する Wails バインディング呼び出し全体）。
- `html/template.JSEscapeString` 経由の `Frontend.Notify`: cum 2.5〜3.7MB（Wails ランタイムの IPC エスケープ、アプリコードではない）。

**単一の支配的サブシステムは存在しない**。音声リングバッファ・FFT・アートワーク処理・MTP はトップに一切出現せず
（起動直後は再生していないため妥当）。LAN サーバー(mDNS)は 0.5MB 程度で軽微。

### pprof -top -inuse_objects
オブジェクト数では `encoding/json.unquote`（46421個, 43%）と `literalInterface`（32768個, 31%）が支配的 —
JSON デコードが生成する小さな `interface{}`/文字列オブジェクトの山であり、まとまった単一アロケーションではない。

## 結論
1. **44MB の untagged VM_ALLOCATE ≒ Go の `runtime.MemStats.Sys`（40.8〜41.0MB）とほぼ一致**。baseline の仮説どおり Go ランタイムヒープで説明がつく。
2. しかしその中身の大半は「**アプリのライブデータ**」ではない。pprof の inuse_space は 11〜22MB 程度しかなく、Sys 41MB との差 19〜30MB は主に:
   - **HeapIdle − HeapReleased のスラック**（4〜13MB、GC タイミング依存）: Go が一度確保した span を OS に返却せず保持している分。
   - **GCSys + BuckHashSys + OtherSys + Stack + MSpan/MCache**（計 7〜9MB）: ランタイム固定コスト（GC ビットマップ、profiling バケット表、goroutine スタック等）。
3. inuse_space の中身で名前が付く最大の要因は **JSON デコード（設定・ライブラリ・再生回数ストアの `store.Load`/`LoadMap`）** と **Wails IPC の文字列エスケープ（`text/template.JSEscapeString` 経由の `EventsEmit`/`Notify`）**。どちらも「持続的なキャッシュ」ではなく、**RPC 呼び出しのたびに発生する一時アロケーション**（GC で回収される）であり、恒常的な footprint 増加の主因ではない。
4. 仮説「ライブラリストア／アートワーク／同期／音声リングバッファ／FFT のいずれかが支配的」は**棄却**。音声・FFT・アートワークはトップに出現せず、支配的な単一犯はいない。実態は「Go ランタイム自体の構造的オーバーヘッド（span 管理・GC・スレッド管理）」が大半で、次点が JSON デコードの一時アロケーション。
5. 駐機（hide）前後で `HeapSys` は完全に不変（32.5MB）——parkしても Go 側のヒープ予約は縮まない。これは Go の scavenger がアイドル span を積極的に OS へ返却しない既知の挙動と一致する。

## 削減可能性の判断
| 項目 | 概算量 | 削減可能性 | 備考 |
|---|---|---|---|
| HeapIdle−HeapReleased スラック | 4〜13MB | **中**（要検証） | `debug.FreeOSMemory()` を hide イベント時に呼べば理論上は縮む可能性があるが、macOS の `madvise(MADV_FREE)` は即座に phys_footprint を下げない（メモリ圧がかかるまで OS が回収を遅延する）ため、**効果は保証されない**。次の一手で要検証。 |
| GCSys/BuckHashSys/OtherSys/Stack/MSpan/MCache | 7〜9MB | **低** | Go ランタイムの構造的固定コスト。アプリコードでは触れない。BuckHashSys は診断用 pprof 自体が計上する分を含むため、通常運用時（`UXMUSIC_PPROF` 未設定）はこれよりやや少ない見込み。 |
| JSON デコードの一時アロケーション（store.Load 系） | 数MB（GC で回収） | **低〜中** | `LoadLibrary`/`GetUnifiedLibrary`/`LoadPlayCounts` が起動時に連続して呼ばれ `map[string]interface{}` へのデコードを繰り返している。型付き構造体へのデコードに変えれば個々のアロケーション効率は上がるが、瞬間的な footprint 影響は小さく、常駐 44MB を大きく動かす施策ではない。 |
| Wails IPC エスケープ（JSEscapeString） | 2.5〜3.7MB（GC で回収） | **不可** | フォーク元 Wails ランタイム内部の実装。アプリ側で変更不可。 |
| regexp コンパイル | 1.5MB | **不可** | 起動時1回のみ。サードパーティ（zeroconf/youtube）由来。 |

総括: **44MB のうち、名前付けして「削れる」と自信を持って言えるのは実質数MB〜13MB程度のスラックのみ**。
残りはGoランタイムの構造的コストであり、これ以上の追求は費用対効果が低い。

## 次の一手 / 未検証事項
1. hide（park）イベント契機で `debug.FreeOSMemory()` を試験的に呼び、`footprint` の untagged VM_ALLOCATE が実際に縮むか検証する（madvise の遅延回収特性のため効果は不透明）。
2. `GOMEMLIMIT` を控えめな値（例: 64MiB）に設定して scavenger をより積極的に働かせた場合の footprint 変化を計測する。
3. 352KB×33 ネイティブ malloc ブロック（baseline note の未解決事項）は本調査の対象外のまま — `MallocStackLogging=1` + `malloc_history` での追跡が引き続き必要。
4. 本調査で診断用 pprof サーバーが恒久的にコードベースへ追加された（`internal/diagnostics/pprof.go`、`UXMUSIC_PPROF` 未設定時は完全無効）。今後の継続調査はこれを再利用できる。
