# relayEngine の再入可能性バグと GitHub Actions 固有の中継テスト失敗

## 目的 / 仮説

`server/app_remote_relay_test.go` の
`TestRemoteRelayEngine_MultipleConcurrentClientsBothReceiveBytes` が、GitHub
Actions の `ubuntu-latest` ランナー上でのみ「2クライアントとも0バイト」で
再現性よく失敗し、`GITHUB_ACTIONS` 環境変数によるスキップで握りつぶされて
いた。同じ Linux（linux/amd64、Docker、`-race`、CPU 制限あり/なし、
`count=20`）ではローカルで一度も再現しなかった。単一クライアント版
（`TestRemoteRelayEngine_SingleClientReceivesADTSBytes`）は同じ CI で安定
して通っていたため、ffmpeg パイプライン自体は機能しているはずで、「2クラ
イアント同時購読」または「CI 環境固有の何か」に絞られていた。

出発仮説（コード分析による事前提示、本調査で検証）:

> `relayEngine.Start()` が spawn する「`cmd.Wait()` の完了を待って
> `e.Stop()` する」ゴルーチンは、自分がどのセッションに属するかを区別
> できていない。`Stop()` もその等ゴルーチンの完了を待たない。直前の
> テストの ffmpeg プロセスの終了・パイプ EOF が CI の混雑したランナー
> で遅延し、次のテストの `Start()` より後に完了すると、古いセッション
> の `Stop()` が新しいセッションの購読者を巻き込んで破棄してしまう
> （generation なしの非同期 Stop() レース）。

反証条件: 対象テストを `-run` で単独・繰り返し実行して CI 上でも失敗する
なら、クロステスト干渉ではなくテスト単体の問題。

## 環境

- リポジトリ: `HariBote1110/UX-Music`、調査ブランチ `relay-ci-diagnosis`
  （起点 `origin/main`）
- CI: GitHub Actions、`test.yml` の `go test (linux)` ジョブ、
  `runs-on: ubuntu-latest`
  - Go: 1.25.5（`/opt/hostedtoolcache/go/1.25.5/x64`、CI ログのスタック
    トレースパスより）
  - ffmpeg: `ffmpeg version 6.1.1-3ubuntu5`（apt でインストール、CI ログの
    `-version` 出力より）
  - 対象パッケージ: `ux-music-sidecar/server`
  - CI は同一パッケージ集合に対して `go test -race` と
    `go test -shuffle=on` の2ステップを実行する
- ローカル比較環境: macOS（darwin/arm64）、ffmpeg 8.0.1（Homebrew）、
  Go はローカル `go.mod` 指定バージョン

## 手順

1. `server/app_remote_relay_test.go:220` の `GITHUB_ACTIONS` スキップを
   一時的に外す。
2. `server/app_remote_relay.go` の `relayEngine` に診断フック
   `debugf func(format string, args ...interface{})`（テストのみ
   `t.Logf` を注入、本番は nil）を追加し、以下を計測できるようにする:
   - ffmpeg の解決パスと `cmd.Start()` の成否
   - ffmpeg stderr の全行（従来 `cmd.Stderr` は未設定＝`os.DevNull` に
     破棄されており、誰も見ていなかった）
   - `pumpPCM` が書き込んだ PCM バイト数の累計
   - `pumpADTS` が読み取った ADTS バイト数の累計・最初のチャンク到着
   - `broadcast` 呼び出しごとの購読者数・送信数・`default:` での drop 数
   - `Subscribe` 呼び出しのタイミング
3. `relay-ci-diagnosis` ブランチに push し、
   `gh run list --branch relay-ci-diagnosis` / `gh run view <id> --log`
   で実際の CI 出力を確認。
4. 1回目の push で `-race` ステップがデータレースを検出して FAIL。
   その内容から核心的な手がかりを得た（下記結果参照）。
