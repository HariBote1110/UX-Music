// Spike: capture our own process audio via a Core Audio process tap
// (macOS 14.4+ API), verify CATapMutedWhenTapped, and re-emit the captured
// samples through PortAudio.
//
// Usage: go run ./cmd/spike-processtap
//
// Phase A taps this very process while pkg/audio's Player plays a sine WAV.
// Phase B taps a child `afplay` process instead (this mirrors the real
// architecture, where WKWebView audio is emitted by a separate WebKit helper
// process) and re-emits the tapped samples through our PortAudio stream.
package main

/*
#cgo LDFLAGS: -framework Foundation -framework CoreAudio -framework AudioToolbox
#include "tap.h"
*/
import "C"

import (
	"fmt"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	audioformat "github.com/go-audio/audio"
	wavcodec "github.com/go-audio/wav"
	"github.com/gordonklaus/portaudio"

	"ux-music-sidecar/pkg/audio"
)

const (
	wavSampleRate = 44100
	wavSeconds    = 40
	toneFrequency = 440.0
	toneAmplitude = 0.30
)

// ---- tap sample sink (shared between the Core Audio IOProc and Go) ----

type tapSink struct {
	mu           sync.Mutex
	sumSquares   float64
	sampleCount  int64
	callbacks    int64
	channels     int
	peak         float64
	ring         []float32
	ringCap      int
	reEmit       bool
	underruns    int64
	firstSeen    time.Time
	haveFirst    bool
	clippedCount int64
}

var sink = &tapSink{}

//export goTapSamples
func goTapSamples(samples *C.float, frames C.int, channels C.int) {
	n := int(frames) * int(channels)
	src := unsafe.Slice((*float32)(unsafe.Pointer(samples)), n)

	sink.mu.Lock()
	defer sink.mu.Unlock()
	if !sink.haveFirst {
		sink.haveFirst = true
		sink.firstSeen = time.Now()
	}
	sink.callbacks++
	sink.channels = int(channels)
	for _, v := range src {
		f := float64(v)
		sink.sumSquares += f * f
		if a := math.Abs(f); a > sink.peak {
			sink.peak = a
		}
	}
	sink.sampleCount += int64(n)
	if sink.reEmit {
		if len(sink.ring)+n <= sink.ringCap {
			// Clamp to avoid runaway feedback if the tap captures our own
			// re-emitted stream (expected in phase A self-tap).
			for _, v := range src {
				if v > 1.0 {
					v = 1.0
					sink.clippedCount++
				} else if v < -1.0 {
					v = -1.0
					sink.clippedCount++
				}
				sink.ring = append(sink.ring, v)
			}
		}
	}
}

func (s *tapSink) snapshotAndReset() (rms, peak float64, callbacks, samples, underruns, clipped int64, channels int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sampleCount > 0 {
		rms = math.Sqrt(s.sumSquares / float64(s.sampleCount))
	}
	peak = s.peak
	callbacks, samples = s.callbacks, s.sampleCount
	underruns, clipped, channels = s.underruns, s.clippedCount, s.channels
	s.sumSquares, s.sampleCount, s.callbacks, s.peak = 0, 0, 0, 0
	return
}

func (s *tapSink) setReEmit(enabled bool, ringCap int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reEmit = enabled
	s.ringCap = ringCap
	s.ring = s.ring[:0]
}

func (s *tapSink) readInto(out []float32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := copy(out, s.ring)
	if n < len(out) {
		for i := n; i < len(out); i++ {
			out[i] = 0
		}
		s.underruns++
	}
	s.ring = s.ring[:copy(s.ring, s.ring[n:])]
}

// ---- helpers ----

func osStatusString(status C.OSStatus) string {
	code := uint32(status)
	fourCC := []byte{byte(code >> 24), byte(code >> 16), byte(code >> 8), byte(code)}
	printable := true
	for _, b := range fourCC {
		if b < 0x20 || b > 0x7e {
			printable = false
			break
		}
	}
	if printable {
		return fmt.Sprintf("%d ('%s')", int32(status), string(fourCC))
	}
	return fmt.Sprintf("%d", int32(status))
}

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
		data = append(data, v, v) // stereo
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

type tapSession struct {
	tap        C.AudioObjectID
	aggregate  C.AudioObjectID
	sampleRate float64
	channels   int
}

