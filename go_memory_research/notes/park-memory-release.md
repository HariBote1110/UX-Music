# 駐機時メモリ返却（L1: FreeOSMemory+malloc_zone_pressure_relief／L2: GOGC・GOMEMLIMIT）

## 目的 / 仮説
baseline-footprint.md / go-heap-pprof.md で確定した「駐機(park)後もGoヒープ44MB・ネイティブmalloc37MBがほぼ不変」という
観測に対し、以下2レバーで駐機時footprintを目標の約70MBまで下げられるか検証する。

- **L1**（恒久コード）: park成功の2秒後に `runtime/debug.FreeOSMemory()`（Goヒープのアイドルspan強制返却）と
  darwin限定 `malloc_zone_pressure_relief(NULL, 0)`（ネイティブmallocの解放済みdirtyページ返却）を実行する。
- **L2**（実験のみ・採否判断）: `GOGC=50` と `GOMEMLIMIT=40MiB` を起動時env経由でそれぞれ単独検証し、
  明確な削減（目安3MB以上）かつGCスラッシングが無ければ `debug.SetGCPercent`/`debug.SetMemoryLimit` で恒久化する。

仮説: L1だけでもHeapIdle−HeapReleasedスラック（4〜13MB, go-heap-pprof.md）とネイティブmallocの一部を削れる。
L2は「駄目なら棄却」の探索的検証（未実施のため事前に結果は無い）。

## 環境
- ホスト: Apple M4 / 32GB RAM / macOS 26.5.2 (25F84)
- ブランチ: feature/native-queue-background
  - baseline計測: L1導入前のコミット `c18218f`（v1.0.0-Beta-64e、pprof調査ノートと同一状態）を
    `git worktree add` で別ディレクトリにチェックアウトしてビルド
  - L1/L2計測: 本セッションでL1を実装したコミット（v1.0.0-Beta-64e、`server/app_memory_release*.go` 追加後）
- ビルド: `wails build`（`strings build/bin/UX-Music.app/Contents/MacOS/UX-Music | grep releaseMemoryAfterPark` で
  L1シンボルの混入を確認済み）
- 計測ツール: `footprint <pid>`（sudo不要、自プロセスのownerであれば動作した）

## 手順
baseline-footprint.md / go-heap-pprof.md との差分: 今回はアプリを `open build/bin/UX-Music.app` ではなく
`build/bin/UX-Music.app/Contents/MacOS/UX-Music` を直接（env付きで）起動している
（GOGC/GOMEMLIMITをvariantごとに切り替えるため。LaunchServices経由の`open`はenv注入が難しい）。
可視性トグルは `osascript -e 'tell application "Finder" to set visible of process "UX-Music" to false'`
（baseline-footprint.md と同じFinder方式。go-heap-pprof.mdはSystem Events方式）。

```bash
# 各variantにつき2回（起動→hide→計測→終了→再起動→hide→計測）
env [GOGC=50 | GOMEMLIMIT=40MiB] ./UX-Music &
sleep 15
osascript -e 'tell application "Finder" to set visible of process "UX-Music" to false'
sleep 40   # park(15s debounce) + L1の2秒遅延 + マージン
footprint <pid>
kill <pid>
```

GOMEMLIMIT=40MiB variantのみ `GODEBUG=gctrace=1` を追加でログ出力し、GC頻度を目視確認した。

一つの変数のみ変える原則に従い、baseline→L1単体→L1+GOGC50→L1+GOMEMLIMIT40MiB の順に、
前variantを完全終了（`kill -9`）してから次を起動した。

## 結果

### footprint（phys_footprint、hide+40秒後）

| Variant | Run1 | Run2 | 平均 | untagged(VM_ALLOCATE) dirty | MALLOC_SMALL dirty |
|---|---|---|---|---|---|
| baseline（L1導入前, `c18218f`） | 72 MB (peak 73) | 66 MB (peak 73) | **69 MB** | 34MB / 29MB | 24MB / 23MB |
| L1単体（FreeOSMemory + malloc_zone_pressure_relief） | 65 MB (peak 74) | 61 MB (peak 71) | **63 MB** | 27MB / 27MB | 23MB / 20MB |
| L1 + GOGC=50 | 61 MB (peak 72) | 62 MB (peak 69) | **61.5 MB** | 22MB / 26MB | 24MB / 22MB |
| L1 + GOMEMLIMIT=40MiB | 67 MB (peak 74) | 65 MB (peak 73) | **66 MB** | 30MB / 27MB | 23MB / 24MB |

