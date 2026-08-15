# 公式再生（embed）のラウドネス: 二重減衰の解消と実測補正

## Decision

embed 再生がローカル曲より小さく鳴る問題（実測 1〜4.4 dB）に対し、2 段構えで対処した。

1. **推定ゲインの是正**（`src/renderer/js/features/playback-gain.ts`）
   `resolveEmbedPlaybackGain` の基準を `effectiveLoudness` から
   `min(effectiveLoudness, -14)` に変更。埋め込みプレイヤー自身が
   `<video>.volume` を下げる形で自前の正規化減衰を掛けている（＝ -14 LUFS 付近まで
   下げた音がタップへ届く）ことをブラウザ実測で確認したため。減衰は片方向で、
   ターゲットより静かなコンテンツはブーストされない ＝ `min` が実態と一致する。

2. **タップ音声の実測ラウドネス補正**（`pkg/audio/loudness_meter.go`,
   `pkg/audio/player_live_loudness.go`, `server/app_live_loudness.go`）
   ITU-R BS.1770 の積分ラウドネスをタップ音声（EQ・ゲイン適用前）に対して実測し、
   `補正 dB = (目標 − 実測) − 既に掛けた推定ゲイン` を `baseGain` に乗算する。
   500 ms ごとに再計算、0.4 秒の一次遅れランプで滑らかに移行、補正量は ±12 dB で
   クランプ。測定が 1.5 秒に満たないうちは補正しない。

再生開始直後は 1 の推定値で鳴り、数秒後に 2 が実測へ寄せる。YouTube 側の
ターゲット変更や DRC 適用（実測で tgt -19.0 を観測）にも追随する。

調査の詳細と実測データは
[youtube_loudness_research/notes/embed-double-normalisation.md](../youtube_loudness_research/notes/embed-double-normalisation.md)。

## Alternatives considered

- **ホストページから実減衰を読む（当初の案 B）**: 却下。`YT.Player` の実体は
  youtube.com のクロスオリジン iframe で、`<video>.volume` も
  `getStatsForNerds()` も読めない。IFrame API が公開する `apiInterface`（実測で
  64 メソッド）に実減衰を返すものは存在せず、`getVolume()` は減衰前の 100 を返す。
- **`min(cont, -14)` の近似だけで済ませる（案 A）**: 却下。DRC 適用時に
  YouTube 側ターゲットが -19 になるケースを実測しており、最大 5 dB の誤差が残る。
- **実測だけで決める（推定ゲインなし）**: 却下。収束までの数秒が素の音量になる。

## Constraints / Gotchas

- **測定点は「タップ音声そのもの」**。`processAudio` でリングバッファから読んだ
  生サンプルをメーターへ流す。EQ 後やゲイン後を測ると補正がフィードバックループに
  なる。この順序は崩さないこと。
- **`processAudio` はリアルタイムスレッド**。メーターの `processSample` はロックも
  アロケーションもしない。完成した 100 ms サブブロックのみ事前確保済みリングへ
  atomic 書き込みし、ゲート処理は別スレッドで行う。
- **推定ゲイン → 補正開始の順序が重要**。補正係数は `baseGain` との差分として
  決まるため、`AudioSetNormalisationGain` の後に
  `AudioStartLiveLoudnessCorrection` を呼ぶ。逆順だと 1 周期ぶん誤った補正が乗る。
- **E2E harness（`youtube-embed-e2e.ts`）は補正を起動しない**。補正は時間とともに
  ゲインを動かすため、`runVolumeCheck` の出力 RMS が測定タイミング依存になる。
  推定ゲインのみを決定的に検証する意図的な差異。
- **広告が挟まると測定が汚れる**。積分ラウドネスは曲頭からの累積なので、冒頭に
  広告が入るとその音量も混ざる。実害が出るようなら「曲の PLAYING 開始時点で
  メーターをリセットする」導線が必要。
- **ゲートの性質上、無音は除外されるが境界ブロックは残る**。無音→信号の境界に
  またがる 400 ms ブロックは BS.1770 の定義どおりゲートを通るため、短い測定では
  0.3 dB 程度の誤差が出る（テストのトレランスもこれを見込んでいる）。
- **実機での聴感確認は未実施**。プロセスタップにはシステム音声録音の許可が要り、
  自動では検証できない。ビルド（`wails build`）と全テストが通ることまでを確認済み。
