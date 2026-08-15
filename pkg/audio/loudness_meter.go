package audio

// ITU-R BS.1770 準拠のラウドネス測定。
//
// 公式再生（embed）ではプロセスタップで捕捉した音声のラウドネスが事前に分からない。
// YouTube のプレイヤー自身が正規化減衰を掛けており（実測で 1〜4.4 dB）、しかもその
// 減衰量はクロスオリジンの iframe 越しには取得できないためである。そこでタップ音声
// そのものを実測し、目標ラウドネスへ合わせる補正ゲインを求める。
//
// 測定はリアルタイムのオーディオコールバックから 1 サンプルずつ呼ばれるため、
// processSample はロックもアロケーションも行わない。完成した 100ms サブブロックだけ
// を事前確保済みのリングへ atomic で書き込み、解析（ゲート処理）は別スレッドで行う。

import (
	"math"
	"sync/atomic"
)

const (
	// 100ms のサブブロックを 4 個重ねて 400ms ブロック（75% オーバーラップ）とする。
	loudnessSubBlockMillis   = 100
	loudnessSubBlocksInBlock = 4
	// 保持するサブブロック数の上限（= 120 秒）。曲頭からの積分ラウドネスを求めるため
	// リングが一周したら以降は捨てる（十分な長さで測定値は既に収束している）。
	loudnessMaxSubBlocks = 1200

	// BS.1770-4 のゲート。絶対ゲート -70 LUFS、相対ゲート -10 LU。
	loudnessAbsoluteGateLUFS = -70.0
	loudnessRelativeGateLU   = -10.0
	// 平均二乗からラウドネスへ変換するときのオフセット（BS.1770-4）。
	loudnessOffsetDB = -0.691

	// 実測補正で許容する最大の増減。測定が何らかの理由で外れても暴走させない。
	maxLiveCorrectionDB = 12.0
)

// kWeightingCoefficients は BS.1770 の K 特性を構成する 2 段のバイクアッド係数を返す。
// 第 1 段は高域シェルビング、第 2 段は RLB ハイパス。48 kHz では規格の係数表と一致し、
// それ以外のサンプリングレートでもアナログ原型から設計するため特性は保たれる。
func kWeightingCoefficients(sampleRate int) (stage1, stage2 biquadCoefficients) {
	if sampleRate <= 0 {
		return identityBiquad(), identityBiquad()
	}
	rate := float64(sampleRate)

	// 高域シェルビング（規格の 48 kHz 係数を再現するアナログ原型）。
	const shelfFreq = 1681.974450955533
	const shelfGainDB = 3.999843853973347
	const shelfQ = 0.7071752369554196
	k := math.Tan(math.Pi * shelfFreq / rate)
	vh := math.Pow(10, shelfGainDB/20)
	vb := math.Pow(vh, 0.4996667741545416)
	denominator := 1 + k/shelfQ + k*k
	stage1 = biquadCoefficients{
		b0: (vh + vb*k/shelfQ + k*k) / denominator,
		b1: 2 * (k*k - vh) / denominator,
		b2: (vh - vb*k/shelfQ + k*k) / denominator,
		a1: 2 * (k*k - 1) / denominator,
		a2: (1 - k/shelfQ + k*k) / denominator,
	}

	// RLB ハイパス。
	const highPassFreq = 38.13547087602444
	const highPassQ = 0.5003270373238773
	k = math.Tan(math.Pi * highPassFreq / rate)
	denominator = 1 + k/highPassQ + k*k
	stage2 = biquadCoefficients{
		b0: 1,
		b1: -2,
		b2: 1,
		a1: 2 * (k*k - 1) / denominator,
		a2: (1 - k/highPassQ + k*k) / denominator,
	}
	return stage1, stage2
}

// blockMeanSquaresFromSubBlocks は 100ms サブブロックの平均二乗列から、
// 75% オーバーラップした 400ms ブロックの平均二乗列を組み立てる。
func blockMeanSquaresFromSubBlocks(subBlocks []float64) []float64 {
	if len(subBlocks) < loudnessSubBlocksInBlock {
		return nil
	}
	blocks := make([]float64, 0, len(subBlocks)-loudnessSubBlocksInBlock+1)
	for start := 0; start+loudnessSubBlocksInBlock <= len(subBlocks); start++ {
		sum := 0.0
		for i := 0; i < loudnessSubBlocksInBlock; i++ {
			sum += subBlocks[start+i]
		}
		blocks = append(blocks, sum/loudnessSubBlocksInBlock)
	}
	return blocks
}

// meanSquareToLUFS は平均二乗（チャンネル合算済み）をラウドネスへ変換する。
func meanSquareToLUFS(meanSquare float64) float64 {
	if meanSquare <= 0 {
		return math.Inf(-1)
	}
	return loudnessOffsetDB + 10*math.Log10(meanSquare)
}

// integratedLoudnessFromBlocks は BS.1770-4 の 2 段ゲートを適用した積分ラウドネスを返す。
// 有効なブロックが 1 つも残らない（全て無音など）場合は ok=false。
func integratedLoudnessFromBlocks(blocks []float64) (float64, bool) {
	// 第 1 段: 絶対ゲート。
	sum := 0.0
	count := 0
	for _, meanSquare := range blocks {
		if meanSquareToLUFS(meanSquare) > loudnessAbsoluteGateLUFS {
			sum += meanSquare
			count++
		}
	}
	if count == 0 {
		return 0, false
	}

	// 第 2 段: 絶対ゲート通過ぶんの平均から相対しきい値を決めて再度ふるいにかける。
	relativeThreshold := meanSquareToLUFS(sum/float64(count)) + loudnessRelativeGateLU
	gatedSum := 0.0
	gatedCount := 0
	for _, meanSquare := range blocks {
		loudness := meanSquareToLUFS(meanSquare)
		if loudness > loudnessAbsoluteGateLUFS && loudness > relativeThreshold {
			gatedSum += meanSquare
			gatedCount++
		}
	}
	if gatedCount == 0 {
		return 0, false
	}
	return meanSquareToLUFS(gatedSum / float64(gatedCount)), true
}

