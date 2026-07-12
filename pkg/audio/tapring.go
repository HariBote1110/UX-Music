package audio

import "sync/atomic"

// floatRingBuffer is a lock-free single-producer single-consumer ring buffer
// of float32 samples, mirroring the atomic read/write/available pattern used
// by Player's playback ring. The producer (the Core Audio real-time IOProc)
// must never block, so Write silently drops samples once the buffer is full.
type floatRingBuffer struct {
	buf       []float32
	size      int64
	readPos   atomic.Int64
	writePos  atomic.Int64
	available atomic.Int64
	dropped   atomic.Int64
	received  atomic.Int64
}

func newFloatRingBuffer(capacity int) *floatRingBuffer {
	return nil // TODO: Green フェーズで実装
}

// Write copies as many samples as fit and returns the number written.
func (r *floatRingBuffer) Write(src []float32) int {
	return 0
}

// Read copies up to len(dst) samples and returns the number read.
func (r *floatRingBuffer) Read(dst []float32) int {
	return 0
}

// Len returns the number of samples currently buffered.
func (r *floatRingBuffer) Len() int {
	return 0
}

// Dropped returns the total number of samples discarded due to overflow.
func (r *floatRingBuffer) Dropped() int64 {
	return 0
}

// Received returns the total number of samples offered to Write.
func (r *floatRingBuffer) Received() int64 {
	return 0
}