func openTapForPID(pid int, uidSuffix string) (*tapSession, error) {
	var processObj C.AudioObjectID
	status := C.spikeTranslatePID(C.int(pid), &processObj)
	if status != 0 {
		return nil, fmt.Errorf("kAudioHardwarePropertyTranslatePIDToProcessObject 失敗: OSStatus=%s", osStatusString(status))
	}
	log.Printf("[tap] PID %d -> AudioObjectID %d", pid, uint32(processObj))

	s := &tapSession{sampleRate: 48000, channels: 2}
	status = C.spikeCreateTap(processObj, 1, &s.tap)
	if status != 0 {
		return nil, fmt.Errorf("AudioHardwareCreateProcessTap 失敗: OSStatus=%s", osStatusString(status))
	}
	log.Printf("[tap] タップ作成成功 (muteBehavior=CATapMutedWhenTapped): AudioObjectID=%d", uint32(s.tap))

	var sr C.double
	var ch, flags, bits, formatID C.uint
	status = C.spikeGetTapFormat(s.tap, &sr, &ch, &flags, &bits, &formatID)
	if status != 0 {
		log.Printf("[tap] kAudioTapPropertyFormat 取得失敗: OSStatus=%s（続行）", osStatusString(status))
	} else {
		isFloat := flags&0x1 != 0 // kAudioFormatFlagIsFloat
		log.Printf("[tap] タップのフォーマット: sampleRate=%.0fHz channels=%d bits=%d isFloat=%v formatID='%c%c%c%c' flags=0x%x",
			float64(sr), uint(ch), uint(bits), isFloat,
			byte(formatID>>24), byte(formatID>>16), byte(formatID>>8), byte(formatID), uint(flags))
		s.sampleRate = float64(sr)
		s.channels = int(ch)
	}

	status = C.spikeCreateAggregate(s.tap, C.CString(uidSuffix), &s.aggregate)
	if status != 0 {
		s.close()
		return nil, fmt.Errorf("AudioHardwareCreateAggregateDevice 失敗: OSStatus=%s", osStatusString(status))
	}
	log.Printf("[tap] 集約デバイス作成成功: AudioObjectID=%d", uint32(s.aggregate))

	status = C.spikeStartIO(s.aggregate)
	if status != 0 {
		s.close()
		return nil, fmt.Errorf("IOProc 登録/開始 失敗: OSStatus=%s", osStatusString(status))
	}
	log.Printf("[tap] IOProc 開始成功")
	return s, nil
}

func (s *tapSession) close() {
	if s.aggregate != 0 {
		if st := C.spikeStopIO(s.aggregate); st != 0 {
			log.Printf("[tap] IOProc 停止で OSStatus=%s", osStatusString(st))
		}
		if st := C.spikeDestroyAggregate(s.aggregate); st != 0 {
			log.Printf("[tap] 集約デバイス破棄で OSStatus=%s", osStatusString(st))
		}
		s.aggregate = 0
	}
	if s.tap != 0 {
		if st := C.spikeDestroyTap(s.tap); st != 0 {
			log.Printf("[tap] タップ破棄で OSStatus=%s", osStatusString(st))
		}
		s.tap = 0
	}
}

func logRMSFor(label string, seconds int) {
	for i := 0; i < seconds; i++ {
		time.Sleep(time.Second)
		rms, peak, cb, n, under, clipped, ch := sink.snapshotAndReset()
		log.Printf("[%s] t+%ds: RMS=%.5f peak=%.5f callbacks=%d samples=%d ch=%d underruns=%d clipped=%d",
			label, i+1, rms, peak, cb, n, ch, under, clipped)
	}
}