// loudnessMeter はストリームの積分ラウドネスを逐次測定する。
// processSample はオーディオスレッド専用、integratedLUFS は別スレッドから呼んでよい。
type loudnessMeter struct {
	channels       int
	stage1         biquadCoefficients
	stage2         biquadCoefficients
	subBlockFrames int

	// 以下はオーディオスレッドのみが触る（ロック不要）。
	states     [][2]biquadState
	sumSquares float64
	frames     int

	// 完成したサブブロックの平均二乗（float64 のビット列）。書き込みはオーディオ
	// スレッド、読み出しは解析スレッド。
	subBlocks []atomic.Uint64
	written   atomic.Int64
}

// newLoudnessMeter は指定のサンプリングレート・チャンネル数用のメーターを作る。
func newLoudnessMeter(sampleRate, channels int) *loudnessMeter {
	if channels <= 0 {
		channels = 1
	}
	if sampleRate <= 0 {
		sampleRate = 48000
	}
	stage1, stage2 := kWeightingCoefficients(sampleRate)
	subBlockFrames := sampleRate * loudnessSubBlockMillis / 1000
	if subBlockFrames <= 0 {
		subBlockFrames = 1
	}
	return &loudnessMeter{
		channels:       channels,
		stage1:         stage1,
		stage2:         stage2,
		subBlockFrames: subBlockFrames,
		states:         make([][2]biquadState, channels),
		subBlocks:      make([]atomic.Uint64, loudnessMaxSubBlocks),
	}
}

// processSample は 1 サンプルを取り込む。channelIndex は 0 始まり。
// リアルタイムスレッドから呼ばれるため、アロケーションもロックも行わない。
func (m *loudnessMeter) processSample(channelIndex int, sample float64) {
	if m == nil || channelIndex < 0 || channelIndex >= m.channels {
		return
	}
	state := &m.states[channelIndex]
	filtered := processBiquadSample(sample, m.stage1, &state[0])
	filtered = processBiquadSample(filtered, m.stage2, &state[1])
	m.sumSquares += filtered * filtered

	// 最終チャンネルまで来たら 1 フレーム完了とみなす。
	if channelIndex != m.channels-1 {
		return
	}
	m.frames++
	if m.frames < m.subBlockFrames {
		return
	}

	// z_i の総和（チャンネル合算）を平均二乗として保存する。
	meanSquare := m.sumSquares / float64(m.frames)
	m.sumSquares = 0
	m.frames = 0

	index := m.written.Load()
	if index < int64(len(m.subBlocks)) {
		m.subBlocks[index].Store(math.Float64bits(meanSquare))
		m.written.Store(index + 1)
	}
}

// integratedLUFS は現時点までの積分ラウドネスを返す。測定に足るだけの有効な音声が
// まだ無ければ ok=false。
func (m *loudnessMeter) integratedLUFS() (float64, bool) {
	if m == nil {
		return 0, false
	}
	count := int(m.written.Load())
	if count < loudnessSubBlocksInBlock {
		return 0, false
	}
	subBlocks := make([]float64, count)
	for i := 0; i < count; i++ {
		subBlocks[i] = math.Float64frombits(m.subBlocks[i].Load())
	}
	return integratedLoudnessFromBlocks(blockMeanSquaresFromSubBlocks(subBlocks))
}

// measuredSeconds は測定済みの音声長（秒）を返す。補正を適用してよいかの判断に使う。
func (m *loudnessMeter) measuredSeconds() float64 {
	if m == nil {
		return 0
	}
	return float64(m.written.Load()) * loudnessSubBlockMillis / 1000
}

// resolveLiveCorrectionGain は実測ラウドネスから、既に掛かっている推定ゲイン
// appliedGainLinear に対して追加で掛けるべき補正係数（線形）を返す。
//
// 必要な総ゲイン(dB) = targetLUFS − measuredLUFS。measuredLUFS は推定ゲインを
// 掛ける前の信号を測ったものなので、補正 = 必要な総ゲイン − 既に掛けたぶん。
// 不正な入力では 1.0（補正なし）を返す。
func resolveLiveCorrectionGain(measuredLUFS, targetLUFS, appliedGainLinear float64) float64 {
	if math.IsNaN(measuredLUFS) || math.IsInf(measuredLUFS, 0) {
		return 1.0
	}
	if math.IsNaN(targetLUFS) || math.IsInf(targetLUFS, 0) {
		return 1.0
	}
	if appliedGainLinear <= 0 || math.IsNaN(appliedGainLinear) || math.IsInf(appliedGainLinear, 0) {
		return 1.0
	}
	appliedDB := 20 * math.Log10(appliedGainLinear)
	correctionDB := clampFloat64((targetLUFS-measuredLUFS)-appliedDB, -maxLiveCorrectionDB, maxLiveCorrectionDB)
	return math.Pow(10, correctionDB/20)
}
