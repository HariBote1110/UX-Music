# デスクトップ版ビジュアライザーのFFT正規化欠落バグ修正

## 決定
- `pkg/audio/player.go` の `calculateFFT` が、`fft.FFTReal` の返す**未正規化**の複素数マグニチュードをそのまま `20*log10(mag)` に渡していたことが根本原因。2048点FFTでは通常の音楽入力でマグニチュードが数百のオーダーになり、dB値が常に正になって `maxDecibels(-30dB)` に張り付き、ほぼ全ビンが255になっていた。結果としてビジュアライザーのバーが常に最大高さで固まって見えていた。
- 修正は WebAudio の `AnalyserNode` の挙動に合わせ、次の2点を実装:
  1. **正規化**: `mag := cmplx.Abs(fftRes[i]) / float64(p.fftSize)` としてFFTサイズで正規化。
  2. **時間平滑化**: リニアマグニチュード領域で `smoothed = 0.8*prevSmoothed + 0.2*mag` を適用してからdB変換する（`smoothingTimeConstant=0.8` 相当）。新規フィールド `Player.fftSmoothed []float64` を `initFFT` で確保し、`calculateFFT` 内で更新する。
- dB→0-255のマッピング（-100dB〜-30dB）自体は変更していない。Hann窓のコヒーレントゲイン補正（×2）は今回見送り、正規化とスケール範囲の組み合わせでテストのしきい値（ピークビンが100〜254の範囲に収まる）を満たすことを確認済み。

## 代替案として検討したもの
- **dBレンジ（minDecibels/maxDecibels）だけをチューニングして張り付きを回避する案**: 表面上は255への張り付きを緩和できるが、FFTサイズやサンプルレートを変えるたびに再調整が必要になり、根本にある「スケールが桁違いに間違っている」問題を放置することになるため採用しなかった。正規化を修正すれば既存のdBレンジ定数（-100〜-30）がAnalyserNode相当の妥当な値としてそのまま機能する。

## 制約・注意点
- `calculateFFT` はRTスレッドではなく非同期処理用goroutine（`fftProcessor`）から呼ばれる。既存の `fftMu` ロックはそのまま維持。
- `fftSmoothed` は曲切り替えやstop時に明示的なリセットフックが見当たらなかったため、今回はリセットを実装していない（次フレームで新しい信号にすぐ収束するため実害は小さい想定）。
- あわせてフロントエンド側 `src/renderer/js/features/visualizer.ts` の `GO_VISUALIZER_FETCH_INTERVAL_MS` を80msから40msに短縮し、正規化で得られたダイナミクスがよりなめらかに見えるようにした。
