package audio

// TapCapture is the platform-agnostic surface of a running process tap
// capture. ProcessTapCapture (darwin, processtap_darwin.go) implements it.
// Callers that only need to pull samples and eventually stop the tap — e.g.
// the LAN relay (server/app_remote_relay_source.go) — should depend on this
// interface rather than the concrete darwin type, so their code compiles on
// every platform even though the capture itself is darwin-only.
type TapCapture interface {
	// ReadSamples copies up to len(dst) captured samples without blocking,
	// returning the number written. It returns 0 when nothing is queued.
	ReadSamples(dst []float32) int
	// SampleRate returns the tap's sample rate.
	SampleRate() int
	// Channels returns the tap's channel count.
	Channels() int
	// Stop halts capture and releases the underlying tap/aggregate device.
	// Idempotent.
	Stop() error
}
