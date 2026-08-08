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
	if capacity < 1 {
		capacity = 1
	}
	return &floatRingBuffer{
		buf:  make([]float32, capacity),
		size: int64(capacity),
	}
}

// Write copies as many samples as fit and returns the number written.
// Samples that do not fit are dropped (never blocks — real-time safe).
func (r *floatRingBuffer) Write(src []float32) int {
	offered := int64(len(src))
	r.received.Add(offered)

	free := r.size - r.available.Load()
	n := offered
	if n > free {
		n = free
	}
	if n <= 0 {
		r.dropped.Add(offered)
		return 0
	}

	writePos := r.writePos.Load()
	for i := int64(0); i < n; i++ {
		r.buf[(writePos+i)%r.size] = src[i]
	}
	r.writePos.Store((writePos + n) % r.size)
	r.available.Add(n)

	if offered > n {
		r.dropped.Add(offered - n)
	}
	return int(n)
}

// Read copies up to len(dst) samples and returns the number read.
func (r *floatRingBuffer) Read(dst []float32) int {
	n := int64(len(dst))
	if avail := r.available.Load(); n > avail {
		n = avail
	}
	if n <= 0 {
		return 0
	}

	readPos := r.readPos.Load()
	for i := int64(0); i < n; i++ {
		dst[i] = r.buf[(readPos+i)%r.size]
	}
	r.readPos.Store((readPos + n) % r.size)
	r.available.Add(-n)
	return int(n)
}

// Len returns the number of samples currently buffered.
func (r *floatRingBuffer) Len() int {
	return int(r.available.Load())
}

// Dropped returns the total number of samples discarded due to overflow.
func (r *floatRingBuffer) Dropped() int64 {
	return r.dropped.Load()
}

// Received returns the total number of samples offered to Write.
func (r *floatRingBuffer) Received() int64 {
	return r.received.Load()
}
