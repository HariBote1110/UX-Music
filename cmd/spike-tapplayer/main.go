// 実機検証: pkg/audio のプロセスタップ捕捉モジュールと Player のライブタップ
// 再生モードを、子プロセス afplay を対象に検証する。
//
// 使い方: go run ./cmd/spike-tapplayer
//
// 発音スケジュール（聴感確認用）:
//   - 0〜約5秒   Phase 1: 無音。afplay を PID タップして捕捉のみ行う（afplay は
//     CATapMutedWhenTapped でミュート、再出力なし）。捕捉サンプルのゼロクロス
//     周波数と RMS を実出力レートで自動判定する。レート誤解釈（例: 192kHz 供給を
//     48kHz と解釈すると 440Hz が 110Hz のウーファー的低音になる）はここで検出。
//   - 約5〜11秒  Phase 2: Player 出力から 440Hz（原音と同じ高さ）が聞こえる。
//     新しい afplay を Player.PlayProcessTap で再生（EQ 有効）。音源はミュート
//     済みなので二重には鳴らない。FFT の 440Hz ビンと背景ビンの対比で自動判定。
//   - 約11〜14秒 Phase 3: タップ停止後、通常のファイル再生（440Hz WAV）が鳴る。
//     位置が前進することで自動判定。
//
// いずれかの自動判定に失敗すると非ゼロ終了する（聴感に依存しない合否）。
package main

import (
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	audioformat "github.com/go-audio/audio"
	wavcodec "github.com/go-audio/wav"

	"ux-music-sidecar/pkg/audio"
)

const (
	wavSampleRate = 44100
	wavSeconds    = 40
	toneFrequency = 440.0
	toneAmplitude = 0.30
)

func buildSineWAV(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := wavcodec.NewEncoder(f, wavSampleRate, 16, 2, 1)
	total := wavSampleRate * wavSeconds
	data := make([]int, 0, total*2)
	for i := 0; i < total; i++ {
		v := int(toneAmplitude * 32767.0 * math.Sin(2.0*math.Pi*toneFrequency*float64(i)/wavSampleRate))
		data = append(data, v, v)
	}
	buf := &audioformat.IntBuffer{
		Data:           data,
		Format:         &audioformat.Format{NumChannels: 2, SampleRate: wavSampleRate},
		SourceBitDepth: 16,
	}
	if err := enc.Write(buf); err != nil {
		return err
	}
	return enc.Close()
}

// analyseMono computes the RMS and the positive-going zero-cross frequency of
// channel 0 in interleaved samples.
func analyseMono(samples []float32, channels, sampleRate int) (rms, frequency float64) {
	if channels <= 0 || len(samples) < channels*2 {
		return 0, 0
	}
	frames := len(samples) / channels
	var sumSquares float64
	crossings := 0
	prev := samples[0]
	for i := 1; i < frames; i++ {
		v := samples[i*channels]
		sumSquares += float64(v) * float64(v)
		if prev <= 0 && v > 0 {
			crossings++
		}
		prev = v
	}
	rms = math.Sqrt(sumSquares / float64(frames-1))
	durationSec := float64(frames) / float64(sampleRate)
	if durationSec > 0 {
		frequency = float64(crossings) / durationSec
	}
	return rms, frequency
}