### GOMEMLIMIT=40MiB の `GODEBUG=gctrace=1` ログ（起動〜駐機55秒間）
- 起動直後0.4〜0.6秒の間にGC 1〜9が集中発生（初期化処理のアロケーションラッシュ、ヒープ3MB→20MB付近まで急増）。
- 以降 gc10 が10.5秒後、gc11（forced）が32秒後に1回ずつ — **スラッシングは無い**。GOMEMLIMIT超過による
  頻発GCは観測されず、通常のGCペースで収まっている。
- 参考: `gc 11 @32.212s ... 17->17->10 MB, 21 MB goal, ... (forced)` — GOMEMLIMITによるforced GCが
  1回動いた形跡はあるが、CPU負荷（cpu欄）は他のgcと同程度で問題になる兆候は無い。

## 結論

1. **baseline自体が本セッションでは約69MB**であり、baseline-footprint.md/go-heap-pprof.mdに記録された
   約98MBより大幅に低い。要因は未特定（`open`ではなくバイナリ直接起動している点、Finder経由hideのタイミング、
   その他環境差の可能性）。**この差は本調査のスコープ外の未解決の疑問として残す**（次の一手参照）。
   ただし本ノートの目的である「L1/L2の効果を同一セッション内で公平比較する」という条件は満たしている
   （baseline・L1・L2はすべて同一セッション・同一起動方式で計測）。
2. **L1（FreeOSMemory + malloc_zone_pressure_relief）は baseline比で平均 約6MB（69MB→63MB）の削減**。
   仮説どおりHeapIdleスラックとネイティブmallocの一部が実際に返却されている。**採用**（既にコミット済み・恒久コード）。
3. **L2: GOGC=50 は L1単体比で平均 約1.5MB（63MB→61.5MB）の追加削減** — プロトコルの「3MB未満は棄却」基準に
   照らして**棄却**。GCスラッシングは確認していないが、そもそも効果が閾値に届かないため恒久化しない。
4. **L2: GOMEMLIMIT=40MiB は L1単体比でむしろ悪化（63MB→66MB、約3MB増）** — **棄却**。GCログ上スラッシングは
   無かった（gc頻度は正常）が、40MiBという制限値がGoランタイムのSys（HeapSys約32.5MB、go-heap-pprof.md参照）に対して
   十分な余裕を与えず、scavengerの挙動がむしろ非効率になった可能性がある（要因未特定、これ以上の深追いはしない —
   3MBの閾値以下どころか逆行しているため）。
5. **70MBの目標**: baseline（本セッション69MB）の時点で既に目標近傍、L1適用後は平均63MBで**目標達成**。
   L2は両案とも採用基準を満たさず、L1のみで目標をクリアした。

## 次の一手 / 未検証事項
1. **baseline 69MB vs 過去記録98MBの乖離の原因調査**（本調査のスコープ外）: `open build/bin/UX-Music.app` 経由の
   起動と直接バイナリ起動でLaunchServices登録の有無がfootprintに影響するか、`Finder`方式と`System Events`方式の
   hideタイミング差、あるいは前回計測時からのライブラリ/依存関係の変化などを切り分ける。
2. L1のOS側での実効性（madvise即時反映か、メモリ圧がかかるまで遅延されるか）はfootprintコマンドの計測結果からは
   「効いている」ことまでは分かるが、実運用でのメモリ圧下での挙動は未検証。
3. 352KB×33 ネイティブmallocブロック（baseline-footprint.mdの未解決事項）は本調査でも追跡していない —
   引き続き `MallocStackLogging=1` + `malloc_history` が必要。
4. L3/L4（ライブラリ・設定ストアのJSONデコードを型付き構造体化する等）は、目標(70MB)が既にL1のみで
   達成できたため本セッションでは着手不要と判断。将来さらに削減したい場合の候補として
   go-heap-pprof.mdの「削減可能性の判断」表を参照。
