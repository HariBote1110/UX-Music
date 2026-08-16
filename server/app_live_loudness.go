package server

// 公式再生（embed）のタップ音声に対する実測ラウドネス補正のフロント向け API。
//
// 埋め込みプレイヤー自身の正規化減衰量はクロスオリジンの iframe 越しには
// 取得できない。そこで再生開始直後は推定ゲイン（resolveEmbedPlaybackGain）で
// 鳴らしつつ、タップ音声の実測ラウドネスで補正する（pkg/audio の
// StartLiveLoudnessCorrection）。

import "math"

const (
	defaultTargetLoudness = -18.0
	// 設定として受け付けるラウドネスの範囲。範囲外は既定値へ倒す。
	minTargetLoudness = -70.0
	maxTargetLoudness = -5.0
)

// sanitiseTargetLoudness は設定由来の目標ラウドネスを検証する。
// 不正値・未設定（0）・想定外の範囲は既定の -18 LUFS を返す。
func sanitiseTargetLoudness(value float64) float64 {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return defaultTargetLoudness
	}
	if value < minTargetLoudness || value > maxTargetLoudness {
		return defaultTargetLoudness
	}
	return value
}

// AudioStartLiveLoudnessCorrection starts measuring the captured (process tap)
// stream and correcting the normalisation gain towards the target loudness.
func (a *App) AudioStartLiveLoudnessCorrection(targetLoudness float64) {
	if a.audioPlayer == nil {
		return
	}
	a.audioPlayer.StartLiveLoudnessCorrection(sanitiseTargetLoudness(targetLoudness))
}

// AudioStopLiveLoudnessCorrection stops the correction and discards its state.
func (a *App) AudioStopLiveLoudnessCorrection() {
	if a.audioPlayer == nil {
		return
	}
	a.audioPlayer.StopLiveLoudnessCorrection()
}

// AudioLiveLoudnessCorrectionGain returns the correction multiplier currently
// applied on top of the estimated normalisation gain. Diagnostic probe.
func (a *App) AudioLiveLoudnessCorrectionGain() float64 {
	if a.audioPlayer == nil {
		return 1.0
	}
	return sanitizeFiniteFloat64(a.audioPlayer.LiveLoudnessCorrectionGain())
}