5. `relayEngine` に世代カウンタ（`generation`）を導入し、
   `cmd.Wait()` 完了時の teardown を `stopIfCurrent(gen)` 経由にして
   「自分の世代が現行世代と一致する場合のみ」実行するよう修正
   （`server/app_remote_relay.go`）。
6. 診断フック用に `debugMu sync.RWMutex` を追加し、`e.mu` を握ったまま
   `logf` を呼ぶ既存コード（`broadcast`・`Subscribe`）とのデッドロックを
   避けつつフィールドアクセスを race-safe にした。
7. 世代ガードの単体テスト `TestRelayEngine_StaleGenerationStopIsNoOp` を
   `server/app_remote_relay_test.go` に追加（実プロセスに依存しない
   ホワイトボックステスト。`stopIfCurrent` を直接呼び、古い世代の呼び出し
   が現行セッションを破棄しないことを検証）。
8. 一時的な CI ステップ
   `go test -race -count=5 -run '^TestRemoteRelayEngine_MultipleConcurrentClientsBothReceiveBytes$' ./server/`
   を `test.yml` に追加し、クロステスト干渉かどうかの切り分けを高速化。
9. push → CI 確認を計3回実施（うち1回は `gh workflow run` による手動
   再実行）。3回とも `go test (linux)` ジョブ（`-race` / `-shuffle=on` /
   一時的な単独5回実行）が全てグリーン。
10. 診断用の一時的な計測コード（`debugf`／`pumpStderr`／各種
    `logf` 呼び出し）と一時 CI ステップを削除し、世代カウンタ本体の
    修正のみを残す形に整理。整理後も `go build`・`go vet`・ローカル
    `-race` テストがグリーンであることを確認。

## 結果

### 1回目の push（診断計測のみ、修正前）で判明したこと

`go test -race` ステップが、狙っていた「0バイト」ではなく **データレース
検出**で FAIL した:

```
WARNING: DATA RACE
Write at 0x000001b2cb90 by goroutine 220:
  ux-music-sidecar/server.TestRemoteRelayEngine_MultipleConcurrentClientsBothReceiveBytes()
      .../app_remote_relay_test.go:226   (remoteRelay.debugf = t.Logf)

Previous read at 0x000001b2cb90 by goroutine 208:
  ux-music-sidecar/server.(*relayEngine).logf()
      .../app_remote_relay.go:79
  ux-music-sidecar/server.(*relayEngine).pumpStderr()
      .../app_remote_relay.go:185
  ux-music-sidecar/server.(*relayEngine).Start.gowrap1()
      .../app_remote_relay.go:165

Goroutine 208 (finished) created at:
  ux-music-sidecar/server.(*relayEngine).Start()
      .../app_remote_relay.go:165
  ux-music-sidecar/server.TestRemoteRelayEngine_SingleClientReceivesADTSBytes()
      .../app_remote_relay_test.go:150
```

これは **直前の `TestRemoteRelayEngine_SingleClientReceivesADTSBytes` が
起動した ffmpeg セッションの stderr 読み取りゴルーチンが、次のテスト
（Multi client）の `Start()` 呼び出し後もまだ生きていた**ことを示す直接
証拠である。`t.Cleanup(remoteRelay.Stop)` は `cancel()` を呼ぶだけで、
その後にプロセスが実際に終了し、パイプが EOF になり、ゴルーチンが
`return` するまでは待たない。CI の共有ランナーではこの「後片付けの尻尾」
が数ミリ秒〜十数ミリ秒残ることがあり、次のテストの初期化と時間的に
重なりうる。

これは事前提示された仮説（generation なしの非同期 `Stop()` レース）が
主張する機構——「古いセッションのゴルーチンが新しいセッションの状態を
いじる」——を、レースディテクタが客観的に裏付けた形になる。ただし今回
実際にレースを起こしたのは元コードのフィールドではなく、調査のために
新規追加した `debugf` フィールドだった点には注意（下記「棄却した/確定
しなかった点」参照）。

### 2回目の push（世代カウンタ導入後）