func startAfplay(wavPath string) *exec.Cmd {
	cmd := exec.Command("/usr/bin/afplay", wavPath)
	if err := cmd.Start(); err != nil {
		log.Fatalf("afplay 起動失敗: %v", err)
	}
	return cmd
}

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== プロセスタップ捕捉モジュール + Player ライブ再生 実機検証 ===")
	log.Printf("発音スケジュール: Phase 1 (〜約5秒) = 無音 / Phase 2 (約5〜11秒) = Player 出力の 440Hz / Phase 3 (約11〜14秒) = 通常再生の 440Hz")
	log.Printf("bundle-ID タップ API (macOS 26+) サポート: %v", audio.ProcessTapBundleAPISupported())

	tmpDir, err := os.MkdirTemp("", "uxmusic-tapplayer-*")
	if err != nil {
		log.Fatalf("一時ディレクトリ作成失敗: %v", err)
	}
	defer os.RemoveAll(tmpDir)
	wavPath := filepath.Join(tmpDir, "tone-440hz.wav")
	if err := buildSineWAV(wavPath); err != nil {
		log.Fatalf("テスト用 WAV 生成失敗: %v", err)
	}
	log.Printf("[準備] 440Hz 正弦波 WAV を生成 (%ds, %dHz, stereo)", wavSeconds, wavSampleRate)

	// ---- Phase 1: 捕捉モジュール単体（無音のはず） ----
	log.Printf("---- Phase 1: afplay を PID タップして捕捉のみ（スピーカーは無音のはず） ----")
	afplay1 := startAfplay(wavPath)
	time.Sleep(1 * time.Second)

	capture, err := audio.StartProcessTap(audio.ProcessTapTargets{PIDs: []int{afplay1.Process.Pid}})
	if err != nil {
		log.Fatalf("[1] StartProcessTap 失敗: %v", err)
	}
	log.Printf("[1] タップ開始: %dHz/%dch", capture.SampleRate(), capture.Channels())
	// Phase 2 の FFT 周波数換算にも使う（同一出力デバイスなので同レート）。
	tapRate := capture.SampleRate()

	phase1Pass := false
	buf := make([]float32, capture.SampleRate()*capture.Channels()) // 1秒分
	for i := 0; i < 3; i++ {
		time.Sleep(time.Second)
		n := capture.ReadSamples(buf)
		rms, freq := analyseMono(buf[:n], capture.Channels(), capture.SampleRate())
		log.Printf("[1] t+%ds: samples=%d RMS=%.5f zeroCrossFreq=%.1fHz (期待 ~440Hz) received=%d dropped=%d",
			i+1, n, rms, freq, capture.ReceivedSamples(), capture.DroppedSamples())
		// 自動判定: 実出力レートで解釈したゼロクロス周波数が 440Hz に一致し、
		// RMS が理論値 (0.3/√2 ≈ 0.212) 付近であること。レート誤解釈があれば
		// 周波数がオクターブ単位でずれるためここで検出できる。
		if math.Abs(freq-toneFrequency) < 25 && rms > 0.15 && rms < 0.30 {
			phase1Pass = true
		}
	}
	if !phase1Pass {
		log.Fatalf("[1] 不合格: 捕捉サンプルの周波数/RMS が期待値と一致しない（レート誤解釈またはバッファ不連続の疑い）")
	}
	log.Printf("[1] 合格: %dHz 解釈のゼロクロスが 440Hz・RMS が理論値と一致", capture.SampleRate())
	if err := capture.Stop(); err != nil {
		log.Printf("[1] Stop で: %v", err)
	}
	afplay1.Process.Kill()
	afplay1.Wait()
	log.Printf("[1] 捕捉停止")

	// ---- Phase 2: Player 統合（EQ 有効、Player 経由で 440Hz が鳴るはず） ----
	log.Printf("---- Phase 2: PlayProcessTap（EQ 有効）。Player 出力から 440Hz が聞こえるはず ----")
	player, err := audio.NewPlayer()
	if err != nil {
		log.Fatalf("Player 初期化失敗: %v", err)
	}
	defer player.Close()
	player.SetEqualizer(true, 0, []float64{3, 2, 1, 0, 0, 0, 0, 0, 0, 0})
	log.Printf("[2] EQ 有効化（低域ブースト）")

	afplay2 := startAfplay(wavPath)
	time.Sleep(1 * time.Second)

	if err := player.PlayProcessTap(audio.ProcessTapTargets{PIDs: []int{afplay2.Process.Pid}}, 1.0); err != nil {
		log.Fatalf("[2] PlayProcessTap 失敗: %v", err)
	}

	// FFT で 440Hz 付近のビンにエネルギーが集中していることを確認する。
	// （強度は -30dB で飽和して 255 に張り付くため、ピーク探索ではなく
	// 期待ビンと背景ビンの対比で判定する）
	const fftSize = 2048
	expectedBin := int(math.Round(toneFrequency * fftSize / float64(tapRate)))
	backgroundBin := expectedBin * 20
	phase2Pass := false
	for i := 0; i < 5; i++ {
		time.Sleep(time.Second)
		freqData := player.GetFrequencyData()
		var signal, background uint8
		if expectedBin < len(freqData) {
			signal = freqData[expectedBin]
		}
		if backgroundBin < len(freqData) {
			background = freqData[backgroundBin]
		}
		log.Printf("[2] t+%ds: playing=%v position=%.1f duration=%.1f FFT[440Hz bin %d]=%d FFT[背景 bin %d]=%d (信号≫背景なら合格)",
			i+1, player.IsPlaying(), player.GetPosition(), player.GetDuration(), expectedBin, signal, backgroundBin, background)
		if player.IsPlaying() && player.GetPosition() == 0 && player.GetDuration() == 0 &&
			int(signal) >= int(background)+80 {
			phase2Pass = true
		}
	}
	if !phase2Pass {
		log.Fatalf("[2] 不合格: タップ音声が 440Hz として再生パイプラインに流れていない")
	}
	log.Printf("[2] 合格: タップ→リング→EQ→FFT の経路に 440Hz の信号が流れ、position/duration は無効化されている")

	// ---- Phase 3: Stop 後の通常ファイル再生復帰 ----
	log.Printf("---- Phase 3: タップ停止 → 通常の WAV 再生が数秒鳴るはず ----")
	if err := player.Stop(); err != nil {
		log.Fatalf("[3] Stop 失敗: %v", err)
	}
	afplay2.Process.Kill()
	afplay2.Wait()

	if err := player.Play(wavPath, 1.0); err != nil {
		log.Fatalf("[3] 通常再生への復帰失敗: %v", err)
	}
	for i := 0; i < 3; i++ {
		time.Sleep(time.Second)
		log.Printf("[3] t+%ds: playing=%v position=%.2fs duration=%.1fs",
			i+1, player.IsPlaying(), player.GetPosition(), player.GetDuration())
	}
	if pos := player.GetPosition(); pos <= 0 {
		log.Fatalf("[3] 不合格: 通常再生の位置が進んでいない: %.2fs", pos)
	}
	log.Printf("[3] 合格: タップ停止後の通常ファイル再生で位置が前進")
	player.Stop()
	log.Printf("=== 検証終了: 全フェーズ合格（タップ捕捉→EQ→出力、通常再生復帰） ===")
}
