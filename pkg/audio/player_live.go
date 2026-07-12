package audio

// ProcessTapTargets specifies which processes a process tap should capture.
// Either bundle IDs (preferred on macOS 26+) or PIDs may be given; at least
// one valid target is required.
type ProcessTapTargets struct {
	BundleIDs []string
	PIDs      []int
}

// liveSampleSource is a pull-based, non-blocking source of interleaved
// float32 samples produced by a live capture (e.g. a Core Audio process tap).
type liveSampleSource interface {
	// ReadSamples copies up to len(dst) samples and returns the number read.
	// It never blocks.
	ReadSamples(dst []float32) int
	SampleRate() int
	Channels() int
	Stop() error
}

// normaliseTapTargets trims, deduplicates and validates tap targets.
func normaliseTapTargets(targets ProcessTapTargets) (ProcessTapTargets, error) {
	return ProcessTapTargets{}, nil // TODO: Green フェーズで実装
}

// liveTapDecoder adapts a liveSampleSource to the Decoder interface so the
// player's existing pipeline (ring buffer, EQ, gain, FFT) applies unchanged.
type liveTapDecoder struct {
	source liveSampleSource
}

func newLiveTapDecoder(source liveSampleSource) *liveTapDecoder {
	return &liveTapDecoder{source: source}
}

func (d *liveTapDecoder) ReadFloat32(dst []float32) (int, error) { return 0, nil }
func (d *liveTapDecoder) Read(p []byte) (int, error)             { return 0, nil }
func (d *liveTapDecoder) SampleRate() int                        { return 0 }
func (d *liveTapDecoder) Channels() int                          { return 0 }
func (d *liveTapDecoder) Length() int64                          { return 0 }
func (d *liveTapDecoder) Seek(sample int64) error                { return nil }
func (d *liveTapDecoder) Close() error                           { return nil }

// playLiveSource starts playback from a live capture source.
func (p *Player) playLiveSource(source liveSampleSource, gainLinear float64) error {
	return nil // TODO: Green フェーズで実装
}
