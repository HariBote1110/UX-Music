package audio

// ライブ捕捉（プロセスタップ）音声の実測ラウドネス補正。
//
// 公式再生（embed）では、YouTube のプレイヤー自身が正規化減衰を掛けた後の音が
// タップへ届く。その減衰量はクロスオリジンの iframe 越しには取得できないため、
// フロントエンドが innertube のコンテンツラウドネスから求める推定ゲインだけでは
// 二重減衰になり、ローカル曲より小さく鳴る。
//
// ここではタップ音声そのものを BS.1770 で実測し、推定ゲインとの差を補正係数として
// 掛け直す。補正はランプで滑らかに適用するため、聴感上の段差にならない。

import (
	"math"
	"time"
)

const (
	// 補正値を再計算する間隔。積分ラウドネスは曲頭から累積するので、
	// 回数を重ねるほど値は安定する。
	liveCorrectionUpdateInterval = 500 * time.Millisecond
	// これだけの音声を測るまでは補正しない（冒頭の無音や無音に近い導入で
	// 過大な補正が決まるのを防ぐ）。
	liveCorrectionMinSeconds = 1.5
	// 補正値の変更にかける時間（秒）。段差ではなくランプで移行させる。
	liveCorrectionRampSeconds = 0.4
)

// gainFromBits は atomic に格納された線形ゲインを読む。ゼロ値（未設定）は
// 補正なしの 1.0 とみなす。
func gainFromBits(bits uint64) float64 {
	value := math.Float64frombits(bits)
	if value <= 0 || math.IsNaN(value) || math.IsInf(value, 0) {
		return 1.0
	}
	return value
}

func (p *Player) liveCorrectionTargetGain() float64 {
	return gainFromBits(p.liveCorrectionTarget.Load())
}

func (p *Player) liveCorrectionCurrentGain() float64 {
	return gainFromBits(p.liveCorrectionCurrent.Load())
}

func (p *Player) setLiveCorrectionTargetGain(gain float64) {
	p.liveCorrectionTarget.Store(math.Float64bits(gain))
}

func (p *Player) setLiveCorrectionCurrentGain(gain float64) {
	p.liveCorrectionCurrent.Store(math.Float64bits(gain))
}

// LiveLoudnessCorrectionGain は現在適用中の補正係数（線形）を返す。診断用。
func (p *Player) LiveLoudnessCorrectionGain() float64 {
	return p.liveCorrectionCurrentGain()
}

// StartLiveLoudnessCorrection はライブ捕捉音声の実測ラウドネス補正を開始する。
// targetLUFS はローカル曲と同じ目標ラウドネス。既に動いていれば作り直す。
func (p *Player) StartLiveLoudnessCorrection(targetLUFS float64) {
	if math.IsNaN(targetLUFS) || math.IsInf(targetLUFS, 0) {
		return
	}

	p.mu.RLock()
	sampleRate := p.sampleRate
	channels := p.channels
	p.mu.RUnlock()
	if sampleRate <= 0 {
		sampleRate = 48000
	}
	if channels <= 0 {
		channels = 2
	}

	p.StopLiveLoudnessCorrection()

	p.liveCorrectionTargetLUFS.Store(math.Float64bits(targetLUFS))
	p.setLiveCorrectionTargetGain(1.0)
	p.setLiveCorrectionCurrentGain(1.0)
	// ランプ係数はインターリーブ済みサンプル 1 つあたりの一次遅れ係数。
	step := 1.0 / (liveCorrectionRampSeconds * float64(sampleRate) * float64(channels))
	p.liveCorrectionStep.Store(math.Float64bits(step))
	p.liveMeter.Store(newLoudnessMeter(sampleRate, channels))

	stop := make(chan struct{})
	p.liveCorrectionMu.Lock()
	p.liveCorrectionStop = stop
	p.liveCorrectionMu.Unlock()

	go func() {
		ticker := time.NewTicker(liveCorrectionUpdateInterval)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				p.updateLiveCorrection()
			}
		}
	}()
}

// StopLiveLoudnessCorrection は補正を停止し、状態を初期値へ戻す。
func (p *Player) StopLiveLoudnessCorrection() {
	p.liveCorrectionMu.Lock()
	stop := p.liveCorrectionStop
	p.liveCorrectionStop = nil
	p.liveCorrectionMu.Unlock()
	if stop != nil {
		close(stop)
	}

	p.liveMeter.Store(nil)
	p.setLiveCorrectionTargetGain(1.0)
	p.setLiveCorrectionCurrentGain(1.0)
}

// updateLiveCorrection は実測ラウドネスから補正の目標値を決める。
// 定期的に呼ばれる（テストからは直接呼ぶ）。
func (p *Player) updateLiveCorrection() {
	meter := p.liveMeter.Load()
	if meter == nil {
		return
	}
	if meter.measuredSeconds() < liveCorrectionMinSeconds {
		return
	}
	measured, ok := meter.integratedLUFS()
	if !ok {
		return
	}

	targetLUFS := math.Float64frombits(p.liveCorrectionTargetLUFS.Load())
	appliedGain := math.Float64frombits(p.baseGain.Load())
	p.setLiveCorrectionTargetGain(resolveLiveCorrectionGain(measured, targetLUFS, appliedGain))
}