func startReEmitStream(sampleRate float64, channels int) (*portaudio.Stream, float64, error) {
	const framesPerBuffer = 1024
	stream, err := portaudio.OpenDefaultStream(0, channels, sampleRate, framesPerBuffer,
		func(out []float32) {
			sink.readInto(out)
		})
	if err != nil {
		return nil, 0, err
	}
	// Ring capacity of ~4 output buffers keeps latency bounded.
	ringFrames := framesPerBuffer * 4
	sink.setReEmit(true, ringFrames*channels)
	if err := stream.Start(); err != nil {
		stream.Close()
		return nil, 0, err
	}
	latencyMS := float64(ringFrames+framesPerBuffer) / sampleRate * 1000.0
	return stream, latencyMS, nil
}

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== Core Audio プロセスタップ検証スパイク ===")
	log.Printf("PID=%d / macOS プロセスタップ API（14.4+）を使用", os.Getpid())
	log.Printf("注記: TCC ダイアログ（システム音声収録）が表示された場合はその旨をログで判断すること")

	tmpDir, err := os.MkdirTemp("", "uxmusic-spike-*")
	if err != nil {
		log.Fatalf("一時ディレクトリ作成失敗: %v", err)
	}
	defer os.RemoveAll(tmpDir)
	wavPath := filepath.Join(tmpDir, "tone-440hz.wav")
	if err := buildSineWAV(wavPath); err != nil {
		log.Fatalf("テスト用 WAV 生成失敗: %v", err)
	}
	log.Printf("[準備] 440Hz 正弦波 WAV を生成: %s (%ds, %dHz, stereo)", wavPath, wavSeconds, wavSampleRate)

	// ---- Phase A: 自プロセスの音声をタップ ----
	log.Printf("---- Phase A: 自プロセス（pkg/audio Player の PortAudio 出力）をタップ ----")

	player, err := audio.NewPlayer()
	if err != nil {
		log.Fatalf("Player 初期化失敗: %v", err)
	}
	defer player.Close()

	if err := player.Play(wavPath, 1.0); err != nil {
		log.Fatalf("再生開始失敗: %v", err)
	}
	log.Printf("[A] Player で WAV 再生開始（2秒間はタップ無し＝スピーカーから 440Hz が聞こえるはず）")
	time.Sleep(2 * time.Second)

	session, err := openTapForPID(os.Getpid(), "phase-a")
	if err != nil {
		log.Printf("[A] タップ確立に失敗: %v", err)
		log.Printf("[A] 自プロセスタップは失敗。Phase B（別プロセスタップ）に進む")
	} else {
		log.Printf("[A] タップ稼働中（mutedWhenTapped が効いていればスピーカーは無音になるはず）")
		log.Printf("[A] まず 5 秒間はキャプチャのみ（再出力なし）")
		logRMSFor("A:capture-only", 5)

		log.Printf("[A] 続いて 5 秒間、タップしたサンプルを PortAudio で再出力（自プロセスなので再出力自体も再タップ＆ミュートされる想定＝帰還の有無を RMS で観察）")
		stream, latencyMS, err := startReEmitStream(session.sampleRate, session.channels)
		if err != nil {
			log.Printf("[A] 再出力ストリーム開始失敗: %v", err)
		} else {
			log.Printf("[A] 再出力開始（推定レイテンシ上限 ≈ %.0f ms）", latencyMS)
			logRMSFor("A:re-emit", 5)
			sink.setReEmit(false, 0)
			stream.Stop()
			stream.Close()
		}
		session.close()
		log.Printf("[A] タップ解除（再びスピーカーから元の音が聞こえるはず）")
		logRMSFor("A:untapped", 2)
	}

	if err := player.Stop(); err != nil {
		log.Printf("[A] Player 停止で: %v", err)
	}

	// ---- Phase B: 別プロセス（afplay）をタップして再出力 ----
	// 実際の構成（WKWebView の音声は別プロセスの WebKit ヘルパーが出す）に近い。
	log.Printf("---- Phase B: 子プロセス afplay をタップし、自プロセスの PortAudio から再出力 ----")

	cmd := exec.Command("/usr/bin/afplay", wavPath)
	if err := cmd.Start(); err != nil {
		log.Fatalf("[B] afplay 起動失敗: %v", err)
	}
	log.Printf("[B] afplay 起動 (PID=%d)。1秒待ってからタップ", cmd.Process.Pid)
	time.Sleep(1 * time.Second)

	sessionB, err := openTapForPID(cmd.Process.Pid, "phase-b")
	if err != nil {
		log.Printf("[B] タップ確立に失敗: %v", err)
	} else {
		log.Printf("[B] タップ稼働中。afplay の直接出力はミュートされ、以降はタップ→PortAudio 経由の音だけが聞こえるはず")
		streamB, latencyMS, err := startReEmitStream(sessionB.sampleRate, sessionB.channels)
		if err != nil {
			log.Printf("[B] 再出力ストリーム開始失敗: %v", err)
			logRMSFor("B:capture-only", 5)
		} else {
			log.Printf("[B] 再出力開始（推定レイテンシ上限 ≈ %.0f ms）", latencyMS)
			logRMSFor("B:re-emit", 8)
			sink.setReEmit(false, 0)
			streamB.Stop()
			streamB.Close()
		}
		sessionB.close()
	}

	cmd.Process.Kill()
	cmd.Wait()
	log.Printf("=== 検証終了 ===")
}
