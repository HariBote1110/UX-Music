# 初回再生の破綻（MP3/FLAC問わず）の原因と対処

## 決定

「アプリ起動後、最初の再生だけがまれに音切れ／歪む（MP3・FLAC両方で確認）」という報告に対し、`pkg/audio/player.go` の再生開始経路を調査し、独立した2つの欠陥を特定・修正した。

### 欠陥A: リングバッファの事前充填を待たずに `stream.Start()` していた

`startDecodedPlayback()` は `decoderLoop()` をゴルーチンとして起動した直後、リングバッファに1サンプルも書き込まれていない状態でも構わず `stream.Start()` していた。通常はデコードがリアルタイム再生より十分速いため問題は表面化しないが、プロセス内で最初にこの経路を通るとき（初回のmp3/flacデコーダ生成、初回のディスクI/O、初回のcgo呼び出しによるページフォルト等）はデコードが遅れやすく、PortAudioの最初のコールバックが半端なバッファを読んで音が途切れる／歪むことがある。

対処として、`decoderLoop()` 起動後・`stream.Start()` 前に、リングバッファが `FramesPerBuffer`（4096フレーム）× チャンネル数分たまるまで待つポーリングループ（`waitForPrefill`）を追加した。判定ロジックは純粋関数 `prefillSatisfied(available, framesPerBuffer, channels int, decoderFinished bool) bool` として切り出し、`pkg/audio/player_prefill_test.go` でテーブル駆動テストしている。

**上限つきポーリングにした理由**: 2msごとにポーリングし、最大150ms（`startPrefillMaxWait`）で必ず打ち切って `stream.Start()` に進む。上限を設けない場合、極端に遅いディスクやデコーダのスタックが発生すると再生開始そのものがフリーズしてしまうため。150msという値は「体感で気づかれない遅延の上限」と「初回再生特有のコールドスタート遅延を吸収するのに十分な余裕」のバランスで選んだ暫定値。

**decoderFinished 分岐が必須な理由**: 1 FramesPerBuffer 分（4096フレーム×チャンネル数）に満たない極短尺のトラック（効果音的な短いファイル等）を再生すると、デコーダは即座にEOFへ到達しリングバッファの充填量が閾値に届かないまま `decoderLoop` が終了する。この場合に閾値到達だけを待つと `waitForPrefill` が150msの上限まで毎回ブロックしてしまう（そして曲によっては上限到達後も再生失敗のリスクが残る）ため、`decoderDone` チャネルのクローズ（デコーダ終了）を検知したら即座に「準備完了」とみなして待機を打ち切る。

**Play() の二重呼び出し（連打スキップ等）との整合性**: `waitForPrefill` は `decoderStop` チャネルのクローズも監視しており、`shutdownDecoderGoroutine()` が別の `Play()` 呼び出しから発行された場合は即座に待機を抜ける。`decoderStop`/`decoderDone` は `startDecodedPlayback` 内で生成されローカル変数として `decoderLoop` 起動時に渡しているため、`p.decoderStop` が後続の `Play()` によって nil 化されても待機ループ自体はデッドロックしない。

### 欠陥B: 出力デバイスのコールドスタート（CoreAudio HAL初期化コスト）

`portaudio.Initialize()` は `NewPlayer()` で一度だけ呼ばれるが、実際のPortAudioストリーム（`OpenStream`/`Start`）は**ユーザーの最初の `Play()` まで一度も開かれない**。macOSでは最初の `IOProc` 生成時にHALがDACの電源投入とフォーマット／レイテンシのネゴシエーションを行うため、初回のストリームオープンにはタイミング依存の一過性コストがかかる（Bluetooth/USBデバイスで特に顕著）。このコストが従来はユーザーの最初の再生操作にそのまま乗っていた。

対処として `Player.warmUpOutputDevice()` を追加し、`NewPlayer()` の末尾（デフォルト出力デバイス解決後）で呼び出す。48kHz/2ch・無音のストリームを開いて `Start()`、30ms実行してから `Stop()`/`Close()` する。これにより実ユーザーの初回再生より前にIOProcを暖機する。

**同期呼び出しにした理由**: 当初は `go p.warmUpOutputDevice()` として非同期実行する設計を試したが、`-race` 検出でPortAudio（cgo経由のC実装）に対する並行アクセスの競合が発覚した——ウォームアップのゴルーチンがまだPortAudio呼び出しの途中にあるうちに、テストが `Player.Close()`（内部で `portaudio.Terminate()`）を呼ぶと、PortAudioのグローバルな内部状態への同時アクセスになる。PortAudioのC実装はこの種の同時呼び出しに対して安全ではないため、`NewPlayer()` 内で同期的に呼び出す設計に変更した。追加コストは最大でも数十ms程度（`warmUpDuration = 30ms` + ストリーム開閉オーバーヘッド）で、これは起動時の一回限りの支出であり、初回再生の破綻よりはるかに許容できる。

**ベストエフォート必須の理由**: 出力デバイスが存在しない環境（CI、ヘッドレス環境等）や、48kHz/stereoを受け付けないデバイスでも `NewPlayer()` は必ず使用可能な `Player` を返さなければならない。そのため `warmUpOutputDevice()` はあらゆるエラー経路で単に `return` するのみで、エラーを一切上位へ伝播しない。加えて cgo 境界での予期せぬ panic からも `recover()` で保護している。ユニットテストでも `TestNewPlayerSucceedsRegardlessOfWarmUp`（`NewPlayer()` が引き続き成功すること）と `TestWarmUpOutputDeviceNoOutputDeviceIsNoOp`（デバイス未解決時に再生用フィールドへ触れず静かに戻ること）で担保している。実機のPortAudioデバイスが必要なテストだが、既存のテストスイートには device-dependent テストのスキップ規約が見当たらなかったため、他のテストと同様に無条件で実行する形にした（このマシン上では正常デバイスが存在し green）。

## 検討した代替案

- **欠陥Aの上限なしポーリング**: シンプルだが、スタックしたデコーダやきわめて遅いディスクI/Oで再生開始そのものが無期限にブロックされるリスクがあるため却下。
- **欠陥Bの非同期ウォームアップ（`go p.warmUpOutputDevice()`）**: 「起動をブロックしない」利点はあるが、`-race` でPortAudioのグローバル状態への同時アクセスが実際に検出された。`Close()`（や `SetDevice` の `Terminate`/`Initialize`）とレースする可能性がある設計は採用しない。

## 制約・注意点

- 以下は事前の調査で棄却済みであり、再調査不要:
  - 曲間でのサンプルレート／デバイスの使い回し — `Play()` は毎回フォーマットを再導出し新しいストリームを開くため無関係。
  - FLACのバックグラウンドインデクサ（`buildIndex()`）とデコーダのレース — インデクサは独立した `os.File` と `flac.Stream` を使うため無関係。
  - `p.channels`/`p.ringBuf`/`p.eqStates` の素朴なフィールド競合 — いずれも `p.playing` アトミックのStore/Load障壁の背後で公開されており無関係。
- `outputFramesPerBuffer`（4096）は `newPortAudioOutputStream` の `FramesPerBuffer` と `prefillSatisfied` の閾値計算の両方で共有する単一の定数にした。値がずれると事前充填の判定基準とストリームの実際のコールバックサイズが食い違う。
- バージョン更新（`src/renderer/package.json`）は別エージェントが編集中のため本タスクでは未実施。重大バグ修正のため `PhaseVer` を上げ `SubVer` をリセットするべき——`1.0.0-Beta-56x` 系から `1.0.0-Beta-57a` への更新が必要。