同じ CI ジョブ（Go 1.25.5 / ffmpeg 6.1.1-3ubuntu5 / ubuntu-latest）で:

| ステップ | 結果 |
|---|---|
| `go test (-race)`（全パッケージ） | PASS（`ux-music-sidecar/server ok 3.711s`） |
| `go test (-shuffle=on)`（全パッケージ） | PASS（`ux-music-sidecar/server ok 2.864s`） |
| `[TEMP] go test relay isolation (-race, -count=5)` | PASS × 5回連続 |

### 3回目・4回目（`gh workflow run` による手動再実行 × 2）

いずれも `go test (linux)` ジョブは全ステップ PASS。合計で
「`go test (linux)` ジョブがグリーン」を3回連続で観測。

（参考: 同じ実行で `swift test (lyrics-sync CLI)` が
`package 'lyrics-sync' is using Swift tools version 6.0.0 but the
installed version is 5.10.0` で毎回落ちているが、これは `main` ブランチ
でも既知の別件インフラ問題であり、本調査とは無関係。`gh run list
--branch main` で直近5回のワークフロー実行が同じ理由で failure に
なっていることを確認済み。）

## 結論

- **仮説は採択**: `relayEngine` には Start/Stop の再入可能性バグが実在
  した。`Start()` の末尾が spawn する「`cmd.Wait()` を待って `e.Stop()`
  する」ゴルーチンは、自分がどのセッションに属するかを区別しておらず、
  `Stop()` 側もそれらのゴルーチンの完了を待たない。ffmpeg プロセスの
  終了・パイプ EOF のタイミングが実行環境（特に CI の混雑した共有
  ランナー）に依存するため、古いセッションの後片付けが新しいセッション
  の開始後にずれ込むことがあり、その場合は新しいセッションの購読者が
  巻き込まれて破棄されうる。
- 修正: `relayEngine` に `generation int` を追加。`Start()` は自分の
  世代番号 `gen` を記録し、`cmd.Wait()` ゴルーチンは
  `stopIfCurrent(gen)` を呼ぶ。これは `gen` が現行世代と一致する場合に
  のみ実際の `Stop()` を実行する。明示的な `Stop()` 呼び出し
  （テストの `t.Cleanup`、`Start()` 冒頭の呼び出し、実運用での曲切り替え
  時の再起動）は常に世代をインクリメントするため、古い世代からの遅延
  `stopIfCurrent` は確実に no-op になる。
- これは**テストだけの問題ではなく本番コードのバグ**でもある:
  `NotifyYouTubePlaybackState` は曲が変わるたびに `remoteRelay.Start()`
  を呼び直す（`Start()` 冒頭で前のセッションを `Stop()` する設計）。
  ユーザーが素早く曲を切り替えた場合、切り替え前の ffmpeg の
  `cmd.Wait()` が新しいセッション開始後に完了すると、生きている LAN
  中継が無音で落ちる可能性があった。今回の修正はテストの CI 固有失敗と
  同時にこの本番経路のバグも塞ぐ。
- `GITHUB_ACTIONS` によるスキップは解除した
  （`server/app_remote_relay_test.go`）。CI で3回連続グリーンを確認
  済み。

### 棄却した仮説 / 確定しなかった点

- **バッファエイリアシング（fan-out での使い回し）**: 事前調査で棄却
  済み（`pumpADTS` はチャンクごとに新しい `[]byte` を allocate してから
  `copy` しており、購読者間で共有していない）。本調査でも
  `broadcast`/`pumpADTS` のロジックを再確認したが、この仮説を再検証
  する新たな証拠は無く、棄却のまま。
- **Subscribe/HTTP ハンドシェイクの遅延そのもの**: 既存コメント
  （テスト冒頭）が示す「生配信ウィンドウ 300ms 版では購読が間に合わない」
  問題は、生配信ウィンドウを5秒に広げる対応で別途解消済みとされており、
  本調査で新たに反証・追認する材料は得られなかった（＝今回の主因では
  ないという既存の判断を維持）。
- **`-shuffle=on` 固有の順序依存バグ**: 修正前の状態で
  `-shuffle=on` ステップ単体が独立に失敗するかどうかは、1回目の push が
  `-race` ステップで先に FAIL したため（`concurrency` 設定と
  ステップの直列実行により、`-race` が落ちた時点でジョブ全体が
  `##[error]Process completed with exit code 1` となり後続ステップは
  スキップされずそのまま実行されるが、今回はログ上 `-shuffle=on` 自体は
  評価されなかった）、**未検証**。ただし修正後は `-race` /
  `-shuffle=on` とも3回連続グリーンであり、実用上は解消したと判断した。
  「`-shuffle=on` だけが失敗するのか `-race` だけなのか」という当初の
  切り分け観点については、**今回確認できたのは `-race` ステップで
  データレースとして症状が可視化されたという事実のみ**であり、
  `-shuffle=on` 単体が独立に「0バイト」症状を起こすかどうかは未確定の
  まま残る（世代カウンタ修正でどちらのステップも通るようになったため、
  これ以上の切り分けは行っていない）。
- **ffmpeg のバージョン差（CI: 6.1.1-3ubuntu5 / ローカル: 8.0.1）が
  原因**という仮説は、今回は積極的に検証していない。ただし
  `TestRemoteRelayEngine_SingleClientReceivesADTSBytes` は同じ CI 環境
  （同じ ffmpeg 6.1.1-3ubuntu5）で一貫して成功しており、ffmpeg
  バージョン差そのものが単独の原因ではないと考えられる（再入可能性
  バグの発現しやすさに間接的に影響していた可能性は否定できないが、
  検証はしていない）。

## 次の一手 / 未検証事項

- 今回の3回の CI グリーンは「修正が有効であることの強い状況証拠」では
  あるが、元の失敗自体が確率的（レースコンディション）だったため、
  「絶対に再発しない」ことの証明にはならない。継続的に CI で監視し、
  再発した場合はこのノートを更新すること。
- `-shuffle=on` ステップ単体が独立に問題を起こすかどうかの切り分けは
  未完了（上記参照）。もし将来別の理由でこのテストが再び不安定になった
  場合、`-race` と `-shuffle=on` を分けて調べる価値がある。
- 診断のために追加した `debugf` フック・`pumpStderr`・各種バイト数計測は
  **すべて削除した**（下記「計測コードの扱い」参照）。同種の調査が必要に
  なった場合は、本ノートの「手順」を参照して同じ仕組みを再構築できる。

## 計測コードの扱い

診断用に追加した以下のコードは、調査完了後に**すべて削除**した（本番の
中継ホットパスに常駐させる判断はしなかった）:

- `relayEngine.debugf` / `debugMu` / `logf` / `setDebugf`
- `relayEngine.pumpStderr`（ffmpeg stderr のパイプ取得・行ごとの中継）
- `pumpPCM` / `pumpADTS` / `broadcast` 内のバイト数・購読者数ログ
- `test.yml` の一時ステップ `[TEMP] go test relay isolation`

理由: これらは `broadcast` のような 1 チャンクごとに呼ばれるホット
パス上で毎回ロック＋関数呼び出しを行うものであり、本番で常時有効化する
価値（＝実運用でこのクラスの再入可能性バグが再発したときの診断材料）
より、恒常的なオーバーヘッドと「調査用コードが本番に残り続ける」こと
自体のリスクの方が大きいと判断した。実際に効いた恒久的な修正は
`relayEngine.generation` / `stopIfCurrent` の世代ガードのみであり、
これは通常運用時のコストがロック内でのフィールド比較1回程度に収まる。

回帰防止テストとして `TestRelayEngine_StaleGenerationStopIsNoOp`
（`server/app_remote_relay_test.go`）を残した。これは実 ffmpeg プロセス
を起動せず `stopIfCurrent` を直接駆動するホワイトボックステストであり、
今後 `relayEngine` のライフサイクルを変更する際の安全網になる。
